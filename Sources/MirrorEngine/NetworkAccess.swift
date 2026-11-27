// NetworkAccess.swift — Wi-Fi access control for the stream and input servers.
//
// Over USB the device reaches the Mac through the adb reverse tunnel, which arrives on
// loopback and is trusted. Wireless mode also listens on the LAN, where anyone on the
// same network could otherwise watch the screen (port 8888) or inject clicks and keys
// (port 8892). So every non-loopback connection must open with an auth packet carrying
// a pairing secret: [DA 75][secret:16]. The secret is generated once and handed to the
// device over USB (ADBBridge.launchApp extras) — plug in once to pair.
//
// The stream itself is not encrypted; on an untrusted network prefer Tailscale
// (WireGuard) or USB.

import Foundation
import Network

enum NetworkAccess {
    static let magicAuth: [UInt8] = [0xDA, 0x75]
    static let secretLength = 16
    static let authPacketLength = 2 + secretLength

    /// Pairing secret, created on first use and kept in the app's defaults.
    static var secret: [UInt8] {
        let key = "pairingSecret"
        if let hex = UserDefaults.standard.string(forKey: key), let bytes = bytes(fromHex: hex),
           bytes.count == secretLength {
            return bytes
        }
        var fresh = [UInt8](repeating: 0, count: secretLength)
        let status = SecRandomCopyBytes(kSecRandomDefault, secretLength, &fresh)
        if status != errSecSuccess {
            for i in 0..<secretLength { fresh[i] = UInt8.random(in: 0...255) }
        }
        UserDefaults.standard.set(hex(fresh), forKey: key)
        return fresh
    }

    static var secretHex: String { hex(secret) }

    /// True when the peer is this Mac (adb reverse tunnel, local tools).
    static func isLoopback(_ endpoint: NWEndpoint) -> Bool {
        guard case let .hostPort(host, _) = endpoint else { return false }
        switch host {
        case .ipv4(let a): return a.isLoopback
        case .ipv6(let a):
            if a.isLoopback { return true }
            // IPv4-mapped loopback (::ffff:127.x.x.x)
            let raw = a.rawValue
            return raw.count == 16 && raw.prefix(10).allSatisfy { $0 == 0 } &&
                raw[10] == 0xFF && raw[11] == 0xFF && raw[12] == 127
        case .name(let n, _): return n == "localhost"
        @unknown default: return false
        }
    }

    /// The Mac's LAN IPv4 addresses (Wi-Fi / Ethernet), handed to the device for Wi-Fi.
    static func lanAddresses() -> [String] {
        var result: [String] = []
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let first = ifaddr else { return [] }
        defer { freeifaddrs(ifaddr) }
        for ptr in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let ifa = ptr.pointee
            guard let sa = ifa.ifa_addr, sa.pointee.sa_family == UInt8(AF_INET) else { continue }
            let flags = Int32(ifa.ifa_flags)
            guard flags & IFF_UP != 0, flags & IFF_LOOPBACK == 0 else { continue }
            let name = String(cString: ifa.ifa_name)
            guard name.hasPrefix("en") else { continue }  // Wi-Fi / Ethernet, not VPN tunnels
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            if getnameinfo(sa, socklen_t(sa.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 {
                let ip = String(cString: host)
                if !ip.hasPrefix("169.254.") { result.append(ip) }  // skip link-local
            }
        }
        return result
    }

    /// Read the auth packet from a fresh non-loopback connection; calls back with the
    /// verdict on `queue`. Times out after 3 s.
    static func authenticate(_ conn: NWConnection, queue: DispatchQueue, completion: @escaping (Bool) -> Void) {
        var finished = false
        let finish: (Bool) -> Void = { ok in
            guard !finished else { return }
            finished = true
            completion(ok)
        }
        queue.asyncAfter(deadline: .now() + 3) { finish(false) }
        conn.receive(minimumIncompleteLength: authPacketLength, maximumLength: authPacketLength) { data, _, _, error in
            queue.async {
                guard error == nil, let data = data, data.count == authPacketLength else { return finish(false) }
                let bytes = [UInt8](data)
                guard bytes[0] == magicAuth[0], bytes[1] == magicAuth[1] else { return finish(false) }
                // Constant-time comparison
                let expected = secret
                var diff: UInt8 = 0
                for i in 0..<secretLength { diff |= bytes[2 + i] ^ expected[i] }
                finish(diff == 0)
            }
        }
    }

    /// Listener parameters: loopback-only unless network access is allowed.
    static func listenerParameters(allowNetwork: Bool, noDelay: Bool = true) -> NWParameters {
        let params = NWParameters.tcp
        if let tcp = params.defaultProtocolStack.transportProtocol as? NWProtocolTCP.Options {
            tcp.noDelay = noDelay
        }
        params.allowLocalEndpointReuse = true
        if !allowNetwork { params.requiredInterfaceType = .loopback }
        return params
    }

    static func hex(_ bytes: [UInt8]) -> String { bytes.map { String(format: "%02x", $0) }.joined() }

    static func bytes(fromHex hex: String) -> [UInt8]? {
        guard hex.count % 2 == 0 else { return nil }
        var out: [UInt8] = []
        var idx = hex.startIndex
        while idx < hex.endIndex {
            let next = hex.index(idx, offsetBy: 2)
            guard let b = UInt8(hex[idx..<next], radix: 16) else { return nil }
            out.append(b)
            idx = next
        }
        return out
    }
}
