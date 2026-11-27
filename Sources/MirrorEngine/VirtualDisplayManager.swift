// VirtualDisplayManager.swift — Virtual display creation via CGVirtualDisplay.
//
// Creates a virtual display at the given resolution and mirrors the Mac's built-in
// display to it. Uses CGVirtualDisplay private API (same as BetterDisplay, DeskPad).
// With hiDPI=true, macOS renders at 2x — e.g. 1600x1200 pixels at 800x600 logical points.
// The virtual display disappears when this object is deallocated.
//
// HiDPI gotchas (measured on macOS 27 with throwaway displays):
//  - With hiDPI on, the mode list is in POINTS. Listing the pixel size (2480x1680) makes
//    macOS offer 2480x1680pt @ 4960x3360 — a microscopic UI — and its 1240x840pt @ 2x
//    variant is marked unusable for the desktop, so switching to it fails. Listing the
//    point size (1240x840) yields a usable 1240x840pt @ 2480x1680px mode.
//  - macOS never picks that mode by default (it prefers 2480x1680 @ 1x), and it
//    remembers the last mode per vendor/product/serial. So we select the exact mode
//    explicitly (applyTargetMode) instead of trusting the default.
//
// Mirror relationship: the built-in display mirrors our virtual display (virtual is
// the primary/source). Closing the lid removes the built-in follower but the virtual
// display continues operating as the sole screen.

import Foundation
import CVirtualDisplay

class VirtualDisplayManager {
    let virtualDisplay: CGVirtualDisplay
    let displayID: CGDirectDisplayID
    let width: UInt
    let height: UInt
    let hiDPI: Bool

    /// Each virtual display needs a unique serial number so macOS treats them as
    /// separate displays. Without this, the second display creation fails (ID 0).
    private static var nextSerial: UInt32 = 1

    /// - productID: distinct per device family so macOS keeps separate saved modes and
    ///   arrangement for a DC-1 and a BOOX display.
    init(width: UInt, height: UInt, hiDPI: Bool = false, name: String = "Daylight DC-1",
         productID: UInt32 = 0xDA7E) {
        self.width = width
        self.height = height
        self.hiDPI = hiDPI

        let serial = VirtualDisplayManager.nextSerial
        VirtualDisplayManager.nextSerial += 1

        let descriptor = CGVirtualDisplayDescriptor()
        descriptor.setDispatchQueue(DispatchQueue.main)
        descriptor.name = name
        descriptor.maxPixelsWide = UInt32(width)
        descriptor.maxPixelsHigh = UInt32(height)
        descriptor.sizeInMillimeters = CGSize(
            width: 25.4 * Double(width) / 100.0,
            height: 25.4 * Double(height) / 100.0
        )
        descriptor.productID = productID
        descriptor.vendorID = 0xDA7E
        descriptor.serialNum = serial

        virtualDisplay = CGVirtualDisplay(descriptor: descriptor)
        displayID = virtualDisplay.displayID
        print("Virtual display created: ID \(displayID)")

        let settings = CGVirtualDisplaySettings()
        settings.hiDPI = hiDPI ? 1 : 0
        // HiDPI modes are listed in points (see header); macOS backs them at 2x.
        settings.modes = [
            hiDPI ? CGVirtualDisplayMode(width: width / 2, height: height / 2, refreshRate: 60)
                  : CGVirtualDisplayMode(width: width, height: height, refreshRate: 60)
        ]

        guard virtualDisplay.apply(settings) else {
            print("WARNING: Failed to apply virtual display settings")
            return
        }
        let modeLabel = hiDPI ? "HiDPI (\(width/2)x\(height/2)pt @ 2x)" : "non-HiDPI"
        print("Virtual display configured: \(width)x\(height) \(modeLabel) @ 60Hz")
    }

    /// The mode this display should run in: exactly width x height backing pixels, at
    /// half that in points when HiDPI.
    private func targetMode() -> CGDisplayMode? {
        let opts = [kCGDisplayShowDuplicateLowResolutionModes: true] as CFDictionary
        guard let modes = CGDisplayCopyAllDisplayModes(displayID, opts) as? [CGDisplayMode] else { return nil }
        let ptW = Int(hiDPI ? width / 2 : width)
        let ptH = Int(hiDPI ? height / 2 : height)
        return modes.first {
            $0.pixelWidth == Int(width) && $0.pixelHeight == Int(height) && $0.width == ptW && $0.height == ptH
        }
    }

    private var isInTargetMode: Bool {
        guard let cur = CGDisplayCopyDisplayMode(displayID) else { return false }
        return cur.pixelWidth == Int(width) && cur.pixelHeight == Int(height)
            && cur.width == Int(hiDPI ? width / 2 : width)
    }

