# Boox Tab Ultra C: Color + Secondary Display — Implementation Plan

## Overview
Three targeted changes to the existing Daylight Mirror app:
1. **Color** — stop converting to greyscale, send RGB
2. **Secondary display** — independent screen instead of mirroring built-in
3. **Boox-tuned settings** — resolution presets, 24fps target, remove Daylight-specific warmth controls

Primary use case: running Claude Code on an e-ink secondary display.

---

## Task 1: Configuration.swift — Boox presets + FPS constants

**What changes:**
- `TARGET_FPS`: 60 → 24
- `KEYFRAME_INTERVAL`: 60 → 24 (still 1 keyframe/sec)
- Add `DisplayResolution` cases:
  - `booxCozy`: 1240x930 HiDPI (620x465pt @ 2x) — color-native resolution
  - `booxBalanced`: 1240x930 non-HiDPI — 1:1 pixel mapping
  - `booxSharp`: 1860x1395 non-HiDPI — between color and B&W native
  - Portrait variants of each
- Remove `CMD_WARMTH`, `WARMTH_STEP` constants

## Task 2: ScreenCapture.swift — BGRA→RGB instead of greyscale

**What changes:**
- Remove `vImageMatrixMultiply_ARGB8888ToPlanar8` (greyscale matrix conversion, lines 244-284)
- Remove Laplacian sharpening convolution
- Remove contrast LUT processing
- Remove `sharpenTemp`, `contrastLUT`, `sharpenAmount`, `contrastAmount` fields
- New conversion: BGRA→RGB (drop alpha channel) using simple loop or vImage permute
- Buffer allocations: `width * height * 3` instead of `width * height`
- LZ4 compression: `pixelCount * 3` bytes instead of `pixelCount`
- XOR delta: operates on `pixelCount * 3` bytes — unchanged logic, just more bytes
- Stats label: "grey" → "rgb" in print statements

## Task 3: VirtualDisplayManager.swift — Secondary display mode

**What changes:**
- Add `mirror: Bool` parameter to `init()` (default: `false`)
- Store `mirror` property
- `mirrorBuiltInDisplay()`: early-return if `mirror == false`
- When not mirroring: virtual display is an independent secondary screen
- macOS handles arrangement via System Settings > Displays

## Task 4: CompositorPacer.swift — 24fps pacing

**What changes:**
- `CAFrameRateRange`: preferred 60 → 24, maximum 60 → 24, minimum 30 → 15
- Timer fallback: 16ms → 42ms (1000/24 ≈ 42)
- Tick counter log: divides by 24 instead of 60

## Task 5: MirrorEngine.swift — Wire up secondary display, remove warmth/auto-dim

**What changes:**
- Pass `mirror: false` to `VirtualDisplayManager`
- Remove `mirrorBuiltInDisplay()` call (handled internally now)
- Remove Mac brightness auto-dim logic (`savedMacBrightness`, `MacBrightness.get/set`)
- Remove `warmth` published property and `setWarmth()` method
- Remove `sharpenAmount` and `contrastAmount` published properties
- Remove warmth-related callbacks on DisplayController
- Keep brightness control (Boox has a frontlight)

## Task 6: DisplayController.swift — Remove warmth controls

**What changes:**
- Remove Ctrl+F11/F12 keyboard shortcuts (warmth up/down)
- Remove `adjustWarmth()`, `setWarmth()`, `currentWarmth` fields
- Remove `onWarmthChanged` callback
- Remove ADB warmth system setting calls
- Keep brightness controls (Ctrl+F1/F2, Ctrl+F10 toggle)

## Task 7: mirror_native.c — RGB color rendering

**What changes:**
- Fragment shader: `float grey = texture2D(...).r; gl_FragColor = vec4(grey,grey,grey,1.0)` →
  `vec3 color = texture2D(...).rgb; gl_FragColor = vec4(color, 1.0)`
- `glTexImage2D`/`glTexSubImage2D`: `GL_LUMINANCE` → `GL_RGB`
- Buffer sizes: `g_pixel_count` → `g_pixel_count * 3` (rename to `g_buffer_size`)
- `blit_grey_to_surface()` → `blit_rgb_to_surface()`: RGB→RGBX expansion instead of grey→RGBX
- CPU fallback render path: RGB→RGBX NEON expansion (3 source bytes → 4 dest bytes)
- `apply_delta_neon`: operates on `pixel_count * 3` bytes — unchanged
- `reallocate_buffers`: allocate `new_pixels * 3` bytes

## Task 8: MirrorActivity.kt — 24fps + generic branding

**What changes:**
- `setFrameRate(60.0f, ...)` → `setFrameRate(24.0f, ...)`
- Status text: "Waiting for Mac..." → "Waiting for connection..."
- Hint text: "Open Daylight Mirror on Mac" → "Open Mirror app on Mac"

---

## What stays the same
- TCP protocol, frame headers, ACK mechanism
- LZ4 compression (works on any byte stream)
- XOR delta compression (works on any byte stream)
- ADB bridge, reverse tunnel, APK install
- USB device monitoring
- WebSocket/HTTP debug servers

## Build & test
```bash
make android   # build updated APK
make mac       # build updated Mac app
adb install -r android/app/build/outputs/apk/debug/app-debug.apk
```
1. Launch Mac app — verify virtual display appears as **secondary** (not mirror) in System Settings > Displays
2. Drag a terminal window to the Boox display
3. Verify color rendering, ~24fps, readable text
4. Run `claude` on the Boox display — confirm it's usable for Claude Code
