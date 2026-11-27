// KeyInjector.swift — Physical keyboard on the Android device → macOS keystrokes.
//
// The companion app forwards each key's Linux scan code (physical position), Android
// keycode and metaState over the input socket (INPUT_KEY packets). The scan code is
// preferred: Android layout apps (e.g. Full Colemak) remap keycodes, and macOS applies
// its own layout to whatever we post — using keycodes would translate twice. Mapping
// the physical position makes the device keyboard act like one plugged into the Mac,
// so the Mac's layout (Colemak, Dvorak, ...), shortcuts and key repeat all just work.
// The keycode table is the fallback for keys without a known scan code.
//
// Modifiers: Android Meta (Win/Search key) → Command, Alt → Option, Ctrl → Control —
// the same convention macOS uses for PC keyboards. Set the `keyboardAltAsCommand`
// default to swap Alt and Meta for keyboards without a usable Meta key:
//   defaults write com.daylight.mirror keyboardAltAsCommand -bool true
//
// Requires Accessibility permission (same as touch injection).

import CoreGraphics
import Foundation

enum KeyInjector {
    // android.view.KeyEvent.META_* bits
    private static let META_SHIFT_ON = 0x1
    private static let META_ALT_ON = 0x2
    private static let META_CTRL_ON = 0x1000
    private static let META_META_ON = 0x10000
    private static let META_CAPS_LOCK_ON = 0x100000

    /// Android keycode → macOS virtual key code (Carbon kVK_* values).
    static let keyMap: [Int: CGKeyCode] = {
        var m: [Int: CGKeyCode] = [:]
        // Letters: KEYCODE_A (29) ... KEYCODE_Z (54)
        let letters: [CGKeyCode] = [0x00, 0x0B, 0x08, 0x02, 0x0E, 0x03, 0x05, 0x04, 0x22, 0x26,  // a-j
                                    0x28, 0x25, 0x2E, 0x2D, 0x1F, 0x23, 0x0C, 0x0F, 0x01, 0x11,  // k-t
                                    0x20, 0x09, 0x0D, 0x07, 0x10, 0x06]                          // u-z
        for (i, k) in letters.enumerated() { m[29 + i] = k }
        // Digits: KEYCODE_0 (7) ... KEYCODE_9 (16)
        let digits: [CGKeyCode] = [0x1D, 0x12, 0x13, 0x14, 0x15, 0x17, 0x16, 0x1A, 0x1C, 0x19]
        for (i, k) in digits.enumerated() { m[7 + i] = k }
        // F1 (131) ... F12 (142)
        let fkeys: [CGKeyCode] = [0x7A, 0x78, 0x63, 0x76, 0x60, 0x61, 0x62, 0x64, 0x65, 0x6D, 0x67, 0x6F]
        for (i, k) in fkeys.enumerated() { m[131 + i] = k }
        // Numpad 0 (144) ... 9 (153)
        let pad: [CGKeyCode] = [0x52, 0x53, 0x54, 0x55, 0x56, 0x57, 0x58, 0x59, 0x5B, 0x5C]
        for (i, k) in pad.enumerated() { m[144 + i] = k }
        let rest: [Int: CGKeyCode] = [
            55: 0x2B,   // COMMA
            56: 0x2F,   // PERIOD
            57: 0x3A,   // ALT_LEFT → Option
            58: 0x3D,   // ALT_RIGHT → Right Option
            59: 0x38,   // SHIFT_LEFT
            60: 0x3C,   // SHIFT_RIGHT
            61: 0x30,   // TAB
            62: 0x31,   // SPACE
            66: 0x24,   // ENTER → Return
            67: 0x33,   // DEL (backspace) → Delete
            68: 0x32,   // GRAVE
            69: 0x1B,   // MINUS
            70: 0x18,   // EQUALS
            71: 0x21,   // LEFT_BRACKET
            72: 0x1E,   // RIGHT_BRACKET
            73: 0x2A,   // BACKSLASH
            74: 0x29,   // SEMICOLON
            75: 0x27,   // APOSTROPHE
            76: 0x2C,   // SLASH
            19: 0x7E,   // DPAD_UP
            20: 0x7D,   // DPAD_DOWN
            21: 0x7B,   // DPAD_LEFT
            22: 0x7C,   // DPAD_RIGHT
            92: 0x74,   // PAGE_UP
            93: 0x79,   // PAGE_DOWN
            111: 0x35,  // ESCAPE
            4: 0x35,    // BACK from a hardware keyboard = Esc
            112: 0x75,  // FORWARD_DEL
            113: 0x3B,  // CTRL_LEFT → Control
            114: 0x3E,  // CTRL_RIGHT
            115: 0x39,  // CAPS_LOCK
            117: 0x37,  // META_LEFT → Command
            118: 0x36,  // META_RIGHT → Right Command
            119: 0x3F,  // FUNCTION → fn
            122: 0x73,  // MOVE_HOME
            123: 0x77,  // MOVE_END
            124: 0x72,  // INSERT → Help (Insert position on Mac keyboards)
            154: 0x4B,  // NUMPAD_DIVIDE
            155: 0x43,  // NUMPAD_MULTIPLY
            156: 0x4E,  // NUMPAD_SUBTRACT
            157: 0x45,  // NUMPAD_ADD
            158: 0x41,  // NUMPAD_DOT
            159: 0x2B,  // NUMPAD_COMMA
            160: 0x4C,  // NUMPAD_ENTER
            161: 0x51,  // NUMPAD_EQUALS
        ]
        m.merge(rest) { _, new in new }
        return m
    }()

