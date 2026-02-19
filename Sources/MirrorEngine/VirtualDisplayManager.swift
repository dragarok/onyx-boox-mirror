// VirtualDisplayManager.swift — Virtual display creation via CGVirtualDisplay.
//
// Creates a virtual display at the given resolution. When mirror=true, mirrors the
// Mac's built-in display. When mirror=false, creates an independent secondary display.
// Uses CGVirtualDisplay private API (same as BetterDisplay, DeskPad).
// With hiDPI=true, macOS renders at 2x — e.g. 1240x930 pixels at 620x465 logical points.
// The virtual display disappears when this object is deallocated.

import Foundation
import CVirtualDisplay

class VirtualDisplayManager {
    let virtualDisplay: CGVirtualDisplay
    let displayID: CGDirectDisplayID
    let width: UInt
    let height: UInt
    let mirror: Bool

    init(width: UInt, height: UInt, hiDPI: Bool = false, mirror: Bool = false) {
        self.width = width
        self.height = height
        self.mirror = mirror

        let descriptor = CGVirtualDisplayDescriptor()
        descriptor.setDispatchQueue(DispatchQueue.main)
        descriptor.name = "Boox Mirror"
        descriptor.maxPixelsWide = UInt32(width)
        descriptor.maxPixelsHigh = UInt32(height)
        descriptor.sizeInMillimeters = CGSize(
            width: 25.4 * Double(width) / 100.0,
            height: 25.4 * Double(height) / 100.0
        )
        descriptor.productID = 0xDA7E
        descriptor.vendorID = 0xDA7E
        descriptor.serialNum = 0x0001

        virtualDisplay = CGVirtualDisplay(descriptor: descriptor)
        displayID = virtualDisplay.displayID
        print("Virtual display created: ID \(displayID)")

        let settings = CGVirtualDisplaySettings()
        settings.hiDPI = hiDPI ? 1 : 0
        settings.modes = [
            CGVirtualDisplayMode(width: width, height: height, refreshRate: CGFloat(TARGET_FPS))
        ]

        guard virtualDisplay.apply(settings) else {
            print("WARNING: Failed to apply virtual display settings")
            return
        }
        let modeLabel = hiDPI ? "HiDPI (\(width/2)x\(height/2)pt @ 2x)" : "non-HiDPI"
        let mirrorLabel = mirror ? "mirror" : "secondary"
        print("Virtual display configured: \(width)x\(height) \(modeLabel) @ \(TARGET_FPS)Hz (\(mirrorLabel))")
    }

    func mirrorBuiltInDisplay() {
        guard mirror else {
            print("Secondary display mode — skipping mirror setup (arrange in System Settings > Displays)")
            return
        }

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

        guard CGCompleteDisplayConfiguration(config, .forSession) == .success else {
            print("WARNING: Failed to complete mirror configuration")
            return
        }

        print("Mirroring: built-in display \(masterID) -> virtual display \(displayID)")
    }
}
