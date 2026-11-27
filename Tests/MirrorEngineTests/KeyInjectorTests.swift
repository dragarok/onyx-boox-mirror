import CoreGraphics
import XCTest
@testable import MirrorEngine

final class KeyInjectorTests: XCTestCase {
    func testLettersMapToANSIPositions() {
        XCTAssertEqual(KeyInjector.macKeyCode(forAndroid: 29, altAsCommand: false), 0x00) // A
        XCTAssertEqual(KeyInjector.macKeyCode(forAndroid: 31, altAsCommand: false), 0x08) // C
        XCTAssertEqual(KeyInjector.macKeyCode(forAndroid: 50, altAsCommand: false), 0x09) // V
        XCTAssertEqual(KeyInjector.macKeyCode(forAndroid: 54, altAsCommand: false), 0x06) // Z
    }

    func testEditingKeys() {
        XCTAssertEqual(KeyInjector.keyMap[66], 0x24)   // Enter → Return
        XCTAssertEqual(KeyInjector.keyMap[67], 0x33)   // Backspace → Delete
        XCTAssertEqual(KeyInjector.keyMap[112], 0x75)  // Forward delete
        XCTAssertEqual(KeyInjector.keyMap[111], 0x35)  // Esc
        XCTAssertEqual(KeyInjector.keyMap[61], 0x30)   // Tab
        XCTAssertEqual(KeyInjector.keyMap[21], 0x7B)   // Left arrow
    }

    func testAllDigitsAndLettersMapped() {
        for code in 7...16 { XCTAssertNotNil(KeyInjector.keyMap[code], "digit keycode \(code)") }
        for code in 29...54 { XCTAssertNotNil(KeyInjector.keyMap[code], "letter keycode \(code)") }
        // Distinct physical keys must not collide
        let letterCodes = (29...54).compactMap { KeyInjector.keyMap[$0] }
        XCTAssertEqual(Set(letterCodes).count, 26)
    }

    func testMetaIsCommandByDefault() {
        let f = KeyInjector.flags(forMeta: 0x10000, altAsCommand: false)
        XCTAssertTrue(f.contains(.maskCommand))
        XCTAssertFalse(f.contains(.maskAlternate))
        XCTAssertTrue(KeyInjector.flags(forMeta: 0x2, altAsCommand: false).contains(.maskAlternate))
    }

    func testAltAsCommandSwap() {
        XCTAssertTrue(KeyInjector.flags(forMeta: 0x2, altAsCommand: true).contains(.maskCommand))
        XCTAssertTrue(KeyInjector.flags(forMeta: 0x10000, altAsCommand: true).contains(.maskAlternate))
        XCTAssertEqual(KeyInjector.macKeyCode(forAndroid: 57, altAsCommand: true), 0x37)
        XCTAssertEqual(KeyInjector.macKeyCode(forAndroid: 117, altAsCommand: true), 0x3A)
    }

    func testShiftCtrlCaps() {
        let f = KeyInjector.flags(forMeta: 0x1 | 0x1000 | 0x100000, altAsCommand: false)
        XCTAssertTrue(f.contains(.maskShift))
        XCTAssertTrue(f.contains(.maskControl))
        XCTAssertTrue(f.contains(.maskAlphaShift))
    }
}

final class KeyInjectorScanCodeTests: XCTestCase {
    func testScanCodeIsPhysicalPosition() {
        // Physical E key (KEY_E = 18) must post the E-position key whatever keycode
        // Android reports — e.g. Full Colemak turns it into KEYCODE_F (34).
        XCTAssertEqual(KeyInjector.macKeyCode(scanCode: 18, androidKeycode: 34, altAsCommand: false), 0x0E)
        XCTAssertEqual(KeyInjector.macKeyCode(scanCode: 37, androidKeycode: 33, altAsCommand: false), 0x28) // K pos
        XCTAssertEqual(KeyInjector.macKeyCode(scanCode: 30, androidKeycode: 29, altAsCommand: false), 0x00) // A pos
    }

    func testFallsBackToKeycodeWithoutScanCode() {
        XCTAssertEqual(KeyInjector.macKeyCode(scanCode: 0, androidKeycode: 33, altAsCommand: false), 0x0E)
        XCTAssertEqual(KeyInjector.macKeyCode(scanCode: 9999, androidKeycode: 33, altAsCommand: false), 0x0E)
    }

    func testScanCodeLettersAreDistinct() {
        let letterScans = Array(16...25) + Array(30...38) + Array(44...50)
        let vks = letterScans.compactMap { KeyInjector.scanMap[$0] }
        XCTAssertEqual(vks.count, 26)
        XCTAssertEqual(Set(vks).count, 26)
        // Same physical letters as the keycode table
        XCTAssertEqual(Set(vks), Set((29...54).compactMap { KeyInjector.keyMap[$0] }))
    }

    func testScanCodeModifiersAndSwap() {
        XCTAssertEqual(KeyInjector.macKeyCode(scanCode: 125, androidKeycode: 117, altAsCommand: false), 0x37) // Meta → Cmd
        XCTAssertEqual(KeyInjector.macKeyCode(scanCode: 56, androidKeycode: 57, altAsCommand: false), 0x3A)   // Alt → Option
        XCTAssertEqual(KeyInjector.macKeyCode(scanCode: 56, androidKeycode: 57, altAsCommand: true), 0x37)    // swapped
    }
}
