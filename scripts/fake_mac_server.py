#!/usr/bin/env python3
"""Protocol test server — stands in for the Mac app to exercise the Android client.

Speaks the same wire protocol as TCPServer.swift / ScreenCapture.swift so the
companion app's decoder, renderer and e-ink handling can be tested without macOS
Screen Recording permission or a virtual display:

    CMD_COLOR_MODE → CMD_RESOLUTION → CMD_EINK_MODE → keyframe
    → tiled deltas (a box sliding across) → one full-frame delta → CMD_REFRESH

No third-party packages: LZ4 blocks are emitted literal-only, which is a valid LZ4
block that any decoder (LZ4_decompress_safe) accepts.

Usage:
    adb -s <serial> reverse tcp:8888 tcp:8888
    python3 scripts/fake_mac_server.py --width 2480 --height 1860 --color
    adb -s <serial> shell am start -S -n com.daylight.mirror/.MirrorActivity
    adb -s <serial> exec-out screencap -p > shot.png
"""

import argparse
import socket
import struct
import threading
import time

MAGIC_FRAME = b"\xda\x7e"
MAGIC_CMD = b"\xda\x7f"
FLAG_KEYFRAME, FLAG_TILED = 0x01, 0x02
CMD_BRIGHTNESS, CMD_WARMTH, CMD_RESOLUTION = 0x01, 0x02, 0x04
CMD_COLOR_MODE, CMD_REFRESH, CMD_EINK_MODE = 0x05, 0x06, 0x07
TILE = 64


def lz4_literal_block(data: bytes) -> bytes:
    """Encode `data` as a single literal-only LZ4 sequence."""
    n = len(data)
    if n < 15:
        return bytes([n << 4]) + data
    out = bytearray([0xF0])
    rem = n - 15
    while rem >= 255:
        out.append(255)
        rem -= 255
    out.append(rem)
    return bytes(out) + data


def xor_bytes(a: bytes, b: bytes) -> bytes:
    return (int.from_bytes(a, "little") ^ int.from_bytes(b, "little")).to_bytes(len(a), "little")


