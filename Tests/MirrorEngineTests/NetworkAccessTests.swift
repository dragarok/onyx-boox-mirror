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

    func testTailnetRange() {
        XCTAssertTrue(NetworkAccess.isTailnetIPv4("100.64.0.1"))
        XCTAssertTrue(NetworkAccess.isTailnetIPv4("100.69.104.127"))
        XCTAssertTrue(NetworkAccess.isTailnetIPv4("100.127.255.254"))
        XCTAssertFalse(NetworkAccess.isTailnetIPv4("100.63.255.255"))
        XCTAssertFalse(NetworkAccess.isTailnetIPv4("100.128.0.1"))
        XCTAssertFalse(NetworkAccess.isTailnetIPv4("192.168.10.239"))
        XCTAssertFalse(NetworkAccess.isTailnetIPv4("not-an-ip"))
    }

    func testPairingHostsListHomeNetworkFirst() {
        let hosts = NetworkAccess.pairingHosts()
        XCTAssertEqual(Array(hosts.prefix(NetworkAccess.lanAddresses().count)), NetworkAccess.lanAddresses())
        XCTAssertEqual(hosts.count, Set(hosts).count)
        for ip in NetworkAccess.tailnetAddresses() { XCTAssertTrue(hosts.contains(ip)) }
    }

    func testTailnetAllowlistBlocksOtherTailnets() {
        let key = NetworkAccess.allowedTailnetKey
        let saved = UserDefaults.standard.object(forKey: key)
        defer { UserDefaults.standard.set(saved, forKey: key) }

        UserDefaults.standard.removeObject(forKey: key)
        XCTAssertFalse(NetworkAccess.arrivedViaBlockedTailnet(localAddress: "100.69.104.127"))

        UserDefaults.standard.set(["100.79.230.45"], forKey: key)
        XCTAssertFalse(NetworkAccess.arrivedViaBlockedTailnet(localAddress: "100.79.230.45"))
        XCTAssertTrue(NetworkAccess.arrivedViaBlockedTailnet(localAddress: "100.69.104.127"))
        XCTAssertFalse(NetworkAccess.arrivedViaBlockedTailnet(localAddress: "192.168.10.239"))  // home network
        XCTAssertFalse(NetworkAccess.arrivedViaBlockedTailnet(localAddress: nil))
        XCTAssertFalse(NetworkAccess.pairingHosts().contains("100.69.104.127"))
    }

    func testIPv4StringFromEndpoints() {
        let v4 = NWEndpoint.hostPort(host: .ipv4(IPv4Address("100.79.230.45")!), port: 8893)
        XCTAssertEqual(NetworkAccess.ipv4String(v4), "100.79.230.45")
        let mapped = NWEndpoint.hostPort(host: .ipv6(IPv6Address("::ffff:100.69.104.127")!), port: 8893)
        XCTAssertEqual(NetworkAccess.ipv4String(mapped), "100.69.104.127")
        let v6 = NWEndpoint.hostPort(host: .ipv6(IPv6Address("fd7a:115c:a1e0::1")!), port: 8893)
        XCTAssertNil(NetworkAccess.ipv4String(v6))
        XCTAssertNil(NetworkAccess.ipv4String(nil))
    }
}
