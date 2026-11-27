import Network
import XCTest
@testable import MirrorEngine

final class NetworkAccessTests: XCTestCase {
    func testHexRoundTrip() {
        let bytes: [UInt8] = [0x00, 0x7f, 0x80, 0xff, 0x12, 0xab]
        XCTAssertEqual(NetworkAccess.bytes(fromHex: NetworkAccess.hex(bytes)), bytes)
        XCTAssertNil(NetworkAccess.bytes(fromHex: "abc"))
        XCTAssertNil(NetworkAccess.bytes(fromHex: "zz"))
    }

    func testSecretIsStableAndSized() {
        let a = NetworkAccess.secret
        XCTAssertEqual(a.count, NetworkAccess.secretLength)
        XCTAssertEqual(NetworkAccess.secret, a, "secret must persist between reads")
        XCTAssertEqual(NetworkAccess.secretHex.count, 32)
    }

    func testLoopbackDetection() {
        XCTAssertTrue(NetworkAccess.isLoopback(.hostPort(host: "127.0.0.1", port: 8888)))
        XCTAssertTrue(NetworkAccess.isLoopback(.hostPort(host: "::1", port: 8888)))
        XCTAssertTrue(NetworkAccess.isLoopback(.hostPort(host: "::ffff:127.0.0.1", port: 8888)))
        XCTAssertFalse(NetworkAccess.isLoopback(.hostPort(host: "192.168.10.66", port: 8888)))
        XCTAssertFalse(NetworkAccess.isLoopback(.hostPort(host: "100.69.104.127", port: 8888)))
    }

    func testAuthPacketLayout() {
        XCTAssertEqual(NetworkAccess.magicAuth, [0xDA, 0x75])
        XCTAssertEqual(NetworkAccess.authPacketLength, 18)
    }

    func testLanAddressesAreIPv4AndNotLoopback() {
        for ip in NetworkAccess.lanAddresses() {
            XCTAssertEqual(ip.split(separator: ".").count, 4, ip)
            XCTAssertFalse(ip.hasPrefix("127."))
            XCTAssertFalse(ip.hasPrefix("169.254."))
        }
    }
}
