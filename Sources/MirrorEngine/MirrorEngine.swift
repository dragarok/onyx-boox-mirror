// MirrorEngine.swift — Core orchestrator for Daylight Mirror.
//
// Coordinates multiple DeviceSessions (one per connected Android device), shared
// servers (WS, HTTP), display controls, USB monitoring, and the control socket.
//
// Used by both the CLI (`daylight-mirror`) and the menu bar app (`DaylightMirror`).
// All heavy lifting is zero-GPU: vImage SIMD greyscale + LZ4 delta compression.

import Foundation
import AppKit
import IOKit
import IOKit.pwr_mgt
import Security

public class MirrorEngine: ObservableObject {
    // RELEASE: Bump this BEFORE creating a GitHub release. Also upload both
    // DaylightMirror-vX.Y.dmg (versioned) and DaylightMirror.dmg (stable name for Gumroad link)
    // to the release. Update Homebrew cask in welfvh/homebrew-tap with new version + sha256.
    public static let appVersion = "1.9.0"

    @Published public var status: MirrorStatus = .idle
    @Published public var fps: Double = 0
    @Published public var bandwidth: Double = 0
    @Published public var brightness: Int = 128
    @Published public var warmth: Int = 128
    @Published public var backlightOn: Bool = true
    @Published public var adbConnected: Bool = false
    @Published public var apkInstallStatus: String = ""
    @Published public var clientCount: Int = 0
    @Published public var totalFrames: Int = 0
    @Published public var frameSizeKB: Int = 0
    @Published public var greyMs: Double = 0
    @Published public var compressMs: Double = 0
    @Published public var jitterMs: Double = 0
    @Published public var rttMs: Double = 0
    @Published public var rttP95Ms: Double = 0
    @Published public var skippedFrames: Int = 0
    /// When true, slider changes are being applied by a profile — don't switch to Custom.
    private var applyingProfile = false
    @Published public var sharpenAmount: Double = 1.0 {
        didSet {
            for session in sessions { session.updateSharpen(sharpenAmount) }
            UserDefaults.standard.set(sharpenAmount, forKey: "sharpenAmount")
            if !applyingProfile && displayProfile != .custom { displayProfile = .custom }
        }
    }
    @Published public var contrastAmount: Double = 1.0 {
        didSet {
            for session in sessions { session.updateContrast(contrastAmount) }
            UserDefaults.standard.set(contrastAmount, forKey: "contrastAmount")
            if !applyingProfile && displayProfile != .custom { displayProfile = .custom }
        }
    }
    /// Gamma correction for reflective paper displays (~1.0-1.5 vs 2.2 for transmissive LCDs).
    /// Values > 1.0 brighten midtones, improving definition on the DC-1's reflective panel.
    @Published public var gammaAmount: Double = 1.2 {
        didSet {
            for session in sessions { session.updateGamma(gammaAmount) }
            UserDefaults.standard.set(gammaAmount, forKey: "gammaAmount")
            if !applyingProfile && displayProfile != .custom { displayProfile = .custom }
        }
    }
    /// Display profile bundles sharpen+contrast+gamma. Selecting a preset applies its values;
    /// manually adjusting any slider switches to "Custom".
    @Published public var displayProfile: DisplayProfile = .crispPaper {
        didSet {
            UserDefaults.standard.set(displayProfile.rawValue, forKey: "displayProfile")
            if displayProfile != .custom {
                applyingProfile = true
                sharpenAmount = displayProfile.sharpen
                contrastAmount = displayProfile.contrast
                gammaAmount = displayProfile.gamma
                applyingProfile = false
            }
        }
    }
    @Published public var fontSmoothingDisabled: Bool = false
    @Published public var deviceDetected: Bool = false
    @Published public var updateVersion: String? = nil
    @Published public var updateURL: String? = nil
    /// Resolution preference for DC-1 devices.
    @Published public var resolution: DisplayResolution {
        didSet {
            UserDefaults.standard.set(resolution.rawValue, forKey: "resolution")
            NSLog("[MirrorEngine] resolution changed: %@ → %@", oldValue.rawValue, resolution.rawValue)
        }
    }
    @Published public var displayMode: DisplayMode {
        didSet { UserDefaults.standard.set(displayMode.rawValue, forKey: "displayMode") }
    }
    /// Resolution preference for BOOX devices (independent of the DC-1 preference).
    @Published public var booxResolution: DisplayResolution {
        didSet { UserDefaults.standard.set(booxResolution.rawValue, forKey: "booxResolution") }
    }
    /// Send RGB to BOOX color (Kaleido) panels. Greyscale is 3x less data and lets the
    /// sharpen/contrast profile shape text exactly like on the DC-1.
    @Published public var booxColor: Bool {
        didSet { UserDefaults.standard.set(booxColor, forKey: "booxColor") }
    }
    /// BOOX panel waveform preference. Applied live, no restart.
    @Published public var einkMode: EinkMode = .auto {
        didSet {
            UserDefaults.standard.set(Int(einkMode.rawValue), forKey: "einkMode")
            displayController?.setEinkMode(einkMode)
        }
    }
    /// Whether any active session is a BOOX tablet (drives the menu bar UI).
    public var hasBoox: Bool { sessions.contains { $0.family == .boox } }

    /// Wireless: also stream to paired devices on the same Wi-Fi (Bonjour + pairing secret,
    /// see NetworkAccess). Off = USB only; the servers then listen on loopback alone.
    @Published public var wirelessEnabled: Bool = UserDefaults.standard.bool(forKey: "wirelessEnabled") {
        didSet {
            UserDefaults.standard.set(wirelessEnabled, forKey: "wirelessEnabled")
            guard wirelessEnabled != oldValue else { return }
            updateRemoteServer()
            guard status == .running else { return }
            let wasRemote = startedRemotely
            stop()
            Task { @MainActor in
                await self.waitUntilStopped()
                self.startedRemotely = wasRemote
                await self.start()
            }
        }
    }

    /// stop() tears down asynchronously — wait for it before starting again.
    @MainActor
    private func waitUntilStopped() async {
        var waited = 0
        while (status == .running || status == .stopping) && waited < 100 {
            try? await Task.sleep(for: .milliseconds(100))
            waited += 1
        }
    }

    // MARK: - Started from the device
    //
    // The companion app finds the Mac (USB tunnel or Wi-Fi), asks STATUS, shows a
    // Mirror / Second monitor chooser and sends START <mode>. See RemoteControlServer.

