// Configuration.swift — Constants and resolution presets for Daylight Mirror.
//
// Protocol constants, resolution presets (landscape + portrait), and shared
// configuration values used across the engine.

import Foundation

let TCP_PORT: UInt16 = 8888
let WS_PORT: UInt16 = 8890
let HTTP_PORT: UInt16 = 8891
let TARGET_FPS: Int = 60  // High capture rate — tile detection keeps bandwidth low when idle
let JPEG_QUALITY: CGFloat = 0.8
let KEYFRAME_INTERVAL: Int = 60  // 1 keyframe per second

// Resolution presets for Boox Tab Ultra C color e-ink panel.
// Color native: 1240x930 (4:3). B&W native: 2480x1860.
// Cozy variants use HiDPI (2x): macOS renders at half logical points with full backing
// pixels — big UI, full native sharpness. Other presets are non-HiDPI 1:1 pixel modes.
public enum DisplayResolution: String, CaseIterable, Identifiable {
    // Landscape (4:3) — Boox Tab Ultra C
    case booxCozy     = "1240x930h"   // HiDPI 2x: 620x465pt → 1240x930px — large UI, color-native
    case booxBalanced = "1240x930"    // Non-HiDPI — 1:1 color pixel mapping
    case booxSharp    = "1860x1395"   // Between color and B&W native — more pixels
    // Portrait (3:4) — Boox Tab Ultra C
    case booxPortraitCozy     = "930x1240h"   // HiDPI 2x: 465x620pt → 930x1240px
    case booxPortraitBalanced = "930x1240"    // Non-HiDPI — 1:1 color pixel mapping
    case booxPortraitSharp    = "1395x1860"   // Between color and B&W native

    public var id: String { rawValue }
    /// Pixel dimensions captured and sent to the device.
    public var width: UInt {
        switch self {
        case .booxCozy: 1240; case .booxBalanced: 1240; case .booxSharp: 1860
        case .booxPortraitCozy: 930; case .booxPortraitBalanced: 930; case .booxPortraitSharp: 1395
        }
    }
    public var height: UInt {
        switch self {
        case .booxCozy: 930; case .booxBalanced: 930; case .booxSharp: 1395
        case .booxPortraitCozy: 1240; case .booxPortraitBalanced: 1240; case .booxPortraitSharp: 1860
        }
    }
    public var label: String {
        switch self {
        case .booxCozy: "Cozy"; case .booxBalanced: "Balanced"; case .booxSharp: "Sharp"
        case .booxPortraitCozy: "Portrait Cozy"
        case .booxPortraitBalanced: "Portrait Balanced"; case .booxPortraitSharp: "Portrait Sharp"
        }
    }
    /// Whether the virtual display uses HiDPI (2x) scaling.
    public var isHiDPI: Bool { switch self { case .booxCozy, .booxPortraitCozy: true; default: false } }
    /// Whether this is a portrait (vertical) orientation preset.
    public var isPortrait: Bool {
        switch self {
        case .booxPortraitCozy, .booxPortraitBalanced, .booxPortraitSharp: true
        default: false
        }
    }
}

// Protocol constants
let MAGIC_FRAME: [UInt8] = [0xDA, 0x7E]
let MAGIC_CMD: [UInt8] = [0xDA, 0x7F]
let MAGIC_ACK: [UInt8] = [0xDA, 0x7A]  // ACK from Android → Mac for RTT measurement
let FLAG_KEYFRAME: UInt8 = 0x01
let CMD_BRIGHTNESS: UInt8 = 0x01
let CMD_BACKLIGHT_TOGGLE: UInt8 = 0x03
let CMD_RESOLUTION: UInt8 = 0x04
let CMD_COLOR_MODE: UInt8 = 0x05

let FLAG_TILED: UInt8 = 0x02
let TILE_SIZE: Int = 64

// Frame header: [DA 7E] [flags:1] [seq:4 LE] [len:4 LE] [payload] = 11 bytes
// ACK packet:   [DA 7A] [seq:4 LE] = 6 bytes (sent by Android after rendering)
let FRAME_HEADER_SIZE = 11

let BRIGHTNESS_STEP: Int = 15

// MARK: - Status

public enum MirrorStatus: Equatable {
    case idle
    case waitingForDevice
    case starting
    case running
    case stopping
    case error(String)
}
