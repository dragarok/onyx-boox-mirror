// workload.swift — repeatable screen activity on the mirrored device's display.
//
// Opens a borderless window on the virtual display (vendor 0xDA7E) and runs fixed
// phases so USB and Wi-Fi runs see identical content:
//   typing    — a few characters per second appended to a line (small dirty area)
//   scrolling — a page of text scrolled 8 px every 33 ms (continuous mid-size updates)
//   pageflip  — two different full-screen pages alternating every 500 ms (whole frame)
// Prints "PHASE <name> <unix-time>" at each boundary and "END <unix-time>" when done.
//
// Usage: swift scripts/bench/workload.swift [seconds-per-phase]

import AppKit

let phaseSeconds = Double(CommandLine.arguments.dropFirst().first ?? "15") ?? 15

func mark(_ s: String) {
    print("\(s) \(Date().timeIntervalSince1970)")
    fflush(stdout)
}

let loremWords = """
the quick brown fox jumps over the lazy dog while e-ink panels refresh only what \
changed so mirroring a desktop means sending small deltas most of the time and a \
whole frame only when everything moves at once like flipping pages or switching tabs
""".split(separator: " ").map(String.init)

func page(seed: Int, lines: Int) -> [String] {
    var rng = seed
    return (0..<lines).map { _ in
        (0..<12).map { _ -> String in
            rng = (rng &* 1103515245 &+ 12345) & 0x7fffffff
            return loremWords[rng % loremWords.count]
        }.joined(separator: " ")
    }
}

final class WorkloadView: NSView {
    var phase = "warmup"
    var typed = ""
    var scrollY: CGFloat = 0
    var flip = false
    let pageA = page(seed: 1, lines: 200)
    let pageB = page(seed: 2, lines: 200)
    let font = NSFont.monospacedSystemFont(ofSize: 18, weight: .regular)

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.white.setFill()
        dirtyRect.fill()
        let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.black]
        let lineH: CGFloat = 26
        switch phase {
        case "typing":
            ("> " + typed + "▌" as NSString).draw(at: NSPoint(x: 40, y: 60), withAttributes: attrs)
        case "scrolling":
            let first = Int(scrollY / lineH)
            let offset = scrollY.truncatingRemainder(dividingBy: lineH)
            var y = 20 - offset
            var i = first
            while y < bounds.height {
                (pageA[i % pageA.count] as NSString).draw(at: NSPoint(x: 40, y: y), withAttributes: attrs)
                y += lineH
                i += 1
            }
        case "pageflip":
            let lines = flip ? pageB : pageA
            if flip { NSColor(white: 0.9, alpha: 1).setFill(); bounds.fill() }
            var y: CGFloat = 20
            for l in lines where y < bounds.height {
                (l as NSString).draw(at: NSPoint(x: 40, y: y), withAttributes: attrs)
                y += lineH
            }
        default:
            ("benchmark starting…" as NSString).draw(at: NSPoint(x: 40, y: 60), withAttributes: attrs)
        }
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)

guard let screen = NSScreen.screens.first(where: {
    let id = ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0
    return CGDisplayVendorNumber(id) == 0xDA7E
}) else {
    print("ERROR no mirrored display found (is the mirror running?)")
    exit(1)
}
// In mirror mode the virtual display is the main screen; either way this is the one captured.

let window = NSWindow(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false, screen: screen)
window.setFrame(screen.frame, display: true)
window.level = .floating
window.isOpaque = true
let view = WorkloadView(frame: NSRect(origin: .zero, size: screen.frame.size))
window.contentView = view
window.orderFrontRegardless()

var timers: [Timer] = []
func stopTimers() { timers.forEach { $0.invalidate() }; timers.removeAll() }

func run(_ phase: String, interval: TimeInterval, tick: @escaping () -> Void) {
    stopTimers()
    view.phase = phase
    mark("PHASE \(phase)")
    view.needsDisplay = true
    timers.append(Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { _ in
        tick()
        view.needsDisplay = true
    })
}

let start = DispatchTime.now()
func at(_ seconds: Double, _ block: @escaping () -> Void) {
    DispatchQueue.main.asyncAfter(deadline: start + seconds, execute: block)
}

let typingText = Array("the quick brown fox jumps over the lazy dog ")
var typeIndex = 0
at(3) {
    run("typing", interval: 0.15) {
        view.typed.append(typingText[typeIndex % typingText.count])
        typeIndex += 1
        if view.typed.count > 90 { view.typed = "" }
    }
}
at(3 + phaseSeconds) { run("scrolling", interval: 0.033) { view.scrollY += 8 } }
at(3 + 2 * phaseSeconds) { run("pageflip", interval: 0.5) { view.flip.toggle() } }
at(3 + 3 * phaseSeconds) {
    stopTimers()
    mark("END")
    window.close()
    exit(0)
}

app.run()