    private var remoteServer: RemoteControlServer?
    /// Current session was started from the device: it ends once the device has gone away.
    private var startedRemotely = false
    private var launchCompanionOnStart = true
    private var remoteIdleStop: DispatchWorkItem?
    /// How long a device-started session survives without the device (app in background,
    /// tablet asleep, out of Wi-Fi range).
    static let remoteIdleGrace: TimeInterval = 60
    private var keepAwakeAssertion: IOPMAssertionID = 0
    private var userActivityAssertion: IOPMAssertionID = 0

    private func updateRemoteServer() {
        if remoteServer == nil {
            remoteServer = RemoteControlServer { [weak self] line, viaTailnet in
                self?.handleRemote(line, viaTailnet: viaTailnet) ?? "ERR shutting down"
            }
        }
        remoteServer?.start(allowNetwork: wirelessEnabled)
        holdKeepAwake(wirelessEnabled)
    }

    /// Wireless: on a power adapter, keep the Mac from idle-sleeping (the screen still
    /// sleeps) so the device can start mirroring any time. macOS ignores this on battery.
    private func holdKeepAwake(_ on: Bool) {
        if on && keepAwakeAssertion == 0 {
            IOPMAssertionCreateWithName(kIOPMAssertionTypePreventSystemSleep as CFString,
                                        IOPMAssertionLevel(kIOPMAssertionLevelOn),
                                        "Daylight Mirror: reachable from the tablet over Wi-Fi" as CFString,
                                        &keepAwakeAssertion)
        } else if !on && keepAwakeAssertion != 0 {
            IOPMAssertionRelease(keepAwakeAssertion)
            keepAwakeAssertion = 0
        }
    }

    /// Wake the screens (as if someone touched the Mac) so there is something to capture.
    private func wakeDisplays() {
        IOPMAssertionDeclareUserActivity("Daylight Mirror: started from the tablet" as CFString,
                                         kIOPMUserActiveLocal, &userActivityAssertion)
    }

    private var statusWord: String {
        switch status {
        case .idle, .waitingForDevice: return "idle"
        case .starting: return "starting"
        case .running: return "running"
        case .stopping: return "stopping"
        case .error: return "error"
        }
    }

    @MainActor
    /// Away from home (over Tailscale) only mirror mode makes sense: a second monitor would
    /// be a screen nobody near the Mac can use, and the tablet can't see the real one.
    func handleRemote(_ line: String, viaTailnet arrivedViaTailnet: Bool = false) -> String {
        let parts = line.split(separator: " ").map { $0.lowercased() }
        let viaTailnet = arrivedViaTailnet && !booxOnUSB
        switch parts.first ?? "" {
        case "status":
            return "OK \(statusWord) \(displayMode.rawValue) \(RemoteControlServer.computerName)"
        case "start":
            var mode: DisplayMode?
            if parts.count > 1 {
                guard let m = DisplayMode(rawValue: parts[1] == "extend" ? "extended" : parts[1]) else {
                    return "ERR unknown mode (mirror, extend)"
                }
                mode = m
            }
            if viaTailnet {
                if mode == .extended { NSLog("[Remote] Second monitor asked over Tailscale — mirroring instead") }
                mode = .mirror
            }
            return remoteStart(mode: mode)
        case "release":
            guard startedRemotely, status == .running else { return "OK kept running" }
            NSLog("[Remote] Device closed the app — stopping")
            stop()
            return "OK stopping"
        case "stop":
            guard status == .running else { return "OK already stopped" }
            NSLog("[Remote] Device asked to stop")
            stop()
            return "OK stopping"
        case "refresh":
            guard status == .running, hasBoox else { return "ERR not running" }
            refreshScreen()
            return "OK refreshed"
        case "settings":
            return "OK " + remoteSettings() + (viaTailnet ? ";remote=1" : "")
        case "set":
            guard parts.count >= 3 else { return "ERR usage: SET <mode|resolution|color|eink> <value>" }
            if viaTailnet, parts[1] == "mode", parts[2] != "mirror" {
                return "ERR Second monitor needs USB or the same Wi-Fi as the Mac"
            }
            return remoteSet(parts[1], parts[2])
        default:
            return "ERR unknown command"
        }
    }

    /// BOOX settings for the device's settings panel, as `key=value` pairs joined by ";".
    /// presets = raw:Label (size) joined by "|".
    @MainActor
    private func remoteSettings() -> String {
        let presets = DisplayResolution.presets(for: .boox)
            .map { "\($0.rawValue):\($0.label) (\($0.displaySize))" }
            .joined(separator: "|")
        return [
            "state=\(statusWord)",
            "mode=\(displayMode == .mirror ? "mirror" : "extended")",
            "resolution=\(booxResolution.rawValue)",
            "color=\(booxColor ? 1 : 0)",
            "eink=\(einkMode.label.lowercased())",
            "wireless=\(wirelessEnabled ? 1 : 0)",
            "presets=\(presets)",
        ].joined(separator: ";")
    }

    @MainActor
    private func remoteSet(_ key: String, _ value: String) -> String {
        switch key {
        case "mode":
            guard let m = DisplayMode(rawValue: value == "extend" ? "extended" : value) else { return "ERR unknown mode" }
            if status == .running || status == .starting { return remoteStart(mode: m) }
            displayMode = m
            return "OK \(value)"
        case "resolution":
            guard let r = DisplayResolution.presets(for: .boox).first(where: { $0.rawValue == value }) else {
                return "ERR unknown preset"
            }
            applyBooxSettings(resolution: r)
            return "OK \(value)"
        case "color":
            guard value == "on" || value == "off" else { return "ERR use on|off" }
            applyBooxSettings(color: value == "on")
            return "OK \(value)"
        case "eink":
            guard let m = EinkMode.allCases.first(where: { $0.label.lowercased() == value }) else { return "ERR unknown e-ink mode" }
            einkMode = m
            return "OK \(value)"
        default:
            return "ERR unknown setting"
        }
    }

    /// Restart the running session (new mode / resolution / colour), keeping who started
    /// it: a device-started session stays device-started (auto-stop, no app relaunch).
    @MainActor
    private func restartKeepingOrigin() {
        let wasRemote = startedRemotely
        stop()
        Task { @MainActor in
            await self.waitUntilStopped()
            self.startedRemotely = wasRemote
            await self.start(requestedByDevice: wasRemote)
        }
    }

