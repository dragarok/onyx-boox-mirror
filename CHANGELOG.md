# Changelog

## [2.7-boox] — 2026-11-27 (Onyx BOOX fork)

### Added
- Tailscale: the Mac hands its Tailscale address to the BOOX when paired over USB, so the tablet can find it away from home
- `tailscaleAddresses` setting picks which of the Mac's tailnets tablets may use; connections through any other tailnet are refused (`defaults write com.daylight.mirror tailscaleAddresses -array <ip>`)
- Mirroring only over Tailscale: a second-monitor request becomes mirroring, a second-monitor session switches to mirroring when the tablet reconnects from away, and the BOOX offers only "Mirror Mac"
- BOOX shows "Connecting to <Mac>…" while the first picture loads on a slow link
- USB always wins: the BOOX asks the Mac over the cable first, and the Mac keeps second monitor when the BOOX is on USB even if a connection arrives over Tailscale

### Fixed
- A phone on Android wireless debugging (mDNS serial `adb-…._adb-tls-connect._tcp`) was treated as a lone DC-1 and mirrored to
- The BOOX stopped checking for the cable if the first picture hadn't arrived yet (slow Tailscale relay), so it could stay off USB

## [2.6-boox] — 2026-11-27 (Onyx BOOX fork)

### Added
- Onyx BOOX Tab Ultra C support: HiDPI virtual display modes, colour and greyscale, e-ink refresh modes (Auto/Quality/Balanced/Fast), frontlight and warmth over USB
- Mirror and second-monitor modes; the Mac screen only dims in mirror mode
- Touch (taps, drags, two-finger scroll) and keyboard input from the BOOX, with layout-independent key injection
- Wi-Fi streaming on the local network, paired over USB with a shared secret; USB is preferred and taken over automatically when plugged in
- Start from the tablet: the BOOX app finds the Mac (USB or Bonjour), asks "Mirror Mac" or "Second monitor", and starts it — no Mac interaction
- "Remember my choice" auto-starts the last mode, with "Choose another mode" during the start
- Settings on the BOOX (mode, resolution, colour, e-ink refresh, full refresh, stop), opened with a four-finger tap while mirroring
- Remote-control port 8893 (`STATUS`, `START`, `RELEASE`, `STOP`, `REFRESH`, `SETTINGS`, `SET`)
- Device-started sessions stop 60 s after the tablet goes away; Back on the tablet stops them at once
- Keeps the Mac from idle-sleeping on AC while Wireless is on
- `daylight-mirror wireless [on|off]` CLI command
- USB vs Wi-Fi benchmark (`scripts/bench`)

### Fixed
- Re-creating an existing adb tunnel dropped the live USB connection mid-start
- A session could stop itself 60 s after starting when the tablet connected before the session was registered
- Relaunching the BOOX app could leave it stuck on "Starting…" (stream ownership between activity instances)
- A touch cancelled by the BOOX system (its three-finger gestures) no longer clicks on the Mac

## [1.8.0] — 2026-03-07

### Added
- Clamshell mode — keep DC-1 alive with MacBook lid closed (works on battery)
- Uses `pmset disablesleep` with cached admin authorization (password asked once per session)
- Automatic re-mirror and capture restart on lid reopen
- Safety restore: clears stuck SleepDisabled on app launch if previous crash left it on
- `daylight-mirror clamshell [on|off]` CLI command
- `daylight-mirror health [verbose]` CLI command — full engine diagnostics
- ESC key dismisses menu bar popover
- Collapsible Speed stats section within More menu
- ScreenCapture stream restart for recovering from display pipeline stalls

## [1.7.0] — 2026-03-07

### Added
- Display profile presets: Crisp Paper, Balanced, Custom — bundles sharpen + contrast + gamma
- Gamma correction for reflective paper displays (adjustable 1.0–1.5)
- GL_NEAREST texture filtering on Android for pixel-perfect 1:1 text rendering
- `wm size` reset on ADB setup to prevent scaling artifacts from DC-1 factory override
- Modern fullscreen API (WindowInsetsController) on Android for full panel access
- v1.7 UserDefaults migration — clears stale saved values so new optimized defaults take effect
- Adaptive backpressure threshold based on RTT for frame skipping
- Trivial delta skip — drops frames where screen barely changed (< 512 bytes compressed)
- CompositorPacer upgraded to 4x4 dirty region for reliable compositor triggering

### Changed
- Default sharpen 1.0→1.5, contrast 1.0→1.2, gamma 0→1.2 for optimal DC-1 crispness
- Renamed "E-ink Crisp" profile → "Crisp Paper" — DC-1 is a reflective LCD, not e-ink
- Removed smoothstep shader from Android renderer — Mac-side LUT alone handles text crispness
- All e-ink references corrected to reflective paper display throughout codebase

### Fixed
- Double-processing crushing ~40% of greyscale range (Mac LUT + Android shader combined)
- 1:1 pixel mapping destroyed by DC-1 `display_size_forced` override
- Profile picker slider changes correctly fall back to Custom profile

## [1.6.1] — 2026-02-20

### Fixed
- Sync initial device brightness to TCPServer on startup

## [1.6.0] — 2026-02-18

### Added
- Developer ID signing + notarization in CI/CD (replaces ad-hoc signing)
- Feedback, support, and about links in app
- "Dim Mac display" toggle

### Changed
- Daylight referral links updated to buy.daylightcomputer.com
- Download links switched to Stripe, added stable GitHub release URL
- Website: swapped hero to daytime image, referral banner, cleaner pricing

### Fixed
- Re-send brightness on reconnect
- Broadcast resolution to connected clients on change
- Portrait rotation: switch Android orientation on resolution change
- Theme toggle icons on website
