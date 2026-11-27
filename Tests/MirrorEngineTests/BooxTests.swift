import XCTest
@testable import MirrorEngine

final class BooxTests: XCTestCase {
    private var savedPanel: (w: UInt, h: UInt) = (0, 0)

    override func setUp() {
        super.setUp()
        savedPanel = BooxPanel.landscape
    }

    override func tearDown() {
        BooxPanel.landscape = savedPanel
        super.tearDown()
    }

    // MARK: - Presets follow the detected panel

    func testRetinaMatchesFullPanel() {
        BooxPanel.update(width: 2480, height: 1860)
        XCTAssertEqual(DisplayResolution.booxRetina.width, 2480)
        XCTAssertEqual(DisplayResolution.booxRetina.height, 1860)
        XCTAssertTrue(DisplayResolution.booxRetina.isHiDPI)
    }

    func testRetinaFollowsReservedPanelArea() {
        // Tab Ultra C with the firmware's 180 px strip reserved: wm size = 2480x1680
        BooxPanel.update(width: 2480, height: 1680)
        XCTAssertEqual(DisplayResolution.booxRetina.width, 2480)
        XCTAssertEqual(DisplayResolution.booxRetina.height, 1680)
        XCTAssertEqual(DisplayResolution.booxBalanced.width, 1240)
        XCTAssertEqual(DisplayResolution.booxBalanced.height, 840)
        XCTAssertEqual(DisplayResolution.booxPortraitRetina.width, 1680)
        XCTAssertEqual(DisplayResolution.booxPortraitRetina.height, 2480)
    }

    func testPanelUpdateAcceptsPortraitReading() {
        BooxPanel.update(width: 1860, height: 2480)
        XCTAssertEqual(BooxPanel.landscape.w, 2480)
        XCTAssertEqual(BooxPanel.landscape.h, 1860)
    }

    func testPanelUpdateIgnoresZero() {
        BooxPanel.update(width: 2480, height: 1860)
        BooxPanel.update(width: 0, height: 1200)
        XCTAssertEqual(BooxPanel.landscape.w, 2480)
        XCTAssertEqual(BooxPanel.landscape.h, 1860)
    }

    func testBooxPresetDimensionsAreEven() {
        // HiDPI virtual displays need even pixel sizes; try an odd-sized panel
        BooxPanel.update(width: 1871, height: 1403)
        for res in DisplayResolution.presets(for: .boox) {
            XCTAssertEqual(res.width % 2, 0, "\(res.label) width \(res.width) is odd")
            XCTAssertEqual(res.height % 2, 0, "\(res.label) height \(res.height) is odd")
            XCTAssertGreaterThan(res.width, 0)
            XCTAssertGreaterThan(res.height, 0)
        }
    }

    func testBooxPortraitPresetsAreTaller() {
        BooxPanel.update(width: 2480, height: 1860)
        for res in DisplayResolution.presets(for: .boox) where res.isPortrait {
            XCTAssertGreaterThan(res.height, res.width, res.label)
        }
        for res in DisplayResolution.presets(for: .boox) where !res.isPortrait {
            XCTAssertGreaterThan(res.width, res.height, res.label)
        }
    }

    // MARK: - Preset families don't mix

    func testPresetFamiliesArePartitioned() {
        let dc1 = DisplayResolution.presets(for: .daylightDC1)
        let boox = DisplayResolution.presets(for: .boox)
        XCTAssertTrue(dc1.allSatisfy { $0.family == .daylightDC1 })
        XCTAssertTrue(boox.allSatisfy { $0.family == .boox })
        XCTAssertEqual(dc1.count + boox.count, DisplayResolution.allCases.count)
        XCTAssertEqual(DisplayResolution.presets(for: .other), dc1)
    }

    func testDefaultBooxPresetIsRetina() {
        XCTAssertEqual(DisplayResolution.presets(for: .boox).first, .booxRetina)
    }

    // MARK: - Device identification

    func testTabUltraCIsBoox() {
        let d = ConnectedDevice(serial: "2B952BE1", model: "TabUltraC", product: "BOOX", deviceName: "BOOX")
        XCTAssertEqual(d.deviceFamily, .boox)
        XCTAssertTrue(d.deviceFamily.isSupported)
        XCTAssertTrue(d.deviceFamily.usesOnyxFrontlight)
        XCTAssertTrue(d.deviceFamily.defaultsToColor)
    }

    func testPhoneNamedOnyxIsNotBoox() {
        // A phone whose codename happens to be "onyx" must not get a mirror session
        let d = ConnectedDevice(serial: "abc", model: "23049PCD8I", product: "onyx_in", deviceName: "onyx")
        XCTAssertEqual(d.deviceFamily, .other)
        XCTAssertFalse(d.deviceFamily.isSupported)
    }

    func testBooxTargetsThirtyFPS() {
        XCTAssertEqual(DeviceFamily.boox.targetFPS, 30)
    }

    // MARK: - Protocol constants the Android client depends on

    func testBooxProtocolConstants() {
        XCTAssertEqual(CMD_COLOR_MODE, 0x05)
        XCTAssertEqual(CMD_REFRESH, 0x06)
        XCTAssertEqual(CMD_EINK_MODE, 0x07)
        XCTAssertEqual(FLAG_TILED, 0x02)
        XCTAssertEqual(TILE_SIZE, 64)
        XCTAssertEqual(EinkMode.allCases.map(\.rawValue), [0, 1, 2, 3])
    }
}

final class DeviceFilterTests: XCTestCase {
    func testWirelessPhoneIsNeverTreatedAsDC1() {
        let phone = ConnectedDevice(serial: "127.0.0.1:15555", model: "25053PC47I", product: "onyx_in", deviceName: "onyx")
        XCTAssertTrue(ADBBridge.filterSupported([phone]).isEmpty)
    }

    func testEmulatorIsNeverTreatedAsDC1() {
        let emu = ConnectedDevice(serial: "emulator-5554", model: "sdk_gphone64_arm64")
        XCTAssertTrue(ADBBridge.filterSupported([emu]).isEmpty)
    }

    func testLoneUSBUnknownDeviceStillFallsBack() {
        let usb = ConnectedDevice(serial: "ABC123", model: "weird")
        XCTAssertEqual(ADBBridge.filterSupported([usb]).map(\.serial), ["ABC123"])
    }

    func testBooxPickedOverPhone() {
        let boox = ConnectedDevice(serial: "2B952BE1", model: "TabUltraC", product: "BOOX", deviceName: "BOOX")
        let phone = ConnectedDevice(serial: "127.0.0.1:15555", model: "25053PC47I", product: "onyx_in", deviceName: "onyx")
        XCTAssertEqual(ADBBridge.filterSupported([phone, boox]).map(\.serial), ["2B952BE1"])
    }
}
