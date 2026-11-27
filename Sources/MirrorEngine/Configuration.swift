// Configuration.swift — Constants and resolution presets for Daylight Mirror.
//
// Protocol constants, resolution presets (landscape + portrait), and shared
// configuration values used across the engine.

import Foundation

let TCP_PORT: UInt16 = 8888
let TCP_PORT_SECONDARY: UInt16 = 8889  // Second device gets its own TCP server
let INPUT_PORT: UInt16 = 8892          // Touch input from device → Mac cursor
let REMOTE_PORT: UInt16 = 8893         // Device asks the Mac to start/stop (see RemoteControlServer)
let WS_PORT: UInt16 = 8890
let HTTP_PORT: UInt16 = 8891
let TARGET_FPS: Int = 60  // DC-1 panel supports up to 120Hz; 60fps viable with GL shader + NEON opts
let JPEG_QUALITY: CGFloat = 0.8
/// Minimum companion APK versionCode (android/app/build.gradle.kts) that speaks this
/// protocol (color mode, tiled deltas, e-ink commands). Older APKs are reinstalled.
let COMPANION_VERSION_CODE: Int = 8
let KEYFRAME_INTERVAL: Int = 60

// Image processing for reflective paper displays (greyscale).
// macOS font smoothing produces subpixel-antialiased text that looks fuzzy when
// converted to greyscale. Two independent post-processing knobs counteract this:
//   sharpenAmount (0.0-3.0): spatial sharpening via Laplacian kernel (default 1.5)
//   contrastAmount (1.0-1.8): linear contrast stretch around midpoint (default 1.2)

// Resolution presets per device family.
//
// Daylight DC-1: 1600x1200 native, 4:3 landscape / 3:4 portrait.
// BOOX: presets are derived from the panel's drawable size, detected over adb when
//   the device connects (BooxPanel.landscape). Tab Ultra C: Kaleido 3, 2480x1860 B&W
//   layer (300 ppi) under a half-resolution color filter — but the firmware can reserve
//   part of the panel (e.g. a 180 px strip, leaving 2480x1680), so never assume 4:3.
//   "Retina" renders at 2x so text uses every B&W pixel while UI stays comfortable;
//   "Color native" is half resolution, matching the color layer 1:1.
//
// Cozy/Retina variants use HiDPI (2x): macOS renders at half logical points with full
// backing pixels — big UI, full native sharpness. Other presets are 1:1 pixel modes.
public enum DisplayResolution: String, CaseIterable, Identifiable {
    // DC-1 Landscape (4:3)
    case cozy        = "800x600"    // HiDPI 2x: 800x600pt → 1600x1200px — large UI, native sharpness
    case comfortable = "1024x768"   // Larger UI, easy on the eyes
    case balanced    = "1280x960"   // Good middle ground
    case sharp       = "1600x1200"  // Maximum sharpness, 1:1 native pixel mapping
    // DC-1 Portrait (3:4)
    case portraitCozy        = "600x800"    // HiDPI 2x: 600x800pt → 1200x1600px — large UI, native sharpness
    case portraitComfortable = "768x1024"   // Larger UI, easy on the eyes
    case portraitBalanced    = "960x1280"   // Good middle ground
    case portraitSharp       = "1200x1600"  // Maximum sharpness, 1:1 native pixel mapping
    // BOOX landscape (sizes follow BooxPanel.landscape = W x H)
    case booxRetina   = "boox-retina"   // HiDPI 2x: W x H px — full B&W sharpness, comfortable UI
    case booxCozy     = "boox-cozy"     // HiDPI 2x: W/2 x H/2 px — huge UI
    case booxBalanced = "boox-color"    // 1:1 at W/2 x H/2 — matches the color layer, fastest
    case booxSharp    = "boox-space"    // 1:1 at 3/4 W x 3/4 H — more desktop space
    // BOOX portrait
    case booxPortraitRetina   = "boox-portrait-retina"  // HiDPI 2x: H x W px
    case booxPortraitBalanced = "boox-portrait-color"   // 1:1 at H/2 x W/2

