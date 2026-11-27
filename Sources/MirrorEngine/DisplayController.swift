// DisplayController.swift — Frontlight + e-ink controls for the attached panel.
//
// Intercepts Ctrl+function key events for display control:
//   Ctrl+F1/F2:   Brightness down/up
//   Ctrl+F5:      Full e-ink refresh (BOOX — clears ghosting)
//   Ctrl+F10:     Toggle backlight on/off
//   Ctrl+F11/F12: Warmth (amber) down/up
//
// DC-1: brightness goes to the app (window brightness), warmth via adb settings.
// BOOX: both go to the app, which writes the Onyx frontlight sysfs nodes
// (onyx_bl_br / onyx_bl_ct, world-writable, 0...max_brightness).

import AppKit

class DisplayController {
    let tcpServer: TCPServer
    let deviceSerial: String?  // For targeted ADB commands
    let family: DeviceFamily
    var currentBrightness: Int = 128
    var currentWarmth: Int = 128
    var backlightOn: Bool = true
    var savedBrightness: Int = 128
    var keyMonitor: Any?
    var systemMonitor: Any?

    var onBrightnessChanged: ((Int) -> Void)?
    var onWarmthChanged: ((Int) -> Void)?
    var onBacklightChanged: ((Bool) -> Void)?

    init(tcpServer: TCPServer, deviceSerial: String? = nil, family: DeviceFamily = .daylightDC1) {
        self.tcpServer = tcpServer
        self.deviceSerial = deviceSerial
        self.family = family
    }

    /// Read an Onyx frontlight node as 0-255 (scaled from 0...max_brightness).
    private func readOnyxLight(_ node: String) -> Int? {
        guard let raw = ADBBridge.shellOutput(["cat", "/sys/class/backlight/\(node)/brightness",
                                                "/sys/class/backlight/\(node)/max_brightness"],
                                              serial: deviceSerial) else { return nil }
        let nums = raw.split(whereSeparator: { $0.isNewline }).compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
        guard nums.count == 2, nums[1] > 0 else { return nil }
        lightLock.lock(); lightMax[node] = nums[1]; lightLock.unlock()
        return min(255, nums[0] * 255 / nums[1])
    }

    // BOOX frontlight writes go through adb: the sysfs nodes are writable by the shell
    // user but SELinux denies regular apps (EACCES), so the companion can't do it.
    // Slider ticks are coalesced — only the newest value per node is written.
    private let lightLock = NSLock()
    private var lightMax: [String: Int] = [:]
    private var pendingLight: [String: Int] = [:]
    private var lightWriterRunning = false