    @MainActor
    private func remoteStart(mode: DisplayMode?) -> String {
        let modeChanged = mode != nil && mode != displayMode
        if let mode { displayMode = mode }
        wakeDisplays()
        let modeName = displayMode == .mirror ? "mirror" : "extended"
        switch status {
        case .running where !modeChanged:
            return "OK running \(modeName)"
        case .starting:
            if modeChanged {
                // Still bringing up the previous mode: switch as soon as it's running
                Task { @MainActor in
                    while self.status == .starting { try? await Task.sleep(for: .milliseconds(100)) }
                    if self.status == .running, self.sessions.first?.displayMode != self.displayMode {
                        self.restartKeepingOrigin()
                    }
                }
            }
            return "OK starting \(modeName)"
        case .running, .stopping:
            NSLog("[Remote] Device asked for %@ — restarting", modeName)
            if status == .running {
                restartKeepingOrigin()
            } else {
                Task { @MainActor in
                    await self.waitUntilStopped()
                    self.startedRemotely = true
                    await self.start(requestedByDevice: true)
                }
            }
            return "OK starting \(modeName)"
        case .idle, .waitingForDevice, .error:
            NSLog("[Remote] Device asked to start (%@)", modeName)
            status = .idle
            startedRemotely = true
            Task { @MainActor in await self.start(requestedByDevice: true) }
            return "OK starting \(modeName)"
        }
    }

