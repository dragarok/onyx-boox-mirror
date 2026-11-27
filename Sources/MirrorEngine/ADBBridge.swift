// ADBBridge.swift — ADB communication layer for Daylight Mirror.
//
// Manages the adb binary (bundled or PATH), reverse tunnels, device queries,
// companion APK installation, and app launching on the Daylight DC-1.
//
// KEY DESIGN: All adb commands run via `/bin/sh -c` to inherit the user's full
// shell environment. This is critical because GUI apps (.app bundles launched via
// Finder/Spotlight) get a stripped environment — adb may start a SEPARATE server
// instance that doesn't know about the USB device. Running through sh ensures we
// talk to the SAME adb server as the user's terminal.

import Foundation

/// A USB-connected Android device detected by ADB.
public struct ConnectedDevice: Identifiable {
    public var id: String { serial }
    public let serial: String
    public let model: String
    /// `product:` field from `adb devices -l` (e.g. "BOOX" on Onyx tablets).
    public let product: String
    /// `device:` field from `adb devices -l` (e.g. "BOOX" on Onyx tablets).
    public let deviceName: String

    public init(serial: String, model: String, product: String = "", deviceName: String = "") {
        self.serial = serial
        self.model = model
        self.product = product
        self.deviceName = deviceName
    }

    /// Infer device family from the fields reported by `adb devices -l`.
    ///
    /// BOOX tablets report `product:BOOX device:BOOX` with the model in `model:`
    /// (e.g. TabUltraC). Match on those exact fields, not on "onyx": Xiaomi/POCO
    /// phones use the codename "onyx" (`product:onyx_in device:onyx`).
    public var deviceFamily: DeviceFamily {
        let m = model.lowercased()
        let p = product.lowercased()
        let d = deviceName.lowercased()
        if m.contains("dc-1") || m.contains("daylight") || m.contains("dc1") {
            return .daylightDC1
        }
        if p == "boox" || d == "boox" || m.hasPrefix("boox") || m.contains("tabultra") {
            return .boox
        }
        // Legacy behaviour: a lone unidentified device is treated as a DC-1 by the
        // engine (see MirrorEngine.supportedDevices). Here we report what it is.
        return .other
    }

    /// Short name for menus and logs, e.g. "BOOX TabUltraC" or "DC-1".
    public var displayName: String {
        switch deviceFamily {
        case .daylightDC1: return "DC-1"
        case .boox: return "BOOX \(model)"
        case .other: return model
        }
    }
}

struct ADBBridge {
    /// Resolved path to the adb binary. Prefers system adb (user-managed, up-to-date),
    /// falls back to bundled copy (for users without Homebrew/Android SDK).
    private static let resolvedADBPath: String? = {
        // 1. System adb on PATH — check common locations directly since GUI apps
        //    don't have Homebrew paths in their PATH.
        // Android Studio installs adb into the SDK, which is never on a GUI app's PATH.
        let env = ProcessInfo.processInfo.environment
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let sdkPaths = [env["ANDROID_HOME"], env["ANDROID_SDK_ROOT"], "\(home)/Library/Android/sdk"]
            .compactMap { $0 }
            .map { "\($0)/platform-tools/adb" }
        let knownPaths = [
            "/opt/homebrew/bin/adb",      // Apple Silicon Homebrew
            "/usr/local/bin/adb",          // Intel Homebrew
        ] + sdkPaths
        for path in knownPaths {
            if FileManager.default.isExecutableFile(atPath: path) {
                NSLog("[ADB] Using system adb: %@", path)
                return path
            }
        }
        // 2. Try `which adb` via shell (catches custom installs)
        let pipe = Pipe()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-l", "-c", "which adb"]
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        try? process.run()
        process.waitUntilExit()
        if process.terminationStatus == 0,
           let path = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !path.isEmpty {
            NSLog("[ADB] Using system adb (via which): %@", path)
            return path
        }
        // 3. Fallback: bundled adb inside the .app bundle (Resources/adb).
        if let bundled = Bundle.main.resourcePath.map({ $0 + "/adb" }),
           FileManager.default.isExecutableFile(atPath: bundled) {
            NSLog("[ADB] Using bundled adb (no system adb found): %@", bundled)
            return bundled
        }
        NSLog("[ADB] No adb binary found (checked known paths + which + bundle)")
        return nil
    }()