    /// Linux input scan code (KEY_* in input-event-codes.h) → macOS virtual key code,
    /// by physical position on a US ANSI board.
    static let scanMap: [Int: CGKeyCode] = {
        var m: [Int: CGKeyCode] = [
            1: 0x35,    // ESC
            12: 0x1B, 13: 0x18, 14: 0x33, 15: 0x30,          // MINUS EQUAL BACKSPACE TAB
            26: 0x21, 27: 0x1E, 28: 0x24, 29: 0x3B,          // [ ] ENTER LEFTCTRL
            39: 0x29, 40: 0x27, 41: 0x32, 42: 0x38, 43: 0x2A, // ; ' ` LEFTSHIFT backslash
            51: 0x2B, 52: 0x2F, 53: 0x2C, 54: 0x3C,          // , . / RIGHTSHIFT
            55: 0x43, 56: 0x3A, 57: 0x31, 58: 0x39,          // KP* LEFTALT SPACE CAPSLOCK
            71: 0x59, 72: 0x5B, 73: 0x5C, 74: 0x4E,          // KP7 KP8 KP9 KP-
            75: 0x56, 76: 0x57, 77: 0x58, 78: 0x45,          // KP4 KP5 KP6 KP+
            79: 0x53, 80: 0x54, 81: 0x55, 82: 0x52, 83: 0x41, // KP1 KP2 KP3 KP0 KP.
            86: 0x0A,                                         // 102ND (ISO key) → §
            87: 0x67, 88: 0x6F,                               // F11 F12
            96: 0x4C, 97: 0x3E, 98: 0x4B, 100: 0x3D,         // KPENTER RIGHTCTRL KP/ RIGHTALT
            102: 0x73, 103: 0x7E, 104: 0x74, 105: 0x7B,      // HOME UP PAGEUP LEFT
            106: 0x7C, 107: 0x77, 108: 0x7D, 109: 0x79,      // RIGHT END DOWN PAGEDOWN
            110: 0x72, 111: 0x75, 117: 0x51,                  // INSERT DELETE KP=
            125: 0x37, 126: 0x36,                             // LEFTMETA RIGHTMETA
            464: 0x3F,                                        // FN
        ]
        // Number row KEY_1 (2) ... KEY_0 (11)
        let digits: [CGKeyCode] = [0x12, 0x13, 0x14, 0x15, 0x17, 0x16, 0x1A, 0x1C, 0x19, 0x1D]
        for (i, k) in digits.enumerated() { m[2 + i] = k }
        // Q W E R T Y U I O P (16-25)
        let top: [CGKeyCode] = [0x0C, 0x0D, 0x0E, 0x0F, 0x11, 0x10, 0x20, 0x22, 0x1F, 0x23]
        for (i, k) in top.enumerated() { m[16 + i] = k }
        // A S D F G H J K L (30-38)
        let home: [CGKeyCode] = [0x00, 0x01, 0x02, 0x03, 0x05, 0x04, 0x26, 0x28, 0x25]
        for (i, k) in home.enumerated() { m[30 + i] = k }
        // Z X C V B N M (44-50)
        let bottom: [CGKeyCode] = [0x06, 0x07, 0x08, 0x09, 0x0B, 0x2D, 0x2E]
        for (i, k) in bottom.enumerated() { m[44 + i] = k }
        // F1 ... F10 (59-68)
        let fkeys: [CGKeyCode] = [0x7A, 0x78, 0x63, 0x76, 0x60, 0x61, 0x62, 0x64, 0x65, 0x6D]
        for (i, k) in fkeys.enumerated() { m[59 + i] = k }
        return m
    }()