    /// A tablet reconnected over Tailscale to a second-monitor session (it left home while
    /// extended): switch to mirroring so it shows the Mac's real screen.
    /// Not when the BOOX is on USB — then Tailscale only won a start-up race and the
    /// stream moves to the cable within seconds.
    @MainActor
    private func tailnetClientArrived() {
        guard status == .running, displayMode == .extended else { return }
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let cabled = Self.booxCabled(ADBBridge.connectedDevices())
            DispatchQueue.main.async {
                guard let self, self.status == .running, self.displayMode == .extended else { return }
                if cabled {
                    NSLog("[Remote] Tailscale connection, but the BOOX is on USB — keeping second monitor")
                    return
                }
                NSLog("[Remote] Tablet is away (Tailscale) — switching to mirror mode")
                self.displayMode = .mirror
                self.restartKeepingOrigin()
            }
        }
    }

    /// Device-started sessions stop once the device has been gone for `remoteIdleGrace`.
    private func scheduleRemoteIdleCheck() {
        remoteIdleStop?.cancel()
        guard startedRemotely else { return }
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.startedRemotely, self.status == .running else { return }
            // Recount from the sessions rather than trusting the cached figure
            guard self.sessions.reduce(0, { $0 + $1.clientCount }) == 0 else { return }
            NSLog("[Remote] Device gone for %.0fs — stopping", Self.remoteIdleGrace)
            self.stop()
        }
        remoteIdleStop = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.remoteIdleGrace, execute: work)
    }

    /// A BOOX was plugged in while idle: get its app open and let it ask which mode to
    /// use (instead of guessing). Also pairs it for Wi-Fi.
    private func offerToDevice(_ device: ConnectedDevice) {
        let serial = device.serial
        NSLog("[USB] %@ attached — asking on the device which mode to use", device.displayName)
        rememberDevice(device)
        if !ADBBridge.isCompanionUpToDate(serial: serial) {
            NSLog("[USB] Installing companion app v%d", COMPANION_VERSION_CODE)
            if let error = ADBBridge.installBundledAPK(serial: serial) {
                NSLog("[USB] APK install error: %@", error)
            }
        }
        _ = ADBBridge.setupReverseTunnel(serial: serial, devicePort: REMOTE_PORT, hostPort: REMOTE_PORT)
        ADBBridge.launchApp(serial: serial, forceRestart: false,
                            pairing: (NetworkAccess.secretHex, NetworkAccess.pairingHosts()))
    }

    /// USB device appeared while idle: a BOOX gets the chooser, anything else auto-starts
    /// as before.
    private func usbAttachedWhileIdle() {
        Task.detached { [weak self] in
            var devices: [ConnectedDevice] = []
            for _ in 0..<8 {  // adb needs a moment to enumerate a fresh device
                devices = ADBBridge.supportedDevices()
                if !devices.isEmpty { break }
                try? await Task.sleep(for: .milliseconds(750))
            }
            guard let self else { return }
            if let boox = devices.first(where: { $0.deviceFamily == .boox }) {
                self.offerToDevice(boox)
            } else {
                await MainActor.run {
                    NSLog("[USB] Device connected — auto-starting mirror")
                    if self.status == .waitingForDevice { self.status = .idle }
                    Task { @MainActor in await self.start() }
                }
            }
        }
    }

    /// The Mac's LAN addresses, for showing in the menu when wireless is on.
    public var lanAddresses: [String] { NetworkAccess.lanAddresses() }

    /// Last USB-connected device, so a Wi-Fi-only start can set up the right display.
    private func rememberDevice(_ d: ConnectedDevice) {
        UserDefaults.standard.set([d.model, d.product, d.deviceName], forKey: "lastDevice")
    }

    private var lastDevice: ConnectedDevice? {
        guard let a = UserDefaults.standard.stringArray(forKey: "lastDevice"), a.count == 3 else { return nil }
        return ConnectedDevice(serial: "none", model: a[0], product: a[1], deviceName: a[2])
    }

    private func updateBooxPanel(width: UInt, height: UInt) {
        BooxPanel.update(width: width, height: height)
        UserDefaults.standard.set([Int(BooxPanel.landscape.w), Int(BooxPanel.landscape.h)], forKey: "booxPanel")
    }
    /// Families of supported devices currently on USB (refreshed on plug events) — lets
    /// the idle menu show the right controls before mirroring starts.
    @Published public var attachedFamilies: Set<DeviceFamily> = []
    /// A BOOX is on the USB cable: it's at the Mac, so Tailscale rules (mirror only) don't
    /// apply even if a connection happens to arrive over Tailscale.
    private var booxOnUSB = false

    private static func booxCabled(_ devices: [ConnectedDevice]) -> Bool {
        devices.contains { $0.deviceFamily == .boox && ADBBridge.isCabled(serial: $0.serial) }
    }

    /// Re-read attached devices over adb off the main thread; also re-detects the
    /// BOOX panel size so preset labels are accurate.
    public func refreshAttachedDevices() {
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard ADBBridge.isAvailable() else { return }
            let devices = ADBBridge.supportedDevices()
            if let boox = devices.first(where: { $0.deviceFamily == .boox }) {
                if let size = ADBBridge.displaySize(serial: boox.serial) {
                    self?.updateBooxPanel(width: size.width, height: size.height)
                }
                self?.rememberDevice(boox)
                // Let the BOOX app reach the Mac over USB (to show its mode chooser) even
                // when nothing is streaming yet.
                _ = ADBBridge.setupReverseTunnel(serial: boox.serial, devicePort: REMOTE_PORT, hostPort: REMOTE_PORT)
            }
            let families = Set(devices.map { $0.deviceFamily == .other ? .daylightDC1 : $0.deviceFamily })
            let cabled = Self.booxCabled(devices)
            DispatchQueue.main.async {
                self?.attachedFamilies = families
                self?.booxOnUSB = cabled
            }
        }
    }

    /// Active device sessions — one per connected Android device.
    /// Published so the menu bar UI can show per-device info.
    @Published public private(set) var sessions: [DeviceSession] = []
    private var wsServer: WebSocketServer?
    private var httpServer: HTTPServer?
    private var displayController: DisplayController?
    private var controlSocket: ControlSocket?
    private var usbMonitor: USBDeviceMonitor?
    private var savedMacBrightness: Float?
    /// When true, auto-start/stop mirroring based on USB device state.
    @Published public var autoMirrorEnabled: Bool = true {
        didSet { UserDefaults.standard.set(autoMirrorEnabled, forKey: "autoMirrorEnabled") }
    }
    /// When true, auto-dim the Mac's built-in display when a Daylight client connects.
    @Published public var autoDimMac: Bool = true {
        didSet { UserDefaults.standard.set(autoDimMac, forKey: "autoDimMac") }
    }
    /// When true, prevent system sleep while mirroring (enables clamshell/lid-closed use).
    /// Creates an IOPMAssertion that keeps the Mac awake even with the lid closed.
    @Published public var clamshellModeEnabled: Bool = false {
        didSet {
            UserDefaults.standard.set(clamshellModeEnabled, forKey: "clamshellModeEnabled")
            if clamshellModeEnabled && status == .running {
                createSleepAssertion()
            } else if !clamshellModeEnabled {
                releaseSleepAssertion()
            }
        }
    }
    /// Caffeinate child process for preventing sleep (including lid-close).
    /// Using caffeinate rather than IOPMAssertion because lid close is a hardware
    /// sleep trigger that overrides software assertions without a real external display.
    private(set) var caffeinateProcess: Process?
    /// Cached authorization ref for privileged pmset commands. Created once per
    /// app session when the user enters their password, reused for subsequent calls.
    private var authRef: AuthorizationRef?
    /// Observers for system wake notifications (clamshell capture recovery).
    private var wakeObserver: NSObjectProtocol?
    private var displayWakeObserver: NSObjectProtocol?
    /// Timer that checks for stalled frame delivery (backup for wake detection).
    private var stallDetectorTimer: Timer?
    /// Debounce: timestamp of last capture restart to avoid restart loops.
    private var lastCaptureRestart: Date = .distantPast
    /// Timer that polls IOKit for lid state changes (clamshell unmirror/remirror).
    private var lidMonitorTimer: Timer?
    /// Last known lid state to detect transitions.
    private var lastLidClosed: Bool = false

    public init() {
        // Load saved resolution — validate it's a known preset, fall back to Sharp.
        let saved = UserDefaults.standard.string(forKey: "resolution") ?? ""
        let loadedRes = DisplayResolution(rawValue: saved) ?? .sharp
        self.resolution = loadedRes
        let savedMode = UserDefaults.standard.string(forKey: "displayMode") ?? ""
        self.displayMode = DisplayMode(rawValue: savedMode) ?? .mirror
        let savedBoox = UserDefaults.standard.string(forKey: "booxResolution") ?? ""
        if let p = UserDefaults.standard.array(forKey: "booxPanel") as? [Int], p.count == 2 {
            BooxPanel.update(width: UInt(max(0, p[0])), height: UInt(max(0, p[1])))
        }
        let booxRes = DisplayResolution(rawValue: savedBoox) ?? .booxRetina
        self.booxResolution = booxRes.family == .boox ? booxRes : .booxRetina
        self.booxColor = UserDefaults.standard.object(forKey: "booxColor") as? Bool ?? true
        // Migration: v1.7 introduced new defaults (sharpen 1.5, contrast 1.2, gamma 1.2).
        // Old installs have sharpen=1.0, contrast=1.0, gamma=0.0 saved — override those.
        let migrated = UserDefaults.standard.bool(forKey: "v1.7_defaults_migrated")
        if !migrated {
            UserDefaults.standard.removeObject(forKey: "sharpenAmount")
            UserDefaults.standard.removeObject(forKey: "contrastAmount")
            UserDefaults.standard.removeObject(forKey: "gammaAmount")
            UserDefaults.standard.removeObject(forKey: "displayProfile")
            UserDefaults.standard.set(true, forKey: "v1.7_defaults_migrated")
        }
        let savedSharpen = UserDefaults.standard.double(forKey: "sharpenAmount")
        self.sharpenAmount = savedSharpen > 0 ? savedSharpen : 1.5
        let savedContrast = UserDefaults.standard.double(forKey: "contrastAmount")
        self.contrastAmount = savedContrast > 0 ? savedContrast : 1.2
        let savedGamma = UserDefaults.standard.double(forKey: "gammaAmount")
        self.gammaAmount = savedGamma > 0 ? savedGamma : 1.2
        let savedProfile = UserDefaults.standard.string(forKey: "displayProfile") ?? ""
        self.displayProfile = DisplayProfile(rawValue: savedProfile) ?? .crispPaper
        if UserDefaults.standard.object(forKey: "autoMirrorEnabled") != nil {
            self.autoMirrorEnabled = UserDefaults.standard.bool(forKey: "autoMirrorEnabled")
        }
        if UserDefaults.standard.object(forKey: "autoDimMac") != nil {
            self.autoDimMac = UserDefaults.standard.bool(forKey: "autoDimMac")
        }
        if UserDefaults.standard.object(forKey: "clamshellModeEnabled") != nil {
            self.clamshellModeEnabled = UserDefaults.standard.bool(forKey: "clamshellModeEnabled")
        }
        if let raw = UserDefaults.standard.object(forKey: "einkMode") as? Int,
           let mode = EinkMode(rawValue: UInt8(clamping: raw)) {
            self.einkMode = mode
        }
        // A DC-1 preset saved by older builds must not leak into the BOOX slot and vice versa.
        if resolution.family != .daylightDC1 { resolution = .sharp }
        NSLog("[MirrorEngine] init, resolution: %@, boox: %@ (%@), mode: %@, sharpen: %.1f",
              resolution.rawValue, booxResolution.rawValue, booxColor ? "RGB" : "grey",
              displayMode.rawValue, sharpenAmount)

        // Control socket — always listening so CLI can send START/STOP/etc.
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            let sock = ControlSocket(engine: self)
            sock.start()
            self.controlSocket = sock
            self.updateRemoteServer()
        }

        // USB device monitoring — auto-detect connect/disconnect
        DispatchQueue.global(qos: .utility).async {
            if ADBBridge.isAvailable() { ADBBridge.ensureServerRunning() }
            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                let monitor = USBDeviceMonitor()
                monitor.onDeviceConnected = { [weak self] in
                    guard let self = self else { return }
                    self.deviceDetected = true
                    // adb needs a moment to enumerate a freshly plugged device
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { self.refreshAttachedDevices() }
                    if self.autoMirrorEnabled && (self.status == .idle || self.status == .waitingForDevice) {
                        self.usbAttachedWhileIdle()
                    } else if self.autoMirrorEnabled && self.status == .stopping {
                        NSLog("[USB] Device connected while stopping — will restart after teardown")
                        Task { @MainActor in
                            while self.status == .stopping {
                                try? await Task.sleep(for: .milliseconds(200))
                            }
                            if self.status == .idle {
                                NSLog("[USB] Teardown complete")
                                self.usbAttachedWhileIdle()
                            }
                        }
                    } else if self.status == .running {
                        NSLog("[USB] Device reconnected — re-establishing tunnels")
                        self.reconnect()
                    }
                }
                monitor.onDeviceDisconnected = { [weak self] in
                    guard let self = self else { return }
                    self.deviceDetected = false
                    self.refreshAttachedDevices()
                    // Wireless: keep streaming — the device falls back to Wi-Fi on its own
                    if self.autoMirrorEnabled && self.status == .running && !self.wirelessEnabled {
                        NSLog("[USB] Device disconnected — stopping mirror")
                        self.stop()
                        self.status = .waitingForDevice
                    }
                }
                monitor.start()
                self.usbMonitor = monitor
                self.deviceDetected = monitor.isDeviceConnected
                self.refreshAttachedDevices()
            }
        }

        // Check for updates in the background
        Task { @MainActor in
            if let release = await UpdateChecker.check(currentVersion: Self.appVersion) {
                self.updateVersion = release.version
                self.updateURL = release.url
                NSLog("[Update] New version available: %@", release.version)
            }
        }
    }

    private var globalKeyMonitor: Any?
    private var globalSystemMonitor: Any?

    /// Call once after init, from the main thread, to register Ctrl+F8 global hotkey.
    public func setupGlobalShortcut() {
        NSLog("[Global] Setting up Ctrl+F8 hotkey via NSEvent monitors...")

        globalKeyMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if event.modifierFlags.contains(.control) && event.keyCode == 100 {
                NSLog("[Global] Ctrl+F8 pressed — toggling")
                self?.toggleMirror()
            }
        }

        globalSystemMonitor = NSEvent.addGlobalMonitorForEvents(matching: .systemDefined) { [weak self] event in
            guard event.subtype.rawValue == 8 else { return }
            let data1 = event.data1
            let keyCode = (data1 & 0xFFFF0000) >> 16
            let keyDown = ((data1 & 0xFF00) >> 8) == 0xA
            let ctrl = event.modifierFlags.contains(.control)
            if keyDown && ctrl && keyCode == 16 {
                NSLog("[Global] Ctrl+F8 media key — toggling")
                self?.toggleMirror()
            }
        }

        NSLog("[Global] Ctrl+F8 hotkey registered (key=%@, system=%@)",
              globalKeyMonitor != nil ? "yes" : "no",
              globalSystemMonitor != nil ? "yes" : "no")
    }

    private func toggleMirror() {
        DispatchQueue.main.async {
            if self.status == .running {
                self.stop()
            } else if self.status == .idle || self.status == .waitingForDevice {
                Task { @MainActor in await self.start() }
            }
        }
    }

    // MARK: - Permission & Device Checks

    public static func hasScreenRecordingPermission() -> Bool { CGPreflightScreenCaptureAccess() }
    public static func requestScreenRecordingPermission() { CGRequestScreenCaptureAccess() }
    public static func hasAccessibilityPermission() -> Bool { AXIsProcessTrusted() }
    public static func requestAccessibilityPermission() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary
        AXIsProcessTrustedWithOptions(options)
    }
    public static func hasADB() -> Bool { ADBBridge.isAvailable() }
    public static func hasDevice() -> Bool { ADBBridge.connectedDevice() != nil }
    public static var setupCompleted: Bool {
        get { UserDefaults.standard.bool(forKey: "setupCompleted") }
        set { UserDefaults.standard.set(newValue, forKey: "setupCompleted") }
    }
    public static var allPermissionsGranted: Bool {
        hasScreenRecordingPermission() && hasAccessibilityPermission()
    }

    // MARK: - Start / Stop

    @MainActor
    /// `requestedByDevice`: the device's chooser asked for this — its app is already open,
    /// and the session ends once the device goes away.
    public func start(requestedByDevice: Bool = false) async {
        guard status == .idle || status != .starting else { return }
        launchCompanionOnStart = !requestedByDevice

        if fontSmoothingDisabled { setFontSmoothing(enabled: false) }

        if !Self.hasScreenRecordingPermission() {
            Self.requestScreenRecordingPermission()
            status = .error("Grant Screen Recording permission in System Settings, then retry")
            return
        }

        status = .starting

        // Shared servers (WS for browser preview, HTTP for fallback page)
        do {
            let ws = try WebSocketServer(port: WS_PORT)
            ws.start()
            wsServer = ws

            let http = try HTTPServer(port: HTTP_PORT, width: resolution.width, height: resolution.height)
            http.start()
            httpServer = http
        } catch {
            status = .error("Server failed: \(error.localizedDescription)")
            return
        }

        // Detect connected devices and create a session for each
        if ADBBridge.isAvailable() {
            ADBBridge.ensureServerRunning()
        }

        // Only DC-1 / BOOX get sessions — phones and emulators on adb are ignored.
        let devices = ADBBridge.isAvailable() ? ADBBridge.supportedDevices() : []
        if devices.isEmpty {
            // Wireless: set up the display for the last device seen over USB, then wait
            // for it to connect over Wi-Fi.
            if wirelessEnabled, let last = lastDevice {
                NSLog("[Engine] No USB device — waiting for %@ over Wi-Fi", last.displayName)
                let session = DeviceSession(
                    port: TCP_PORT, resolution: resolutionForDevice(last),
                    displayMode: displayMode, device: last,
                    useColor: last.deviceFamily == .boox && booxColor, wireless: true
                )
                await startSession(session, wsServer: wsServer)
            } else {
                NSLog("[Engine] No devices found — creating default session (DC-1 resolution)")
                let pseudoDevice = ConnectedDevice(serial: "none", model: "unknown")
                let session = DeviceSession(
                    port: TCP_PORT, resolution: resolution,
                    displayMode: displayMode, device: pseudoDevice, wireless: wirelessEnabled
                )
                await startSession(session, wsServer: wsServer)
            }
        } else {
            // Sort: DC-1 first (gets primary port 8888), then other devices.
            // This ensures stable port assignment regardless of USB enumeration order.
            let sorted = devices.sorted { a, b in
                a.deviceFamily == .daylightDC1 && b.deviceFamily != .daylightDC1
            }
            // Size BOOX presets to the panel's real drawable area before creating displays
            if let boox = sorted.first(where: { $0.deviceFamily == .boox }),
               let size = ADBBridge.displaySize(serial: boox.serial) {
                updateBooxPanel(width: size.width, height: size.height)
                NSLog("[Engine] BOOX panel: %dx%d drawable", BooxPanel.landscape.w, BooxPanel.landscape.h)
            }
            var port = TCP_PORT
            for (_, device) in sorted.enumerated() {
                let res = resolutionForDevice(device)
                // Primary device uses user's display mode preference.
                // Additional devices always get their own extended display.
                let mode: DisplayMode = (port == TCP_PORT) ? displayMode : .extended
                if port == TCP_PORT { rememberDevice(device) }
                let session = DeviceSession(
                    port: port, resolution: res,
                    displayMode: mode, device: device,
                    useColor: device.deviceFamily == .boox && booxColor,
                    wireless: wirelessEnabled && port == TCP_PORT
                )
                // Primary session (port 8888) gets the WS server for browser preview
                let ws: WebSocketServer? = (port == TCP_PORT) ? wsServer : nil
                await startSession(session, wsServer: ws)
                port += 1
                // Stagger virtual display creation — macOS needs time to register each one
                if sorted.count > 1 {
                    try? await Task.sleep(for: .seconds(2))
                }
            }
        }

        // Display controller — attach to the primary panel's TCP server for
        // brightness/warmth (DC-1 first, otherwise a BOOX).
        if let panel = sessions.first(where: { $0.family == .daylightDC1 }) ?? sessions.first(where: { $0.family == .boox }),
           let tcp = panel.tcpServer {
            // Wi-Fi-only session: "none" makes adb calls fail instead of reaching some other
            // attached device (e.g. a phone on wireless debugging).
            let serial = panel.device.serial != "none" ? panel.device.serial : (panel.wireless ? "none" : nil)
            let dc = DisplayController(tcpServer: tcp, deviceSerial: serial, family: panel.family)
            dc.onBrightnessChanged = { [weak self] val in
                DispatchQueue.main.async { self?.brightness = val }
            }
            dc.onWarmthChanged = { [weak self] val in
                DispatchQueue.main.async { self?.warmth = val }
            }
            dc.onBacklightChanged = { [weak self] on in
                DispatchQueue.main.async { self?.backlightOn = on }
            }
            dc.start()
            dc.setEinkMode(einkMode)
            displayController = dc
            brightness = dc.currentBrightness
            warmth = dc.currentWarmth
            backlightOn = dc.backlightOn
        }

        adbConnected = sessions.contains { $0.adbConnected }
        apkInstallStatus = ""
        status = .running

        if clamshellModeEnabled { createSleepAssertion() }
        // A device can connect before its session is in `sessions` (the tunnel is already
        // up, so it connects the moment the server listens) — recount now that it is.
        aggregateClientCount()
        if startedRemotely && clientCount == 0 { scheduleRemoteIdleCheck() }

        let sessionSummary = sessions.map { "\($0.device.model)@\($0.port):\($0.resolution.rawValue)" }
        print("---")
        print("Sessions: \(sessionSummary.joined(separator: ", "))")
        print("WS: ws://localhost:\(WS_PORT) | HTTP: http://localhost:\(HTTP_PORT)")
    }

    /// Start a single DeviceSession and wire up its stats callbacks.
    @MainActor
    private func startSession(_ session: DeviceSession, wsServer: WebSocketServer?) async {
        session.relaunchCompanion = launchCompanionOnStart
        // Wire stats back to engine's @Published properties (aggregated across sessions)
        session.onStatsChanged = { [weak self] in
            DispatchQueue.main.async { self?.aggregateStats() }
        }
        session.onTailnetClient = { [weak self] in
            DispatchQueue.main.async { self?.tailnetClientArrived() }
        }
        session.onClientCountChanged = { [weak self] _ in
            DispatchQueue.main.async { self?.aggregateClientCount() }
        }
        session.onLatencyStats = { [weak self] stats in
            DispatchQueue.main.async {
                self?.rttMs = stats.rttAvgMs
                self?.rttP95Ms = stats.rttP95Ms
            }
        }

        do {
            try await session.start(
                wsServer: wsServer,
                sharpenAmount: sharpenAmount,
                contrastAmount: contrastAmount,
                gammaAmount: gammaAmount
            )
        } catch {
            NSLog("[Engine] Session %@ failed: %@", session.device.serial, error.localizedDescription)
        }

        sessions.append(session)
    }

    /// Pick the right resolution for a detected device based on its family.
    /// Resolution for a given device. Currently all devices use the same resolution.
    /// Future: auto-detect panel size and generate appropriate presets.
    private func resolutionForDevice(_ device: ConnectedDevice) -> DisplayResolution {
        device.deviceFamily == .boox ? booxResolution : resolution
    }

    /// Aggregate stats from all sessions for the UI.
    private func aggregateStats() {
        // Show primary session's stats (first session, typically DC-1)
        guard let primary = sessions.first else { return }
        fps = primary.fps
        bandwidth = sessions.reduce(0) { $0 + $1.bandwidth }
        totalFrames = sessions.reduce(0) { $0 + $1.totalFrames }
        frameSizeKB = primary.frameSizeKB
        greyMs = primary.greyMs
        compressMs = primary.compressMs
        jitterMs = primary.jitterMs
        skippedFrames = sessions.reduce(0) { $0 + $1.skippedFrames }
    }

    /// Aggregate client count from all sessions.
    private func aggregateClientCount() {
        let total = sessions.reduce(0) { $0 + $1.clientCount }
        let wasConnected = clientCount > 0
        clientCount = total
        if startedRemotely {
            if total == 0 { scheduleRemoteIdleCheck() } else { remoteIdleStop?.cancel() }
        }

        // Auto-dim Mac when any client connects — mirror mode only: as a second monitor
        // the Mac screen is still in use. Restoring still runs if we dimmed earlier.
        if autoDimMac {
            if total > 0 && !wasConnected && displayMode == .mirror {
                if let current = MacBrightness.get() {
                    savedMacBrightness = current
                    MacBrightness.set(0)
                    NSLog("[Mac] Auto-dimmed (was %.2f)", current)
                } else {
                    NSLog("[Mac] Auto-dim failed: could not read current brightness")
                }
            } else if total == 0 && wasConnected {
                if let saved = savedMacBrightness {
                    MacBrightness.set(saved)
                    savedMacBrightness = nil
                    NSLog("[Mac] Brightness restored to %.2f", saved)
                }
            }
        }
    }

    public func stop() {
        guard status == .running || status == .waitingForDevice else { return }
        if status == .waitingForDevice { status = .idle; return }
        DispatchQueue.main.async { self.status = .stopping }
        startedRemotely = false
        remoteIdleStop?.cancel()

        releaseSleepAssertion()

        if let saved = savedMacBrightness {
            MacBrightness.set(saved)
            savedMacBrightness = nil
            print("[Mac] Brightness restored to \(saved)")
        }

        Task {
            displayController?.stop()
            displayController = nil

            for session in sessions {
                await session.stop()
            }
            sessions.removeAll()

            wsServer?.stop()
            httpServer?.stop()
            wsServer = nil
            httpServer = nil

            if self.fontSmoothingDisabled {
                self.setFontSmoothing(enabled: true)
            }

            await MainActor.run {
                status = .idle
                fps = 0
                bandwidth = 0
                clientCount = 0
                totalFrames = 0
                adbConnected = false
            }

            print("Mirror stopped")
        }
    }

    /// Lightweight reconnect: re-establish ADB tunnels and relaunch apps
    /// without tearing down virtual displays, captures, or servers.
    public func reconnect() {
        guard status == .running else { return }
        print("[MirrorEngine] Reconnecting ADB...")
        let wireless = wirelessEnabled
        Task.detached {
            // adb needs a moment to enumerate a freshly plugged device
            var usb: [ConnectedDevice] = []
            for _ in 0..<8 {
                usb = ADBBridge.supportedDevices()
                if !usb.isEmpty { break }
                try? await Task.sleep(for: .milliseconds(750))
            }
            for session in self.sessions {
                // A Wi-Fi session may have no serial (started without USB) or a stale
                // tunnel from before the unplug — always re-tunnel when wireless.
                var serial = session.device.serial
                if serial == "none" {
                    guard let d = usb.first(where: { $0.deviceFamily == session.family }) else { continue }
                    serial = d.serial
                }
                guard usb.contains(where: { $0.serial == serial }) else { continue }
                if session.adbConnected && !wireless { continue }
                let tunnelOK = ADBBridge.setupReverseTunnel(
                    serial: serial,
                    devicePort: TCP_PORT,
                    hostPort: session.port
                )
                if tunnelOK {
                    // Input tunnel — non-blocking; touch disabled if this fails
                    let inputOK = ADBBridge.setupReverseTunnel(
                        serial: serial,
                        devicePort: INPUT_PORT,
                        hostPort: INPUT_PORT
                    )
                    if !inputOK { NSLog("[ADB] Input tunnel failed for %@ — touch disabled", serial) }
                    _ = ADBBridge.setupReverseTunnel(serial: serial, devicePort: REMOTE_PORT, hostPort: REMOTE_PORT)
                    // Refresh pairing; the app notices the tunnel and moves off Wi-Fi itself
                    ADBBridge.launchApp(serial: serial, forceRestart: false,
                                        pairing: (NetworkAccess.secretHex, NetworkAccess.pairingHosts()))
                    NSLog("[ADB] Reconnected %@ over USB", serial)
                }
            }
            await MainActor.run {
                self.adbConnected = self.sessions.contains { $0.adbConnected }
            }
        }
    }

    // MARK: - Display Controls

    public static func brightnessFromSliderPos(_ pos: Double) -> Int {
        if pos < 0.03 { return 0 }
        let raw = pos * pos * 255.0
        if raw < 1.5 { return 1 }
        return min(255, Int(raw))
    }

    public func setBrightness(_ value: Int) {
        displayController?.setBrightness(value)
        brightness = max(0, min(255, value))
        backlightOn = brightness > 0
    }

    public func setWarmth(_ value: Int) {
        displayController?.setWarmth(value)
        warmth = max(0, min(255, value))
    }

    /// Full e-ink refresh on the BOOX panel (clears ghosting). Ctrl+F5.
    public func refreshScreen() {
        displayController?.refreshScreen()
    }

    /// Change the BOOX preset or pixel format. Needs a new virtual display and capture
    /// buffers, so a running mirror is restarted.
    public func applyBooxSettings(resolution newRes: DisplayResolution? = nil, color: Bool? = nil) {
        var changed = false
        if let r = newRes, r.family == .boox, r != booxResolution { booxResolution = r; changed = true }
        if let c = color, c != booxColor { booxColor = c; changed = true }
        guard changed, status == .running, hasBoox else { return }
        Task { @MainActor in self.restartKeepingOrigin() }
    }

    public func toggleBacklight() {
        displayController?.toggleBacklight()
        if let dc = displayController {
            brightness = dc.currentBrightness
            backlightOn = dc.backlightOn
        }
    }

    // MARK: - Sleep Prevention (Clamshell Mode)

    /// Disable system sleep entirely via `pmset disablesleep 1`. This is the only
    /// reliable way to prevent lid-close sleep on battery — caffeinate assertions
    /// are ignored for hardware lid-close events. Requires admin privileges, which
    /// are requested via osascript the first time. Also starts caffeinate as a
    /// backup for idle sleep prevention.
    private func createSleepAssertion() {
        guard caffeinateProcess == nil else { return }

        // pmset disablesleep 1 — requires sudo, prevents ALL sleep including lid close
        setSleepDisabled(true)

        // caffeinate as backup for idle sleep
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/caffeinate")
        process.arguments = ["-di"]
        do {
            try process.run()
            caffeinateProcess = process
            startLidMonitor()
            NSLog("[Clamshell] caffeinate started (pid: %d)", process.processIdentifier)
        } catch {
            NSLog("[Clamshell] Failed to start caffeinate: %@", "\(error)")
        }
    }

    /// Re-enable system sleep and stop caffeinate.
    private func releaseSleepAssertion() {
        setSleepDisabled(false)
        guard let process = caffeinateProcess else { return }
        process.terminate()
        caffeinateProcess = nil
        stopWakeListeners()
        NSLog("[Clamshell] caffeinate stopped")
    }

    /// On launch, check if a previous crash left SleepDisabled=1 and restore it.
    public func restoreSleepIfNeeded() {
        guard !clamshellModeEnabled else { return } // clamshell is on, leave it
        let service = IOServiceGetMatchingService(kIOMainPortDefault,
            IOServiceMatching("IOPMrootDomain"))
        guard service != IO_OBJECT_NULL else { return }
        defer { IOObjectRelease(service) }
        if let prop = IORegistryEntryCreateCFProperty(service,
            "SleepDisabled" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue(),
           let val = prop as? Bool, val == true {
            NSLog("[Clamshell] SleepDisabled=1 found on launch (previous crash?) — restoring")
            setSleepDisabled(false)
        }
    }

    /// Set `pmset disablesleep` via cached privileged execution. Uses the Security
    /// framework's AuthorizationExecuteWithPrivileges (loaded via dlsym) to run pmset
    /// as root. The authorization ref is created once per app session — the system
    /// password dialog appears on first use, then subsequent calls reuse the cached auth.
    private func setSleepDisabled(_ disabled: Bool) {
        let value = disabled ? "1" : "0"

        // Create and cache authorization ref — only prompts once per app session
        if authRef == nil {
            var auth: AuthorizationRef?
            let status = AuthorizationCreate(nil, nil, [], &auth)
            guard status == errAuthorizationSuccess, let a = auth else {
                NSLog("[Clamshell] Failed to create AuthorizationRef (status %d)", status)
                return
            }
            authRef = a
        }

        guard let auth = authRef else { return }

        // Pre-authorize: shows password dialog first time, cached after
        var rightName = kAuthorizationRightExecute.withCString { strdup($0)! }
        defer { free(rightName) }
        var item = AuthorizationItem(name: rightName, valueLength: 0, value: nil, flags: 0)
        var rights = AuthorizationRights(count: 1, items: &item)
        let flags: AuthorizationFlags = [.interactionAllowed, .extendRights, .preAuthorize]

        let authStatus = AuthorizationCopyRights(auth, &rights, nil, flags, nil)
        guard authStatus == errAuthorizationSuccess else {
            NSLog("[Clamshell] Authorization denied (status %d)", authStatus)
            return
        }

        // Load AuthorizationExecuteWithPrivileges from Security framework (deprecated
        // but still functional — the standard pattern used by Sparkle, Homebrew, etc.)
        typealias AuthExecFn = @convention(c) (
            AuthorizationRef,
            UnsafePointer<CChar>,
            AuthorizationFlags,
            UnsafePointer<UnsafeMutablePointer<CChar>?>,
            UnsafeMutablePointer<UnsafeMutablePointer<FILE>?>?
        ) -> OSStatus

        guard let secHandle = dlopen("/System/Library/Frameworks/Security.framework/Security", RTLD_LAZY),
              let sym = dlsym(secHandle, "AuthorizationExecuteWithPrivileges") else {
            NSLog("[Clamshell] Failed to load AuthorizationExecuteWithPrivileges")
            // Fallback to osascript
            setSleepDisabledFallback(disabled)
            return
        }
        let execFn = unsafeBitCast(sym, to: AuthExecFn.self)

        let tool = "/usr/bin/pmset"
        let arg1 = strdup("disablesleep")!
        let arg2 = strdup(value)!
        defer { free(arg1); free(arg2) }
        var args: [UnsafeMutablePointer<CChar>?] = [arg1, arg2, nil]

        let execStatus = execFn(auth, tool, [], &args, nil)
        if execStatus == errAuthorizationSuccess {
            NSLog("[Clamshell] pmset disablesleep %@", value)
        } else {
            NSLog("[Clamshell] pmset execution failed (status %d) — trying fallback", execStatus)
            setSleepDisabledFallback(disabled)
        }
    }

    /// Fallback: use osascript if AuthorizationExecuteWithPrivileges is unavailable.
    private func setSleepDisabledFallback(_ disabled: Bool) {
        let value = disabled ? "1" : "0"
        let script = "do shell script \"/usr/bin/pmset disablesleep \(value)\" with administrator privileges"
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", script]
        do {
            try process.run()
            process.waitUntilExit()
            if process.terminationStatus == 0 {
                NSLog("[Clamshell] pmset disablesleep %@ (fallback)", value)
            } else {
                NSLog("[Clamshell] pmset disablesleep fallback failed (status %d)", process.terminationStatus)
            }
        } catch {
            NSLog("[Clamshell] Failed to run pmset fallback: %@", "\(error)")
        }
    }

    /// Start monitoring lid state via IOKit. When the lid closes, the built-in
    /// display goes offline which breaks the mirror relationship. When the lid
    /// reopens, we re-mirror and restart the capture to restore the pipeline.
    private func startLidMonitor() {
        guard lidMonitorTimer == nil else { return }
        lastLidClosed = Self.isLidClosed()

        lidMonitorTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            guard let self = self, self.status == .running, self.clamshellModeEnabled else { return }
            let closed = Self.isLidClosed()
            if closed != self.lastLidClosed {
                self.lastLidClosed = closed
                if closed {
                    NSLog("[Clamshell] Lid closed — mirror will break when built-in goes offline")
                } else {
                    NSLog("[Clamshell] Lid opened — re-mirroring and restarting capture")
                    // Delay to let macOS finish bringing the built-in display back online
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                        for session in self.sessions {
                            if session.displayMode == .mirror {
                                session.remirror()
                            }
                        }
                        // Restart capture after re-mirror settles
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                            Task {
                                for session in self.sessions {
                                    await session.restartCapture()
                                }
                            }
                        }
                    }
                }
            }
        }
        NSLog("[Clamshell] Lid monitor started (polling 0.5s)")
    }

    private func stopLidMonitor() {
        lidMonitorTimer?.invalidate()
        lidMonitorTimer = nil
    }

    /// Query IOKit for the current lid state.
    static func isLidClosed() -> Bool {
        let service = IOServiceGetMatchingService(kIOMainPortDefault,
            IOServiceMatching("IOPMrootDomain"))
        guard service != IO_OBJECT_NULL else { return false }
        defer { IOObjectRelease(service) }
        if let prop = IORegistryEntryCreateCFProperty(service,
            "AppleClamshellState" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() {
            return (prop as? Bool) == true
        }
        return false
    }

    private func stopWakeListeners() {
        let ws = NSWorkspace.shared.notificationCenter
        if let obs = wakeObserver { ws.removeObserver(obs); wakeObserver = nil }
        if let obs = displayWakeObserver { ws.removeObserver(obs); displayWakeObserver = nil }
        stallDetectorTimer?.invalidate()
        stallDetectorTimer = nil
        stopLidMonitor()
    }

    public func setFontSmoothing(enabled: Bool) {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/defaults")
        if enabled {
            task.arguments = ["delete", "-g", "AppleFontSmoothing"]
        } else {
            task.arguments = ["write", "-g", "AppleFontSmoothing", "-int", "0"]
        }
        try? task.run()
        task.waitUntilExit()
        fontSmoothingDisabled = !enabled
        print("[Engine] Font smoothing \(enabled ? "enabled" : "disabled")")
    }
}
