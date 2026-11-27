#!/usr/bin/env python3
"""USB vs Wi-Fi benchmark for the live mirror.

Runs scripts/bench/workload.swift on the mirrored display and samples the app's own
stats (control socket LATENCY + HEALTH) every 0.5 s, bucketed per workload phase:
  fps        frames the Mac actually sent per second (from total_frames)
  rtt        frame sent → ACK received from the device: network + LZ4 decode + render
  bandwidth  Mbit/s on the wire

Usage:
  python3 scripts/bench/run_bench.py --label wifi       # run one leg, save JSON
  python3 scripts/bench/run_bench.py --compare usb wifi # table from the latest results
"""

import argparse
import json
import socket
import statistics
import subprocess
import sys
import threading
import time
from datetime import datetime
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
RESULTS = ROOT / "bench" / "results"
SOCK = "/tmp/daylight-mirror.sock"
PHASES = ["typing", "scrolling", "pageflip"]


def control(cmd):
    s = socket.socket(socket.AF_UNIX)
    s.settimeout(2)
    s.connect(SOCK)
    s.sendall((cmd + "\n").encode())
    data = b""
    try:
        while True:
            chunk = s.recv(8192)
            if not chunk:
                break
            data += chunk
    except socket.timeout:
        pass
    s.close()
    out = {}
    for line in data.decode().splitlines():
        if "=" in line:
            k, v = line.split("=", 1)
            out[k.strip()] = v.strip()
    return out


def num(d, k):
    try:
        return float(d.get(k, "nan"))
    except ValueError:
        return float("nan")


def run_leg(label, phase_seconds):
    health = control("HEALTH")
    if health.get("status") != "running" or health.get("clients", "0") == "0":
        sys.exit(f"Mirror not running with a connected device (status={health.get('status')}, clients={health.get('clients')})")

    proc = subprocess.Popen(["swift", str(ROOT / "scripts/bench/workload.swift"), str(phase_seconds)],
                            stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
    marks = []  # (name, t)

    def reader():
        for line in proc.stdout:
            parts = line.split()
            if parts and parts[0] in ("PHASE", "END") and len(parts) >= 2:
                name = parts[1] if parts[0] == "PHASE" else "END"
                marks.append((name, float(parts[-1])))
                print(f"  {datetime.now():%H:%M:%S} {line.strip().rsplit(' ', 1)[0]}", flush=True)
            elif line.startswith("ERROR"):
                print(line.strip(), flush=True)

    t = threading.Thread(target=reader, daemon=True)
    t.start()

    samples = []
    while proc.poll() is None:
        try:
            lat = control("LATENCY")
            h = control("HEALTH")
            samples.append({
                "t": time.time(),
                "frames": num(lat, "total_frames"),
                "rtt_avg": num(lat, "rtt_avg_ms"),
                "rtt_p95": num(lat, "rtt_p95_ms"),
                "bw": num(h, "bandwidth_mbps"),
                "skipped": num(lat, "skipped_frames"),
            })
        except OSError:
            pass
        time.sleep(0.5)
    t.join(timeout=2)
    if not any(m[0] == "END" for m in marks):
        sys.exit("Workload did not finish (no mirrored display?)")

    bounds = {}
    for i, (name, ts) in enumerate(marks):
        if name in PHASES:
            end = marks[i + 1][1] if i + 1 < len(marks) else ts + phase_seconds
            bounds[name] = (ts, end)

    phases = {}
    for name, (a, b) in bounds.items():
        # skip the first second of each phase so rolling stats reflect the new load
        inside = [s for s in samples if a + 1.0 <= s["t"] <= b]
        if len(inside) < 2:
            continue
        dur = inside[-1]["t"] - inside[0]["t"]
        frames = inside[-1]["frames"] - inside[0]["frames"]
        rtts = [s["rtt_avg"] for s in inside if s["rtt_avg"] == s["rtt_avg"] and s["rtt_avg"] > 0]
        p95s = [s["rtt_p95"] for s in inside if s["rtt_p95"] == s["rtt_p95"] and s["rtt_p95"] > 0]
        bws = [s["bw"] for s in inside if s["bw"] == s["bw"]]
        phases[name] = {
            "fps": round(frames / dur, 1) if dur > 0 else 0,
            "rtt_avg_ms": round(statistics.median(rtts), 1) if rtts else None,
            "rtt_p95_ms": round(max(p95s), 1) if p95s else None,
            "bandwidth_mbps": round(statistics.mean(bws), 2) if bws else None,
            "samples": len(inside),
        }

    result = {"label": label, "time": datetime.now().isoformat(timespec="seconds"),
              "phase_seconds": phase_seconds, "phases": phases}
    RESULTS.mkdir(parents=True, exist_ok=True)
    path = RESULTS / f"{label}-{datetime.now():%Y%m%d-%H%M%S}.json"
    path.write_text(json.dumps(result, indent=2))
    print_table([result])
    print(f"\nSaved {path.relative_to(ROOT)}")


def latest(label):
    files = sorted(RESULTS.glob(f"{label}-*.json"))
    if not files:
        sys.exit(f"No results for '{label}' in {RESULTS}")
    return json.loads(files[-1].read_text())


def print_table(results):
    cols = ["fps", "rtt_avg_ms", "rtt_p95_ms", "bandwidth_mbps"]
    heads = {"fps": "fps", "rtt_avg_ms": "RTT median (ms)", "rtt_p95_ms": "RTT p95 (ms)",
             "bandwidth_mbps": "Mbit/s"}
    print(f"\n{'phase':<10} {'link':<6} " + " ".join(f"{heads[c]:>16}" for c in cols))
    for ph in PHASES:
        for r in results:
            p = r["phases"].get(ph)
            if not p:
                continue
            vals = " ".join(f"{('-' if p[c] is None else p[c]):>16}" for c in cols)
            print(f"{ph:<10} {r['label']:<6} {vals}")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--label", help="name for this leg, e.g. usb or wifi")
    ap.add_argument("--seconds", type=float, default=15, help="seconds per phase")
    ap.add_argument("--compare", nargs="+", help="labels to compare (latest result each)")
    a = ap.parse_args()
    if a.compare:
        print_table([latest(l) for l in a.compare])
    elif a.label:
        run_leg(a.label, a.seconds)
    else:
        ap.print_help()


if __name__ == "__main__":
    main()
