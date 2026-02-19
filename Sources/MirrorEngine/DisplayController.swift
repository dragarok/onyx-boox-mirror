// DisplayController.swift — Keyboard controls for display hardware.
//
// Intercepts Ctrl+function key events for display control:
//   Ctrl+F1/F2:   Brightness down/up
//   Ctrl+F3/F4:   Warmth down/up
//   Ctrl+F5:      Full e-ink refresh
//   Ctrl+F10:     Toggle backlight on/off

import AppKit

class DisplayController {
    let tcpServer: TCPServer
    var currentBrightness: Int = 128
    var currentWarmth: Int = 0
    var backlightOn: Bool = true
    var savedBrightness: Int = 128
    var keyMonitor: Any?
    var systemMonitor: Any?

    var onBrightnessChanged: ((Int) -> Void)?
    var onWarmthChanged: ((Int) -> Void)?
    var onBacklightChanged: ((Bool) -> Void)?

    init(tcpServer: TCPServer) {
        self.tcpServer = tcpServer
    }

    func start() {
        // Query current brightness from device
        DispatchQueue.global().async { [weak self] in
            guard let self = self else { return }
            if let val = ADBBridge.querySystemSetting("screen_brightness") {
                self.currentBrightness = val
                self.savedBrightness = val
                self.onBrightnessChanged?(val)
                print("[Display] Brightness: \(val)/255")
            }
        }

        // NSEvent monitors for keyboard shortcuts
        keyMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard event.modifierFlags.contains(.control), let self = self else { return }
            switch event.keyCode {
            case 122: self.adjustBrightness(by: -BRIGHTNESS_STEP)  // Ctrl+F1
            case 120: self.adjustBrightness(by: BRIGHTNESS_STEP)   // Ctrl+F2
            case 99:  self.adjustWarmth(by: -WARMTH_STEP)          // Ctrl+F3
            case 118: self.adjustWarmth(by: WARMTH_STEP)           // Ctrl+F4
            case 96:  self.refreshScreen()                         // Ctrl+F5
            case 109: self.toggleBacklight()                       // Ctrl+F10
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
            case 20: self.adjustWarmth(by: -WARMTH_STEP)         // Ctrl+F3 media
            case 19: self.adjustWarmth(by: WARMTH_STEP)          // Ctrl+F4 media
            case 23: self.refreshScreen()                        // Ctrl+F5 media
            case 7: self.toggleBacklight()                       // Ctrl+F10 media
            default: break
            }
        }

        print("[Display] Ctrl+F1/F2: brightness | Ctrl+F3/F4: warmth | Ctrl+F5: refresh | Ctrl+F10: backlight")
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
        sendBrightness()
        onBrightnessChanged?(currentBrightness)
        onBacklightChanged?(backlightOn)
        print("[Display] Brightness -> \(currentBrightness)/255")
    }

    func setBrightness(_ value: Int) {
        currentBrightness = max(0, min(255, value))
        savedBrightness = max(currentBrightness, 1)
        backlightOn = currentBrightness > 0
        sendBrightness()
        onBrightnessChanged?(currentBrightness)
        onBacklightChanged?(backlightOn)
    }

    /// Quadratic curve with widened landing zone at the low end.
    /// Shared with MirrorEngine.brightnessFromSliderPos (public API for the slider).
    static func brightnessFromSliderPos(_ pos: Double) -> Int {
        MirrorEngine.brightnessFromSliderPos(pos)
    }

    func toggleBacklight() {
        if backlightOn {
            savedBrightness = max(currentBrightness, 1)
            currentBrightness = 0
            backlightOn = false
            sendBrightness()
            onBrightnessChanged?(0)
            onBacklightChanged?(false)
            print("[Display] Backlight OFF")
        } else {
            currentBrightness = savedBrightness
            backlightOn = true
            sendBrightness()
            onBrightnessChanged?(currentBrightness)
            onBacklightChanged?(true)
            print("[Display] Backlight ON -> \(currentBrightness)/255")
        }
    }

    func adjustWarmth(by delta: Int) {
        currentWarmth = max(0, min(255, currentWarmth + delta))
        sendWarmth()
        onWarmthChanged?(currentWarmth)
        print("[Display] Warmth -> \(currentWarmth)/255")
    }

    func setWarmth(_ value: Int) {
        currentWarmth = max(0, min(255, value))
        sendWarmth()
        onWarmthChanged?(currentWarmth)
    }

    func refreshScreen() {
        DispatchQueue.global(qos: .userInitiated).async {
            ADBBridge.triggerEinkRefresh()
        }
        print("[Display] Full e-ink refresh")
    }

    // MARK: - ADB sysfs writes (Boox frontlight)

    /// Send brightness via adb shell → sysfs. Rescales 0-255 to 0-25.
    private func sendBrightness() {
        let scaled = (currentBrightness * 25) / 255
        DispatchQueue.global(qos: .userInitiated).async {
            ADBBridge.writeSysfs("/sys/class/backlight/onyx_bl_br/brightness", value: scaled)
        }
    }

    /// Send warmth via adb shell → sysfs. Rescales 0-255 to 0-24.
    private func sendWarmth() {
        let scaled = (currentWarmth * 24) / 255
        DispatchQueue.global(qos: .userInitiated).async {
            ADBBridge.writeSysfs("/sys/class/backlight/onyx_bl_ct/brightness", value: scaled)
        }
    }
}