def make_frame(w, h, bpp, box_x=None, box=120):
    """Color bars on top, a fine 1-px checker + text-like stripes below, optional black box."""
    bars = [(255, 255, 255), (255, 255, 0), (0, 255, 255), (0, 255, 0),
            (255, 0, 255), (255, 0, 0), (0, 0, 255), (0, 0, 0)]

    def px(rgb):
        if bpp == 3:
            return bytes(rgb)
        r, g, b = rgb
        return bytes([(77 * r + 150 * g + 29 * b) >> 8])

    bar_row = b"".join(px(bars[(x * len(bars)) // w]) for x in range(w))
    checker_a = b"".join(px((0, 0, 0) if x % 2 == 0 else (255, 255, 255)) for x in range(w))
    checker_b = b"".join(px((255, 255, 255) if x % 2 == 0 else (0, 0, 0)) for x in range(w))
    stripe = b"".join(px((30, 30, 30) if (x // 6) % 3 else (255, 255, 255)) for x in range(w))
    white = px((255, 255, 255)) * w

    rows = []
    for y in range(h):
        if y < h // 3:
            rows.append(bar_row)
        elif y < h // 2:
            rows.append(checker_a if y % 2 == 0 else checker_b)
        elif (y // 12) % 2 == 0:
            rows.append(stripe)
        else:
            rows.append(white)
    frame = bytearray(b"".join(rows))
    if box_x is not None:
        black = px((0, 0, 0)) * box
        y0 = h // 2 + 40
        for y in range(y0, min(h, y0 + box)):
            off = (y * w + box_x) * bpp
            frame[off:off + box * bpp] = black[: max(0, min(box, w - box_x)) * bpp]
    return bytes(frame)


def tiled_delta(prev, cur, w, h, bpp):
    cols, rows = (w + TILE - 1) // TILE, (h + TILE - 1) // TILE
    stride = w * bpp
    dirty = []
    for ty in range(rows):
        th = min(TILE, h - ty * TILE)
        for tx in range(cols):
            rl = min(TILE, w - tx * TILE) * bpp
            base = ty * TILE * stride + tx * TILE * bpp
            for r in range(th):
                o = base + r * stride
                if cur[o:o + rl] != prev[o:o + rl]:
                    dirty.append(ty * cols + tx)
                    break
    bitmap = bytearray((cols * rows + 7) // 8)
    for i in dirty:
        bitmap[i >> 3] |= 1 << (i & 7)
    out = bytearray(struct.pack("<HH", cols, rows)) + bitmap
    for i in dirty:
        ty, tx = divmod(i, cols)
        th = min(TILE, h - ty * TILE)
        rl = min(TILE, w - tx * TILE) * bpp
        base = ty * TILE * stride + tx * TILE * bpp
        packed = b"".join(xor_bytes(cur[base + r * stride: base + r * stride + rl],
                                    prev[base + r * stride: base + r * stride + rl]) for r in range(th))
        block = lz4_literal_block(packed)
        out += struct.pack("<I", len(block)) + block
    return bytes(out), len(dirty), cols * rows


class Client:
    def __init__(self, conn):
        self.conn = conn
        self.seq = 0
        self.sent_at = {}
        self.rtts = []
        self.alive = True
        threading.Thread(target=self._read_acks, daemon=True).start()

    def _read_acks(self):
        buf = b""
        while self.alive:
            try:
                data = self.conn.recv(4096)
            except OSError:
                break
            if not data:
                break
            buf += data
            while len(buf) >= 6:
                if buf[0:2] != b"\xda\x7a":
                    buf = buf[1:]
                    continue
                seq = struct.unpack("<I", buf[2:6])[0]
                buf = buf[6:]
                t = self.sent_at.pop(seq, None)
                if t is not None:
                    self.rtts.append((time.time() - t) * 1000)
        self.alive = False

    def cmd(self, cmd, payload: bytes):
        self.conn.sendall(MAGIC_CMD + bytes([cmd]) + payload)

    def frame(self, flags, payload):
        self.sent_at[self.seq] = time.time()
        self.conn.sendall(MAGIC_FRAME + bytes([flags]) + struct.pack("<II", self.seq, len(payload)) + payload)
        self.seq += 1


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--width", type=int, default=1240)
    ap.add_argument("--height", type=int, default=930)
    ap.add_argument("--color", action="store_true")
    ap.add_argument("--port", type=int, default=8888)
    ap.add_argument("--steps", type=int, default=20)
    ap.add_argument("--hold", type=float, default=4.0, help="seconds to hold after keyframe/deltas")
    ap.add_argument("--eink-mode", type=int, default=0)
    args = ap.parse_args()
    w, h, bpp = args.width, args.height, 3 if args.color else 1

    print(f"Building test frames {w}x{h} {'RGB' if bpp == 3 else 'grey'}...")
    key = make_frame(w, h, bpp)

    srv = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    srv.bind(("127.0.0.1", args.port))
    srv.listen(1)
    print(f"Listening on 127.0.0.1:{args.port} — launch the app now")
    conn, _ = srv.accept()
    conn.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
    c = Client(conn)
    print("Client connected")

    c.cmd(CMD_COLOR_MODE, bytes([1 if bpp == 3 else 0]))
    c.cmd(CMD_RESOLUTION, struct.pack("<HH", w, h))
    c.cmd(CMD_EINK_MODE, bytes([args.eink_mode]))
    kf = lz4_literal_block(key)
    c.frame(FLAG_KEYFRAME, kf)
    print(f"KEYFRAME_SENT {len(kf)} bytes")
    time.sleep(args.hold)
    print("HOLD_DONE keyframe")

    prev = key
    x = 40
    tiled_bytes = 0
    for i in range(args.steps):
        x = 40 + i * max(1, (w - 200) // max(1, args.steps))
        cur = make_frame(w, h, bpp, box_x=x)
        payload, nd, nt = tiled_delta(prev, cur, w, h, bpp)
        c.frame(FLAG_TILED, payload)
        tiled_bytes += len(payload)
        prev = cur
        time.sleep(0.08)
    print(f"TILED_SENT {args.steps} frames, {tiled_bytes} bytes total, last box_x={x}")
    time.sleep(args.hold)
    print("HOLD_DONE tiled")

    # One full-frame XOR delta (flags 0): move the box back to the left edge
    cur = make_frame(w, h, bpp, box_x=40)
    c.frame(0x00, lz4_literal_block(xor_bytes(cur, prev)))
    prev = cur
    print("FULL_DELTA_SENT box_x=40")
    time.sleep(args.hold)
    print("HOLD_DONE full")

    c.cmd(CMD_REFRESH, b"\x01")
    print("REFRESH_SENT")
    time.sleep(2)

    if c.rtts:
        s = sorted(c.rtts)
        print(f"ACKS {len(s)}/{c.seq} rtt avg {sum(s)/len(s):.1f}ms p50 {s[len(s)//2]:.1f}ms max {s[-1]:.1f}ms")
    else:
        print(f"ACKS 0/{c.seq}")
    print("DONE")
    if "--keep" not in __import__("sys").argv:
        conn.close()


if __name__ == "__main__":
    main()