    public var id: String { rawValue }
    /// Pixel dimensions captured and sent to the device.
    public var width: UInt {
        switch self {
        case .cozy: 1600; case .comfortable: 1024; case .balanced: 1280; case .sharp: 1600
        case .portraitCozy: 1200; case .portraitComfortable: 768; case .portraitBalanced: 960; case .portraitSharp: 1200
        case .booxRetina, .booxCozy, .booxBalanced, .booxSharp,
             .booxPortraitRetina, .booxPortraitBalanced: booxSize.w
        }
    }
    public var height: UInt {
        switch self {
        case .cozy: 1200; case .comfortable: 768; case .balanced: 960; case .sharp: 1200
        case .portraitCozy: 1600; case .portraitComfortable: 1024; case .portraitBalanced: 1280; case .portraitSharp: 1600
        case .booxRetina, .booxCozy, .booxBalanced, .booxSharp,
             .booxPortraitRetina, .booxPortraitBalanced: booxSize.h
        }
    }
    /// Pixel size of a BOOX preset, derived from the detected panel. Even dimensions
    /// (HiDPI modes need them).
    private var booxSize: (w: UInt, h: UInt) {
        let (W, H) = BooxPanel.landscape
        func even(_ v: UInt) -> UInt { v & ~1 }
        switch self {
        case .booxRetina: return (even(W), even(H))
        case .booxCozy, .booxBalanced: return (even(W / 2), even(H / 2))
        case .booxSharp: return (even(W * 3 / 4), even(H * 3 / 4))
        case .booxPortraitRetina: return (even(H), even(W))
        case .booxPortraitBalanced: return (even(H / 2), even(W / 2))
        default: return (0, 0)
        }
    }
    public var label: String {
        switch self {
        case .cozy: "Cozy"; case .comfortable: "Comfortable"; case .balanced: "Balanced"; case .sharp: "Sharp"
        case .portraitCozy: "Portrait Cozy"; case .portraitComfortable: "Portrait Comfortable"
        case .portraitBalanced: "Portrait Balanced"; case .portraitSharp: "Portrait Sharp"
        case .booxRetina: "Retina"; case .booxCozy: "Cozy"; case .booxBalanced: "Color native"
        case .booxSharp: "More space"
        case .booxPortraitRetina: "Portrait Retina"; case .booxPortraitBalanced: "Portrait Color native"
        }
    }
    /// Human-readable size shown next to the label (logical points, as macOS shows them).
    public var displaySize: String {
        isHiDPI ? "\(width / 2)x\(height / 2) @2x" : "\(width)x\(height)"
    }
    /// Whether the virtual display uses HiDPI (2x) scaling.
    public var isHiDPI: Bool {
        switch self {
        case .cozy, .portraitCozy, .booxRetina, .booxCozy, .booxPortraitRetina: true
        default: false
        }
    }
    /// Whether this is a portrait (vertical) orientation preset.
    public var isPortrait: Bool {
        switch self {
        case .portraitCozy, .portraitComfortable, .portraitBalanced, .portraitSharp: true
        case .booxPortraitRetina, .booxPortraitBalanced: true
        default: false
        }
    }
    /// Device family this preset is designed for.
    public var family: DeviceFamily {
        switch self {
        case .booxRetina, .booxCozy, .booxBalanced, .booxSharp,
             .booxPortraitRetina, .booxPortraitBalanced: .boox
        default: .daylightDC1
        }
    }
    /// Presets offered for a device family, in menu order.
    public static func presets(for family: DeviceFamily) -> [DisplayResolution] {
        let target: DeviceFamily = family == .boox ? .boox : .daylightDC1
        return allCases.filter { $0.family == target }
    }
}

/// Drawable size of the attached BOOX panel in landscape (logical display as `wm size`
/// reports it, long edge first). MirrorEngine updates it when a BOOX connects; the
/// default is the Tab Ultra C's full panel.
public enum BooxPanel {
    public static var landscape: (w: UInt, h: UInt) = (2480, 1860)

    /// Set from a `wm size` reading in either orientation.
    public static func update(width: UInt, height: UInt) {
        guard width > 0, height > 0 else { return }
        landscape = (max(width, height), min(width, height))
    }
}

/// Device families for connected Android devices.
/// Only `.daylightDC1` and `.boox` get a mirroring session. Anything else (phones,
/// emulators, other tablets that happen to be on adb) is ignored so we never create
/// a virtual display for it or install the companion app on it.
public enum DeviceFamily: String {
    case daylightDC1 = "Daylight DC-1"
    case boox        = "BOOX"
    case other       = "Other Android"

    /// Whether this family is a supported mirror target.
    public var isSupported: Bool { self != .other }
    /// Panel has a color filter layer (Kaleido) and should default to RGB frames.
    public var defaultsToColor: Bool { self == .boox }
    /// Frontlight is driven through the Onyx sysfs nodes rather than Android settings.
    public var usesOnyxFrontlight: Bool { self == .boox }
    /// Frame rate the capture pipeline targets. E-ink panels physically refresh at
    /// ~10-20 Hz in fast modes; capturing faster only burns Mac CPU and USB bandwidth.
    public var targetFPS: Int { self == .boox ? 30 : TARGET_FPS }
}

/// Display mode: mirror the built-in display, or extend as a second screen.
public enum DisplayMode: String, CaseIterable, Identifiable {
    case mirror   = "mirror"    // Virtual display mirrors the Mac's built-in display
    case extended = "extended"  // Virtual display is an independent second screen