    private func writeOnyxLight(_ node: String, _ value255: Int) {
        lightLock.lock()
        pendingLight[node] = max(0, min(255, value255))
        let startWriter = !lightWriterRunning
        if startWriter { lightWriterRunning = true }
        lightLock.unlock()
        guard startWriter else { return }
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            while true {
                self.lightLock.lock()
                guard let (n, v) = self.pendingLight.first else {
                    self.lightWriterRunning = false
                    self.lightLock.unlock()
                    return
                }
                self.pendingLight[n] = nil
                let maxRaw = self.lightMax[n] ?? 32
                self.lightLock.unlock()
                let raw = (v * maxRaw + 127) / 255
                // One string so the device shell sees the redirect.
                ADBBridge.shell(["echo \(raw) > /sys/class/backlight/\(n)/brightness"], serial: self.deviceSerial)
            }
        }
    }

    /// Send a brightness value to the panel (0 = light off).
    private func pushBrightness(_ value: Int) {
        if family.usesOnyxFrontlight { writeOnyxLight("onyx_bl_br", value) }
        tcpServer.sendCommand(CMD_BRIGHTNESS, value: UInt8(max(0, min(255, value))))
    }

    func start() {
        // Query current values from device
        DispatchQueue.global().async { [weak self] in
            guard let self = self else { return }
            if self.family.usesOnyxFrontlight {
                if let val = self.readOnyxLight("onyx_bl_br") {
                    self.currentBrightness = val
                    self.savedBrightness = max(val, 1)
                    self.backlightOn = val > 0
                    self.tcpServer.sendCommand(CMD_BRIGHTNESS, value: UInt8(val))
                    self.onBrightnessChanged?(val)
                    self.onBacklightChanged?(self.backlightOn)
                }
                if let val = self.readOnyxLight("onyx_bl_ct") {
                    self.currentWarmth = val
                    self.tcpServer.sendCommand(CMD_WARMTH, value: UInt8(val))
                    self.onWarmthChanged?(val)
                }
                print("[Display] BOOX frontlight: brightness \(self.currentBrightness)/255, warmth \(self.currentWarmth)/255")
                return
            }
            if let val = ADBBridge.querySystemSetting("screen_brightness", serial: self.deviceSerial) {
                self.currentBrightness = val
                self.savedBrightness = val
                // Sync to TCPServer so reconnecting clients get the correct value
                self.tcpServer.sendCommand(CMD_BRIGHTNESS, value: UInt8(val))
                self.onBrightnessChanged?(val)
                print("[Display] Daylight brightness: \(val)/255")
            }
            if let val = ADBBridge.querySystemSetting("screen_brightness_amber_rate", serial: self.deviceSerial) {
                // Effective range is 0-255 (device accepts 0-1023 but caps effect at 255)
                self.currentWarmth = min(val, 255)
                self.onWarmthChanged?(self.currentWarmth)
                print("[Display] Daylight warmth: \(self.currentWarmth)/255")
            }
        }

        // NSEvent monitors for keyboard shortcuts (no TCC code-signing issues)
        keyMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard event.modifierFlags.contains(.control), let self = self else { return }
            switch event.keyCode {
            case 122: self.adjustBrightness(by: -BRIGHTNESS_STEP)  // Ctrl+F1
            case 120: self.adjustBrightness(by: BRIGHTNESS_STEP)   // Ctrl+F2
            case 96:  self.refreshScreen()                         // Ctrl+F5
            case 109: self.toggleBacklight()                       // Ctrl+F10
            case 103: self.adjustWarmth(by: -WARMTH_STEP)          // Ctrl+F11
            case 111: self.adjustWarmth(by: WARMTH_STEP)           // Ctrl+F12
            default: break
            }
        }

        systemMonitor = NSEvent.addGlobalMonitorForEvents(matching: .systemDefined) { [weak self] event in
            guard event.subtype.rawValue == 8, let self = self else { return }
            let data1 = event.data1
            let keyCode = (data1 & 0xFFFF0000) >> 16
            let keyDown = ((data1 & 0xFF00) >> 8) == 0xA
            guard keyDown && event.modifierFlags.contains(.control) else { return }
            switch keyCode {
            case 3: self.adjustBrightness(by: -BRIGHTNESS_STEP)  // Ctrl+F1 media
            case 2: self.adjustBrightness(by: BRIGHTNESS_STEP)   // Ctrl+F2 media
            case 23: self.refreshScreen()                        // Ctrl+F5 media
            case 7: self.toggleBacklight()                       // Ctrl+F10 media
            case 1: self.adjustWarmth(by: -WARMTH_STEP)          // Ctrl+F11 media
            case 0: self.adjustWarmth(by: WARMTH_STEP)           // Ctrl+F12 media
            default: break
            }
        }

        print("[Display] Ctrl+F1/F2: brightness | Ctrl+F5: e-ink refresh | Ctrl+F10: backlight toggle | Ctrl+F11/F12: warmth")
    }

    func stop() {
        if let m = keyMonitor { NSEvent.removeMonitor(m); keyMonitor = nil }
        if let m = systemMonitor { NSEvent.removeMonitor(m); systemMonitor = nil }
    }

    /// Step brightness using the same quadratic curve as the slider.
    /// Steps happen in slider-space (0–1) so they're tiny at low brightness, bigger at high.
    func adjustBrightness(by delta: Int) {
        let pos = sqrt(Double(currentBrightness) / 255.0)
        let step = 0.05 * Double(delta > 0 ? 1 : -1)
        let newPos = max(0, min(1, pos + step))
        currentBrightness = Self.brightnessFromSliderPos(newPos)
        savedBrightness = max(currentBrightness, 1)
        backlightOn = currentBrightness > 0
        tcpServer.sendCommand(CMD_BRIGHTNESS, value: UInt8(currentBrightness))
        onBrightnessChanged?(currentBrightness)
        onBacklightChanged?(backlightOn)
        print("[Display] Brightness -> \(currentBrightness)/255")
    }

    func setBrightness(_ value: Int) {
        currentBrightness = max(0, min(255, value))
        savedBrightness = max(currentBrightness, 1)
        backlightOn = currentBrightness > 0
        pushBrightness(currentBrightness)
        onBrightnessChanged?(currentBrightness)
        onBacklightChanged?(backlightOn)
    }

    /// Quadratic curve with widened landing zone at the low end.
    /// Shared with MirrorEngine.brightnessFromSliderPos (public API for the slider).
    static func brightnessFromSliderPos(_ pos: Double) -> Int {
        MirrorEngine.brightnessFromSliderPos(pos)
    }

    func adjustWarmth(by delta: Int) {
        setWarmth(currentWarmth + delta)
    }

    func setWarmth(_ value: Int) {
        currentWarmth = max(0, min(255, value))
        if family.usesOnyxFrontlight {
            writeOnyxLight("onyx_bl_ct", currentWarmth)
            tcpServer.sendCommand(CMD_WARMTH, value: UInt8(currentWarmth))
        } else {
            // DC-1: screen_brightness_amber_rate is a Daylight-protected setting that only
            // the shell user can write, not a regular Android app.
            DispatchQueue.global().async { [warmth = currentWarmth, serial = deviceSerial] in
                ADBBridge.setSystemSetting("screen_brightness_amber_rate", value: warmth, serial: serial)
            }
        }
        onWarmthChanged?(currentWarmth)
        print("[Display] Warmth -> \(currentWarmth)/255")
    }

    /// Full e-ink refresh (GC16 flash) to clear accumulated ghosting. BOOX only.
    func refreshScreen() {
        guard family == .boox else { return }
        tcpServer.sendCommand(CMD_REFRESH, value: 1)
        print("[Display] Full e-ink refresh")
    }

    /// Set the panel waveform preference (auto / quality / balanced / fast). BOOX only.
    func setEinkMode(_ mode: EinkMode) {
        guard family == .boox else { return }
        tcpServer.sendCommand(CMD_EINK_MODE, value: mode.rawValue)
        print("[Display] E-ink mode -> \(mode.label)")
    }

    func toggleBacklight() {
        if backlightOn {
            savedBrightness = max(currentBrightness, 1)
            currentBrightness = 0
            backlightOn = false
            pushBrightness(0)
            onBrightnessChanged?(0)
            onBacklightChanged?(false)
            print("[Display] Backlight OFF")
        } else {
            currentBrightness = savedBrightness
            backlightOn = true
            pushBrightness(currentBrightness)
            onBrightnessChanged?(currentBrightness)
            onBacklightChanged?(true)
            print("[Display] Backlight ON -> \(currentBrightness)/255")
        }
    }
}
