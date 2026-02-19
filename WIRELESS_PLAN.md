# Wireless Mirroring — Implementation Plan

## Context

Daylight Mirror currently streams LZ4-compressed greyscale/RGB frames from Mac to Boox Tab Ultra C over USB (ADB reverse tunnel on TCP port 8888). The protocol is already transport-agnostic — the same TCP stream works over WiFi with zero changes. The only missing piece is **device discovery**.

### What's Already Done (Current State)
- Virtual display creation + screen capture (CGDisplayStream)
- Greyscale/color mode with vImage SIMD conversion
- Tile-based dirty detection (64x64 tiles, bitmap, per-tile LZ4)
- XOR delta compression with SIMD (Mac: SIMD16, Android: NEON)
- TCP frame server (NWListener on port 8888)
- ADB reverse tunnel for USB connectivity
- Boox frontlight control via ADB sysfs (brightness + warmth)
- E-ink full refresh trigger
- Touch input: single-finger tap/click/drag + two-finger scroll
- Compositor pacer for consistent frame delivery
- Auto-reconnect on USB plug/unplug

---

## Phase 1: WiFi with mDNS Discovery

**Goal**: Mirror works over WiFi on the same network. No manual IP entry.

### 1.1 Mac — Advertise via Bonjour (1 line)

**File**: `Sources/MirrorEngine/TCPServer.swift`

In `start()`, after creating the listener:
```swift
listener.service = NWListener.Service(name: "Daylight Mirror", type: "_daylight-mirror._tcp")
```

That's it. `NWListener` handles mDNS advertisement automatically. The TCP server already binds to `0.0.0.0` (all interfaces), so WiFi clients can connect.

### 1.2 Android — Discover Mac via NsdManager (~40 lines)

**File**: `android/app/src/main/java/com/daylight/mirror/MirrorActivity.kt`

Add `NsdManager` service discovery:
```kotlin
val nsdManager = getSystemService(Context.NSD_SERVICE) as NsdManager

// Discover "_daylight-mirror._tcp" services on the local network
// On service found → resolve → get Mac's IP + port
// Pass discovered host to nativeStart() instead of "127.0.0.1"
```

Key callbacks:
- `onServiceFound` → trigger resolve
- `onServiceResolved` → extract `host.hostAddress` and `port`
- `onServiceLost` → mark host as unavailable

### 1.3 Android Native — Parameterized Host

**File**: `android/app/src/main/cpp/mirror_native.c`

Already parameterized! `g_host` and `g_port` are set from `nativeStart(surface, host, port)`. The Kotlin side just needs to pass the discovered IP instead of `"127.0.0.1"`.

### 1.4 Bandwidth Requirements

| Scenario | Frame Size | FPS | Bandwidth |
|----------|-----------|-----|-----------|
| Idle (reading) | ~0.2 KB | 60 | ~96 Kbps |
| Light typing | ~5 KB | 60 | ~2.4 Mbps |
| Scrolling | ~50 KB | 60 | ~24 Mbps |
| Full-screen change | ~200 KB | 60 | ~96 Mbps |

WiFi 5: 300-800 Mbps real throughput. WiFi latency: ~1-4ms (invisible on e-ink).

---

## Phase 2: Hybrid USB + WiFi Auto-Detection

**Goal**: Seamless handoff. Prefer USB when available, fall back to WiFi.

### 2.1 Android Connection Strategy

**File**: `android/app/src/main/cpp/mirror_native.c`

Modify the reconnect loop (currently retries `127.0.0.1:8888` every 1s) to cycle through available hosts:

```
Connection priority:
1. localhost:8888 (USB tunnel — fastest, always try first)
2. <mDNS-discovered-IP>:8888 (WiFi — fallback)
```

Add a JNI method `nativeUpdateHost(host, port)` that Kotlin calls when:
- mDNS discovers a new Mac on the network
- USB state changes (connect/disconnect)

### 2.2 Mac — Keep ADB Bridge for USB

No changes needed. The existing `ADBBridge.swift` handles USB tunnel setup. The TCP server serves both USB (via tunnel) and WiFi (direct) clients simultaneously.

### 2.3 Status UI

Update `MirrorActivity.kt` status hints:
```
"1. Connect via USB cable, or
     connect to the same WiFi network
 2. Open Mirror app on Mac
 3. Start via menu bar or Ctrl+F8"
```

Show connection type indicator: "USB" or "WiFi" badge.

### 2.4 Mac Menu Bar — Connection Type

**File**: `Sources/App/DaylightMirrorApp.swift`

Show whether the connected client is on USB (localhost) or WiFi (LAN IP) in the running view stats.

---

## Phase 3: Security (Optional, Later)

### 3.1 Simple PIN Pairing

On first WiFi connection:
1. Mac displays a random 4-digit PIN in the menu bar
2. Android app prompts user to enter the PIN
3. If correct, Mac stores the device ID (derive from Android device serial)
4. Future connections from that device skip the PIN

### 3.2 TLS Encryption (If Needed)

**Mac** — Network.framework supports TLS natively:
```swift
let tlsOptions = NWProtocolTLS.Options()
let params = NWParameters(tls: tlsOptions, tcp: tcpOptions)
```

**Android** — Wrap socket with `SSLSocket`.

Hardware AES-GCM adds <1% CPU overhead. TLS handshake: ~1-2ms one-time cost.

---

## Files to Modify

| File | Phase | Changes |
|------|-------|---------|
| `Sources/MirrorEngine/TCPServer.swift` | 1 | Add `listener.service` for Bonjour |
| `MirrorActivity.kt` | 1 | Add NsdManager discovery, pass discovered host |
| `mirror_native.c` | 2 | Cycle through hosts in reconnect loop, add `nativeUpdateHost` JNI |
| `DaylightMirrorApp.swift` | 2 | Show USB/WiFi connection type |
| `MirrorEngine.swift` | 2 | Surface connection type to UI |

## What Does NOT Change
- TCP frame protocol (same bytes over USB or WiFi)
- LZ4 + XOR delta compression
- Tile-based dirty detection
- Touch/scroll forwarding
- Brightness/warmth/refresh controls
- ACK-based RTT measurement

## Build & Test

**Phase 1**:
```bash
swift build
cd android && ./gradlew assembleDebug
adb install -r app/build/outputs/apk/debug/app-debug.apk
```
1. Disconnect USB cable
2. Ensure Mac and Boox are on the same WiFi
3. Launch Mac app → start mirror
4. Boox should discover Mac via mDNS and connect within seconds
5. Verify frames stream, touch works, latency is acceptable

**Phase 2**:
1. Start with USB connected → verify USB tunnel used
2. Unplug USB → verify seamless fallback to WiFi
3. Plug USB back in → verify switch back to USB