    public var id: String { rawValue }
    public var label: String {
        switch self { case .mirror: "Mirror"; case .extended: "Extend" }
    }
}

// Protocol constants
let MAGIC_FRAME: [UInt8] = [0xDA, 0x7E]
let MAGIC_CMD: [UInt8] = [0xDA, 0x7F]
let MAGIC_ACK: [UInt8] = [0xDA, 0x7A]  // ACK from Android → Mac for RTT measurement
let MAGIC_INPUT: [UInt8] = [0xDA, 0x70] // Touch input packet magic

// Touch input event types
let INPUT_TOUCH_DOWN: UInt8 = 0x01
let INPUT_TOUCH_MOVE: UInt8 = 0x02
let INPUT_TOUCH_UP: UInt8 = 0x03
let INPUT_SCROLL: UInt8 = 0x04
let INPUT_KEY: UInt8 = 0x05     // [keycode:4][action:4 0=down 1=up][metaState:4][repeat:4][scanCode:4]
let INPUT_PACKET_SIZE = 23  // [DA 70][type:1][x:4][y:4][dx:4][dy:4][pointer:4]
let FLAG_KEYFRAME: UInt8 = 0x01
let CMD_BRIGHTNESS: UInt8 = 0x01
let CMD_WARMTH: UInt8 = 0x02
let CMD_BACKLIGHT_TOGGLE: UInt8 = 0x03
let CMD_RESOLUTION: UInt8 = 0x04
let CMD_COLOR_MODE: UInt8 = 0x05   // [DA 7F] [05] [0=greyscale, 1=RGB] — sent before CMD_RESOLUTION
let CMD_REFRESH: UInt8 = 0x06      // [DA 7F] [06] [mode] — e-ink full refresh (clears ghosting)
let CMD_EINK_MODE: UInt8 = 0x07    // [DA 7F] [07] [EinkMode.rawValue] — panel waveform preference

// Tiled delta frames: only 64x64 tiles that changed are sent.
// Payload: [tile_cols:2 LE] [tile_rows:2 LE] [dirty bitmap] then per dirty tile
// (row-major): [lz4_len:4 LE] [LZ4(XOR delta of tile rows)].
let FLAG_TILED: UInt8 = 0x02
let TILE_SIZE: Int = 64

// Frame header: [DA 7E] [flags:1] [seq:4 LE] [len:4 LE] [payload] = 11 bytes
// ACK packet:   [DA 7A] [seq:4 LE] = 6 bytes (sent by Android after rendering)
let FRAME_HEADER_SIZE = 11

let BRIGHTNESS_STEP: Int = 15
let WARMTH_STEP: Int = 20

/// E-ink waveform preference for BOOX panels. The Android app maps these onto the
/// Onyx EPD controller; other devices ignore the command.
public enum EinkMode: UInt8, CaseIterable, Identifiable {
    case auto     = 0  // Fast mode while content changes, a clean refresh once it settles
    case quality  = 1  // Panel default (best greys, slowest)
    case balanced = 2  // Onyx "balanced"/regal-style partial updates
    case fast     = 3  // A2-style fast mode — lowest latency, some ghosting

    public var id: UInt8 { rawValue }
    public var label: String {
        switch self {
        case .auto: "Auto"; case .quality: "Quality"; case .balanced: "Balanced"; case .fast: "Fast"
        }
    }
}

// MARK: - Display Profiles

/// Bundles sharpen, contrast, and gamma into named presets for the DC-1 reflective panel.
/// "Crisp Paper" is the optimized default. "Balanced" is gentler. "Custom" unlocks sliders.
public enum DisplayProfile: String, CaseIterable, Identifiable {
    case crispPaper = "Crisp Paper"
    case balanced  = "Balanced"
    case custom    = "Custom"

    public var id: String { rawValue }

    public var sharpen: Double {
        switch self { case .crispPaper: 1.5; case .balanced: 0.5; case .custom: 0 }
    }
    public var contrast: Double {
        switch self { case .crispPaper: 1.2; case .balanced: 1.0; case .custom: 1.0 }
    }
    public var gamma: Double {
        switch self { case .crispPaper: 1.2; case .balanced: 1.0; case .custom: 1.0 }
    }

    /// Migration: map old "E-ink Crisp" raw value to the renamed case.
    public init?(rawValue: String) {
        switch rawValue {
        case "Crisp Paper": self = .crispPaper
        case "E-ink Crisp": self = .crispPaper  // v1.6 → v1.7 migration
        case "Balanced": self = .balanced
        case "Custom": self = .custom
        default: return nil
        }
    }
}

// MARK: - Status

public enum MirrorStatus: Equatable {
    case idle
    case waitingForDevice
    case starting
    case running
    case stopping
    case error(String)
}