    /// Modifier scan codes: LEFTCTRL LEFTSHIFT RIGHTSHIFT LEFTALT CAPSLOCK RIGHTCTRL
    /// RIGHTALT LEFTMETA RIGHTMETA FN.
    private static let modifierScanCodes: Set<Int> = [29, 42, 54, 56, 58, 97, 100, 125, 126, 464]

    /// Android modifier keycodes (their own down/up become flagsChanged events).
    private static let modifierKeycodes: Set<Int> = [57, 58, 59, 60, 113, 114, 115, 117, 118, 119]

    private static var altAsCommand: Bool {
        UserDefaults.standard.bool(forKey: "keyboardAltAsCommand")
    }

    /// macOS modifier flags for an Android metaState.
    static func flags(forMeta meta: Int, altAsCommand: Bool = KeyInjector.altAsCommand) -> CGEventFlags {
        var f: CGEventFlags = []
        if meta & META_SHIFT_ON != 0 { f.insert(.maskShift) }
        if meta & META_CTRL_ON != 0 { f.insert(.maskControl) }
        if meta & META_CAPS_LOCK_ON != 0 { f.insert(.maskAlphaShift) }
        let alt = meta & META_ALT_ON != 0
        let win = meta & META_META_ON != 0
        if altAsCommand {
            if alt { f.insert(.maskCommand) }
            if win { f.insert(.maskAlternate) }
        } else {
            if alt { f.insert(.maskAlternate) }
            if win { f.insert(.maskCommand) }
        }
        return f
    }

    /// macOS key code for a key, preferring its physical scan code (see header).
    static func macKeyCode(scanCode: Int, androidKeycode code: Int,
                           altAsCommand: Bool = KeyInjector.altAsCommand) -> CGKeyCode? {
        if scanCode > 0, let vk = scanMap[scanCode] {
            if altAsCommand {
                switch scanCode {
                case 56: return 0x37    // LEFTALT → Command
                case 100: return 0x36   // RIGHTALT → Right Command
                case 125: return 0x3A   // LEFTMETA → Option
                case 126: return 0x3D   // RIGHTMETA → Right Option
                default: break
                }
            }
            return vk
        }
        return macKeyCode(forAndroid: code, altAsCommand: altAsCommand)
    }

    /// macOS key code for an Android keycode, honoring the Alt/Meta swap.
    static func macKeyCode(forAndroid code: Int, altAsCommand: Bool = KeyInjector.altAsCommand) -> CGKeyCode? {
        if altAsCommand {
            switch code {
            case 57: return 0x37    // ALT_LEFT → Command
            case 58: return 0x36
            case 117: return 0x3A   // META_LEFT → Option
            case 118: return 0x3D
            default: break
            }
        }
        return keyMap[code]
    }

    /// Post one key event. `down` = key pressed; `repeatCount` > 0 marks auto-repeat.
    static func inject(androidKeycode code: Int, scanCode: Int, down: Bool, metaState: Int, repeatCount: Int) {
        guard let vk = macKeyCode(scanCode: scanCode, androidKeycode: code) else {
            NSLog("[Input] Unmapped key: Android keycode %d, scan code %d", code, scanCode)
            return
        }
        let isModifier = scanCode > 0 && scanMap[scanCode] != nil
            ? modifierScanCodes.contains(scanCode)
            : modifierKeycodes.contains(code)
        let flags = flags(forMeta: metaState)
        guard let event = CGEvent(keyboardEventSource: nil, virtualKey: vk, keyDown: down) else { return }
        if isModifier {
            // Modifier press/release: macOS expects a flagsChanged event carrying the
            // new modifier state (Android's metaState already reflects it).
            event.type = .flagsChanged
        } else if repeatCount > 0 {
            event.setIntegerValueField(.keyboardEventAutorepeat, value: 1)
        }
        event.flags = flags
        event.post(tap: .cghidEventTap)
    }
}
