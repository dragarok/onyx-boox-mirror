// TouchInjector.swift — Converts Boox touch events into Mac mouse events.
//
// Receives normalized touch coordinates from the Android device and posts
// CGEvents to the Mac's virtual display, allowing the Boox touchscreen
// to interact with macOS apps on the mirrored display.
//
// Single finger: tap/click/drag. Two fingers: scroll wheel.

import Foundation
import CoreGraphics

class TouchInjector {
    let displayID: CGDirectDisplayID
    private var isDown = false

    init(displayID: CGDirectDisplayID) {
        self.displayID = displayID
        NSLog("[Touch] Injector ready for display %u", displayID)
    }

    func handleTouch(action: UInt8, xNorm: UInt16, yNorm: UInt16, scrollDelta: Int16 = 0) {
        let bounds = CGDisplayBounds(displayID)
        let x = bounds.origin.x + (Double(xNorm) / 65535.0) * bounds.width
        let y = bounds.origin.y + (Double(yNorm) / 65535.0) * bounds.height
        let point = CGPoint(x: x, y: y)

        switch action {
        case 0: // DOWN
            isDown = true
            if let event = CGEvent(mouseEventSource: nil, mouseType: .leftMouseDown,
                                   mouseCursorPosition: point, mouseButton: .left) {
                event.post(tap: .cghidEventTap)
            }
        case 1: // UP
            isDown = false
            if let event = CGEvent(mouseEventSource: nil, mouseType: .leftMouseUp,
                                   mouseCursorPosition: point, mouseButton: .left) {
                event.post(tap: .cghidEventTap)
            }
        case 2: // MOVE / DRAG
            let type: CGEventType = isDown ? .leftMouseDragged : .mouseMoved
            if let event = CGEvent(mouseEventSource: nil, mouseType: type,
                                   mouseCursorPosition: point, mouseButton: .left) {
                event.post(tap: .cghidEventTap)
            }
        case 3: // SCROLL (two-finger)
            // Negate: Android swipe-up (negative deltaY) → positive wheel1 → Mac scroll up
            let scrollAmount = Int32(-scrollDelta) / 3
            if let event = CGEvent(scrollWheelEvent2Source: nil, units: .pixel,
                                   wheelCount: 1, wheel1: scrollAmount,
                                   wheel2: 0, wheel3: 0) {
                event.location = point
                event.post(tap: .cghidEventTap)
            }
        default:
            break
        }
    }
}