    /// Switch the display to its target mode if macOS chose (or restored) another one.
    /// Pass a configuration to fold the change into it (e.g. alongside mirroring).
    @discardableResult
    func applyTargetMode(in config: CGDisplayConfigRef? = nil) -> Bool {
        if isInTargetMode { return true }
        guard let mode = targetMode() else {
            let cur = CGDisplayCopyDisplayMode(displayID)
            print("WARNING: \(width)x\(height)\(hiDPI ? " HiDPI" : "") mode not offered (current \(cur?.width ?? 0)x\(cur?.height ?? 0)pt)")
            return false
        }
        if let config = config {
            return CGConfigureDisplayWithDisplayMode(config, displayID, mode, nil) == .success
        }
        var ref: CGDisplayConfigRef?
        guard CGBeginDisplayConfiguration(&ref) == .success, let cfg = ref else { return false }
        guard CGConfigureDisplayWithDisplayMode(cfg, displayID, mode, nil) == .success else {
            CGCancelDisplayConfiguration(cfg)
            return false
        }
        let ok = CGCompleteDisplayConfiguration(cfg, .forSession) == .success
        print("Display mode -> \(mode.width)x\(mode.height)pt @ \(mode.pixelWidth)x\(mode.pixelHeight)px: \(ok ? "ok" : "failed")")
        return ok
    }

    func mirrorBuiltInDisplay() {
        var displayIDs = [CGDirectDisplayID](repeating: 0, count: 32)
        var displayCount: UInt32 = 0
        CGGetOnlineDisplayList(32, &displayIDs, &displayCount)

        var builtInID: CGDirectDisplayID?
        for i in 0..<Int(displayCount) {
            if CGDisplayIsBuiltin(displayIDs[i]) != 0 {
                builtInID = displayIDs[i]
                break
            }
        }

        guard let masterID = builtInID else {
            print("WARNING: No built-in display found")
            return
        }

        var configRef: CGDisplayConfigRef?
        guard CGBeginDisplayConfiguration(&configRef) == .success, let config = configRef else {
            print("WARNING: Failed to begin display configuration")
            return
        }

        guard CGConfigureDisplayMirrorOfDisplay(config, masterID, displayID) == .success else {
            print("WARNING: Failed to configure mirror")
            CGCancelDisplayConfiguration(config)
            return
        }
        // Mirroring can make macOS fall back to a "common" mode; pin ours in the same change.
        applyTargetMode(in: config)

        guard CGCompleteDisplayConfiguration(config, .forSession) == .success else {
            print("WARNING: Failed to complete mirror configuration")
            return
        }

        print("Mirroring: built-in display \(masterID) -> virtual display \(displayID)")
    }

    /// Second-monitor mode: macOS remembers mirror sets per display identity and can
    /// restore one when the display reappears. Break it if the built-in display ended up
    /// mirroring us; leave any other mirroring the user set up alone.
    func ensureExtended() {
        var ids = [CGDirectDisplayID](repeating: 0, count: 32)
        var count: UInt32 = 0
        CGGetOnlineDisplayList(32, &ids, &count)
        let followers = ids.prefix(Int(count)).filter { $0 != displayID && CGDisplayMirrorsDisplay($0) == displayID }
        let mastered = CGDisplayMirrorsDisplay(displayID) != kCGNullDirectDisplay
        guard !followers.isEmpty || mastered else { return }
        var ref: CGDisplayConfigRef?
        guard CGBeginDisplayConfiguration(&ref) == .success, let config = ref else { return }
        for f in followers { CGConfigureDisplayMirrorOfDisplay(config, f, kCGNullDirectDisplay) }
        if mastered { CGConfigureDisplayMirrorOfDisplay(config, displayID, kCGNullDirectDisplay) }
        applyTargetMode(in: config)
        let ok = CGCompleteDisplayConfiguration(config, .forSession) == .success
        print("Extended mode: removed restored mirroring (\(followers.count) follower(s)): \(ok ? "ok" : "failed")")
    }

    /// Break the mirror relationship so the virtual display becomes a standalone
    /// independent display. Used during clamshell mode — when the lid closes, the
    /// built-in display going offline drags the compositor down with it. Unmirroring
    /// makes the virtual display self-sufficient so CGDisplayStream keeps delivering.
    func unmirrorBuiltInDisplay() {
        var displayIDs = [CGDirectDisplayID](repeating: 0, count: 32)
        var displayCount: UInt32 = 0
        CGGetOnlineDisplayList(32, &displayIDs, &displayCount)

        // Find the built-in display to unmirror it
        var builtInID: CGDirectDisplayID?
        for i in 0..<Int(displayCount) {
            if CGDisplayIsBuiltin(displayIDs[i]) != 0 {
                builtInID = displayIDs[i]
                break
            }
        }

        guard let followerID = builtInID else {
            print("[Clamshell] No built-in display found to unmirror")
            return
        }

        var configRef: CGDisplayConfigRef?
        guard CGBeginDisplayConfiguration(&configRef) == .success, let config = configRef else {
            print("[Clamshell] Failed to begin display configuration for unmirror")
            return
        }

        // Setting mirror target to kCGNullDirectDisplay breaks the mirror
        guard CGConfigureDisplayMirrorOfDisplay(config, followerID, kCGNullDirectDisplay) == .success else {
            print("[Clamshell] Failed to configure unmirror")
            CGCancelDisplayConfiguration(config)
            return
        }

        guard CGCompleteDisplayConfiguration(config, .forSession) == .success else {
            print("[Clamshell] Failed to complete unmirror configuration")
            return
        }

        print("[Clamshell] Unmirrored: virtual display \(displayID) is now standalone")
    }
}