    /// Shell environment loaded once from login shell. This ensures adb commands
    /// see the same env as the user's terminal (ANDROID_HOME, PATH, HOME, etc.).
    private static let shellEnvironment: [String: String] = {
        let pipe = Pipe()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-l", "-c", "env"]
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        try? process.run()
        process.waitUntilExit()
        let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        var env: [String: String] = [:]
        for line in output.split(separator: "\n") {
            if let eqIdx = line.firstIndex(of: "=") {
                let key = String(line[line.startIndex..<eqIdx])
                let value = String(line[line.index(after: eqIdx)...])
                env[key] = value
            }
        }
        // Ensure HOME is always set
        if env["HOME"] == nil { env["HOME"] = NSHomeDirectory() }
        NSLog("[ADB] Shell environment loaded (%d vars, HOME=%@, ANDROID_HOME=%@)",
              env.count, env["HOME"] ?? "nil", env["ANDROID_HOME"] ?? "nil")
        return env
    }()

    /// Create a Process configured to run adb with the given arguments.
    /// Uses the full shell environment to ensure we talk to the same adb server
    /// as the user's terminal. When serial is provided, prepends `-s <serial>`.
    private static func makeADBProcess(_ arguments: [String], serial: String? = nil) -> Process? {
        guard let adbPath = resolvedADBPath else { return nil }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: adbPath)
        var args: [String] = []
        if let serial = serial {
            args += ["-s", serial]
        }
        args += arguments
        process.arguments = args
        process.environment = shellEnvironment
        return process
    }

    static func isAvailable() -> Bool {
        return resolvedADBPath != nil
    }

    /// Ensure the ADB server daemon is running. Called once before first ADB operation.
    /// Without this, `adb devices` can silently fail on first use.
    @discardableResult
    static func ensureServerRunning() -> Bool {
        let stderr = Pipe()
        guard let process = makeADBProcess(["start-server"]) else { return false }
        process.standardOutput = FileHandle.nullDevice
        process.standardError = stderr
        do {
            try process.run()
        } catch {
            NSLog("[ADB] start-server: failed to launch — %@", "\(error)")
            return false
        }
        process.waitUntilExit()
        if process.terminationStatus == 0 {
            NSLog("[ADB] Server running")
            return true
        }
        let errOutput = String(data: stderr.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        NSLog("[ADB] WARNING: start-server failed (exit %d) — %@", process.terminationStatus, errOutput.trimmingCharacters(in: .whitespacesAndNewlines))
        return false
    }

    /// Devices we can mirror to. Phones, emulators and unknown tablets are skipped so
    /// we never create a virtual display or install the APK on them. If exactly one
    /// device is attached and it is unidentified, it is treated as a DC-1 (upstream
    /// behaviour — older DC-1 firmware reports a generic model string).
    static func supportedDevices() -> [ConnectedDevice] {
        filterSupported(connectedDevices())
    }

    /// DC-1 / BOOX only. Upstream treats a lone unidentified device as a DC-1 (some units
    /// report an unexpected model) — but only when it's on a USB cable: phones attached
    /// over wireless adb ("ip:port" serials) and emulators must never get a session.
    static func filterSupported(_ all: [ConnectedDevice]) -> [ConnectedDevice] {
        let supported = all.filter { $0.deviceFamily.isSupported }
        if supported.isEmpty, all.count == 1, let lone = all.first,
           !lone.serial.contains(":"), !lone.serial.hasPrefix("emulator-") {
            return all
        }
        return supported
    }

    /// Returns the serial of the first connected device (legacy convenience).
    static func connectedDevice() -> String? {
        return supportedDevices().first?.serial
    }

    /// Detect all connected USB devices. Parses `adb devices -l` for serial + model.
    static func connectedDevices() -> [ConnectedDevice] {
        let stdout = Pipe()
        let stderr = Pipe()
        guard let process = makeADBProcess(["devices", "-l"]) else {
            NSLog("[ADB] connectedDevices: no adb binary")
            return []
        }
        process.standardOutput = stdout
        process.standardError = stderr
        do {
            try process.run()
        } catch {
            NSLog("[ADB] connectedDevices: failed to launch — %@", "\(error)")
            return []
        }
        process.waitUntilExit()
        let output = String(data: stdout.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        if process.terminationStatus != 0 {
            let errOutput = String(data: stderr.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            NSLog("[ADB] connectedDevices: exit %d — %@", process.terminationStatus, errOutput.trimmingCharacters(in: .whitespacesAndNewlines))
            return []
        }

        var devices: [ConnectedDevice] = []
        for line in output.split(separator: "\n").dropFirst() {
            // Format: "SERIAL  device usb:... product:... model:MODEL device:..."
            let parts = line.split(separator: " ", maxSplits: 2)
            guard parts.count >= 2 else { continue }
            let serial = String(parts[0])
            let status = String(parts[1])
            guard status == "device" else {
                NSLog("[ADB] connectedDevices: %@ status '%@' (not ready)", serial, status)
                continue
            }
            // Extract key:value pairs (model, product, device)
            func field(_ key: String) -> String? {
                guard let r = line.range(of: " \(key):") else { return nil }
                return String(line[r.upperBound...].prefix(while: { $0 != " " }))
            }
            let model = field("model") ?? "unknown"
            let device = ConnectedDevice(serial: serial, model: model,
                                         product: field("product") ?? "",
                                         deviceName: field("device") ?? "")
            devices.append(device)
            NSLog("[ADB] connectedDevices: found %@ (model: %@, family: %@)",
                  serial, model, device.deviceFamily.rawValue)
        }
        return devices
    }

    /// Set up ADB reverse tunnel: device's `devicePort` → Mac's `hostPort`.
    /// Both Android apps connect to localhost:8888, but the tunnel routes each to its own Mac port.
    @discardableResult
    /// True when `adb reverse --list` already maps devicePort → hostPort.
    static func reverseTunnelExists(serial: String?, devicePort: UInt16, hostPort: UInt16) -> Bool {
        guard let process = makeADBProcess(["reverse", "--list"], serial: serial) else { return false }
        let stdout = Pipe()
        process.standardOutput = stdout
        process.standardError = Pipe()
        do { try process.run() } catch { return false }
        let out = String(data: stdout.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        process.waitUntilExit()
        return out.split(separator: "\n").contains { $0.hasSuffix("tcp:\(devicePort) tcp:\(hostPort)") }
    }

    static func setupReverseTunnel(serial: String? = nil, devicePort: UInt16 = TCP_PORT, hostPort: UInt16 = TCP_PORT) -> Bool {
        // Re-binding an existing tunnel drops connections already flowing through it
        // (the device would fall back to Wi-Fi mid-start) — keep an identical one.
        if reverseTunnelExists(serial: serial, devicePort: devicePort, hostPort: hostPort) { return true }
        let stdout = Pipe()
        let stderr = Pipe()
        guard let process = makeADBProcess(["reverse", "tcp:\(devicePort)", "tcp:\(hostPort)"], serial: serial) else { return false }
        process.standardOutput = stdout
        process.standardError = stderr
        do {
            try process.run()
        } catch {
            NSLog("[ADB] setupReverseTunnel: failed to launch — %@", "\(error)")
            return false
        }
        process.waitUntilExit()
        let stdOutput = String(data: stdout.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        if process.terminationStatus != 0 {
            let errOutput = String(data: stderr.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            NSLog("[ADB] setupReverseTunnel: exit %d — stdout='%@' stderr='%@'",
                  process.terminationStatus,
                  stdOutput.trimmingCharacters(in: .whitespacesAndNewlines),
                  errOutput.trimmingCharacters(in: .whitespacesAndNewlines))
            return false
        }
        NSLog("[ADB] setupReverseTunnel: %@:%d → host:%d — success", serial ?? "default", devicePort, hostPort)

        let verified = verifyReverseTunnel(serial: serial, devicePort: devicePort)
        if !verified {
            NSLog("[ADB] setupReverseTunnel: WARNING — command succeeded but tunnel not in --list!")
        }
        return verified
    }

    private static func verifyReverseTunnel(serial: String? = nil, devicePort: UInt16 = TCP_PORT) -> Bool {
        let stdout = Pipe()
        guard let process = makeADBProcess(["reverse", "--list"], serial: serial) else { return false }
        process.standardOutput = stdout
        process.standardError = FileHandle.nullDevice
        try? process.run()
        process.waitUntilExit()
        let output = String(data: stdout.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let found = output.contains("tcp:\(devicePort)")
        NSLog("[ADB] verifyReverseTunnel: %@ (output='%@')", found ? "VERIFIED" : "NOT FOUND", output.trimmingCharacters(in: .whitespacesAndNewlines))
        return found
    }

    @discardableResult
    static func removeReverseTunnel(serial: String? = nil, devicePort: UInt16 = TCP_PORT) -> Bool {
        guard let process = makeADBProcess(["reverse", "--remove", "tcp:\(devicePort)"], serial: serial) else { return false }
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try? process.run()
        process.waitUntilExit()
        return process.terminationStatus == 0
    }

    static func querySystemSetting(_ setting: String, serial: String? = nil) -> Int? {
        let pipe = Pipe()
        guard let process = makeADBProcess(["shell", "settings", "get", "system", setting], serial: serial) else { return nil }
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        try? process.run()
        process.waitUntilExit()
        if let str = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) {
            return Int(str)
        }
        return nil
    }

    static func setSystemSetting(_ setting: String, value: Int, serial: String? = nil) {
        guard let process = makeADBProcess(["shell", "settings", "put", "system", setting, "\(value)"], serial: serial) else { return }
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try? process.run()
    }

    /// Check if the companion Android app is installed on the specified device.
    static func isAppInstalled(serial: String? = nil) -> Bool {
        let pipe = Pipe()
        guard let process = makeADBProcess(["shell", "pm", "list", "packages", "com.daylight.mirror"], serial: serial) else { return false }
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        try? process.run()
        process.waitUntilExit()
        let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        return output.contains("package:com.daylight.mirror")
    }

    /// Installed companion app versionCode on the device, or nil if not installed.
    static func installedVersionCode(serial: String? = nil) -> Int? {
        let pipe = Pipe()
        guard let process = makeADBProcess(["shell", "dumpsys", "package", "com.daylight.mirror"], serial: serial) else { return nil }
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        try? process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let output = String(data: data, encoding: .utf8) ?? ""
        guard let r = output.range(of: "versionCode=") else { return nil }
        return Int(output[r.upperBound...].prefix(while: { $0.isNumber }))
    }

    /// Whether the device has a companion app at least as new as the protocol needs.
    static func isCompanionUpToDate(serial: String? = nil) -> Bool {
        guard let code = installedVersionCode(serial: serial) else { return false }
        return code >= COMPANION_VERSION_CODE
    }

    /// Run `adb shell <cmd>` on a device and wait for it. Used for Onyx sysfs writes
    /// and EPD broadcasts that a regular app cannot always perform itself.
    @discardableResult
    static func shell(_ args: [String], serial: String? = nil) -> Bool {
        guard let process = makeADBProcess(["shell"] + args, serial: serial) else { return false }
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return false }
        process.waitUntilExit()
        return process.terminationStatus == 0
    }

    /// Logical display size the device gives apps (`wm size`; an override wins).
    static func displaySize(serial: String? = nil) -> (width: UInt, height: UInt)? {
        guard let out = shellOutput(["wm", "size"], serial: serial) else { return nil }
        var result: (UInt, UInt)?
        for line in out.split(whereSeparator: { $0.isNewline }) {
            guard let r = line.range(of: ": ") else { continue }
            let dims = line[r.upperBound...].trimmingCharacters(in: .whitespaces).split(separator: "x")
            guard dims.count == 2, let w = UInt(dims[0]), let h = UInt(dims[1]) else { continue }
            if line.contains("Override") || result == nil { result = (w, h) }
        }
        return result
    }

    /// Run `adb shell <args>` and return stdout, or nil on failure.
    static func shellOutput(_ args: [String], serial: String? = nil) -> String? {
        let pipe = Pipe()
        guard let process = makeADBProcess(["shell"] + args, serial: serial) else { return nil }
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// Install the bundled APK onto the specified device.
    /// Returns nil on success, or an error message on failure.
    static func installBundledAPK(serial: String? = nil) -> String? {
        // App bundle first; MIRROR_APK lets CLI/dev builds point at a fresh gradle output.
        let candidates = [
            ProcessInfo.processInfo.environment["MIRROR_APK"],
            Bundle.main.resourcePath.map { $0 + "/app-debug.apk" },
        ].compactMap { $0 }
        guard let apkPath = candidates.first(where: { FileManager.default.fileExists(atPath: $0) }) else {
            return "No bundled APK found (set MIRROR_APK for dev builds)"
        }
        let pipe = Pipe()
        guard let process = makeADBProcess(["install", "-r", apkPath], serial: serial) else {
            return "ADB not available"
        }
        process.standardOutput = pipe
        process.standardError = pipe
        try? process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let output = String(data: data, encoding: .utf8) ?? ""
        if process.terminationStatus != 0 {
            // A companion built on another machine is signed with a different debug key and
            // can't be upgraded in place. It keeps no state, so replace it.
            if output.contains("INSTALL_FAILED_UPDATE_INCOMPATIBLE") {
                NSLog("[ADB] Companion signature differs on %@ — reinstalling", serial ?? "default")
                shell(["pm", "uninstall", "com.daylight.mirror"], serial: serial)
                guard let retry = makeADBProcess(["install", apkPath], serial: serial) else { return "ADB not available" }
                let retryPipe = Pipe()
                retry.standardOutput = retryPipe
                retry.standardError = retryPipe
                try? retry.run()
                let retryData = retryPipe.fileHandleForReading.readDataToEndOfFile()
                retry.waitUntilExit()
                if retry.terminationStatus == 0 {
                    NSLog("[ADB] Installed bundled APK on %@", serial ?? "default")
                    return nil
                }
                return "Install failed: \((String(data: retryData, encoding: .utf8) ?? "").trimmingCharacters(in: .whitespacesAndNewlines))"
            }
            return "Install failed: \(output.trimmingCharacters(in: .whitespacesAndNewlines))"
        }
        NSLog("[ADB] Installed bundled APK on %@", serial ?? "default")
        return nil
    }

    /// Reset display size override so the app gets the full physical panel resolution.
    /// The DC-1 ships with `display_size_forced=1184,1584` which steals 16px per axis,
    /// causing 1600x1200 frames to be scaled to 1584x1184 — destroying 1:1 pixel mapping.
    @discardableResult
    static func resetDisplaySizeOverride(serial: String? = nil) -> Bool {
        // Check current override
        let checkPipe = Pipe()
        guard let checkProcess = makeADBProcess(["shell", "wm", "size"], serial: serial) else { return false }
        checkProcess.standardOutput = checkPipe
        checkProcess.standardError = FileHandle.nullDevice
        try? checkProcess.run()
        checkProcess.waitUntilExit()
        let sizeOutput = String(data: checkPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""

        if sizeOutput.contains("Override") {
            // Reset size override to physical resolution
            guard let resetProcess = makeADBProcess(["shell", "wm", "size", "reset"], serial: serial) else { return false }
            resetProcess.standardOutput = FileHandle.nullDevice
            resetProcess.standardError = FileHandle.nullDevice
            try? resetProcess.run()
            resetProcess.waitUntilExit()
            NSLog("[ADB] Reset display size override (was: %@)", sizeOutput.trimmingCharacters(in: .whitespacesAndNewlines))
            return resetProcess.terminationStatus == 0
        }
        NSLog("[ADB] No display size override to reset")
        return true
    }

    /// Launch the companion app on the specified device.
    /// When `forceRestart` is true, uses `-S` to stop any existing instance first.
    static func launchApp(serial: String? = nil, forceRestart: Bool = false,
                          pairing: (secretHex: String, hosts: [String])? = nil) {
        var args = ["shell", "am", "start"]
        if forceRestart { args.append("-S") }
        args += ["-n", "com.daylight.mirror/.MirrorActivity"]
        if let p = pairing {
            // Values are hex / dotted IPs joined by commas — nothing the device shell splits.
            args += ["--es", "mirror_token", p.secretHex]
            if !p.hosts.isEmpty { args += ["--es", "mirror_hosts", p.hosts.joined(separator: ",")] }
        }
        let stderr = Pipe()
        guard let process = makeADBProcess(args, serial: serial) else { return }
        process.standardOutput = FileHandle.nullDevice
        process.standardError = stderr
        do {
            try process.run()
        } catch {
            NSLog("[ADB] launchApp: failed to launch — %@", "\(error)")
            return
        }
        process.waitUntilExit()
        if process.terminationStatus != 0 {
            let errOutput = String(data: stderr.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            NSLog("[ADB] launchApp: exit %d — %@", process.terminationStatus, errOutput.trimmingCharacters(in: .whitespacesAndNewlines))
        } else {
            NSLog("[ADB] Launched Daylight Mirror on %@%@", serial ?? "default", forceRestart ? " (force-restart)" : "")
        }
    }
}
