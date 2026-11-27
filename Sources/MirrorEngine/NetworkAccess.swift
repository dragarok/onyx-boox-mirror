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

    /// Tailscale addresses (IPv4 in 100.64.0.0/10) on interfaces that also carry Tailscale's
    /// IPv6 prefix fd7a:115c:a1e0::/48, so other VPNs using the CGNAT range are left out.
    /// More than one when the Mac is signed in to several tailnets.
    static func tailnetAddresses() -> [String] {
        var v4: [String: [String]] = [:]
        var tailscaleInterfaces = Set<String>()
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let first = ifaddr else { return [] }
        defer { freeifaddrs(ifaddr) }
        for ptr in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let ifa = ptr.pointee
            guard let sa = ifa.ifa_addr, Int32(ifa.ifa_flags) & IFF_UP != 0 else { continue }
            let family = Int32(sa.pointee.sa_family)
            guard family == AF_INET || family == AF_INET6 else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(sa, socklen_t(sa.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 else { continue }
            let ip = String(cString: host)
            let name = String(cString: ifa.ifa_name)
            if family == AF_INET6, ip.lowercased().hasPrefix("fd7a:115c:a1e0:") { tailscaleInterfaces.insert(name) }
            if family == AF_INET, isTailnetIPv4(ip) { v4[name, default: []].append(ip) }
        }
        return v4.filter { tailscaleInterfaces.contains($0.key) }
            .sorted { $0.key < $1.key }
            .flatMap { $0.value }
    }

    /// 100.64.0.0/10 — the shared address space Tailscale assigns from.
    static func isTailnetIPv4(_ ip: String) -> Bool {
        let parts = ip.split(separator: ".").compactMap { UInt8($0) }
        guard parts.count == 4 else { return false }
        return parts[0] == 100 && (parts[1] & 0xC0) == 64
    }

    /// UserDefaults key: the Mac's own Tailscale addresses tablets may use. When the Mac is
    /// in several tailnets (say personal and work), only these are offered and accepted.
    /// Unset = every tailnet. Set with:
    ///   defaults write com.daylight.mirror tailscaleAddresses -array 100.x.y.z
    static let allowedTailnetKey = "tailscaleAddresses"

    static var tailnetAllowlist: Set<String>? {
        guard let list = UserDefaults.standard.stringArray(forKey: allowedTailnetKey), !list.isEmpty else { return nil }
        return Set(list)
    }

    /// The Mac's Tailscale addresses tablets may use (see `allowedTailnetKey`).
    static func allowedTailnetAddresses() -> [String] {
        let all = tailnetAddresses()
        guard let allow = tailnetAllowlist else { return all }
        return all.filter { allow.contains($0) }
    }

    /// Every address a paired tablet may try: home network first, then Tailscale for when
    /// it's away.
    static func pairingHosts() -> [String] {
        var seen = Set<String>()
        return (lanAddresses() + allowedTailnetAddresses()).filter { seen.insert($0).inserted }
    }

    /// The IPv4 address of an endpoint (plain or IPv4-mapped IPv6), as dotted text.
    static func ipv4String(_ endpoint: NWEndpoint?) -> String? {
        guard let endpoint, case let .hostPort(host, _) = endpoint else { return nil }
        let raw: Data
        switch host {
        case .ipv4(let a): raw = a.rawValue
        case .ipv6(let a):
            let r = a.rawValue
            guard r.count == 16, r.prefix(10).allSatisfy({ $0 == 0 }), r[10] == 0xFF, r[11] == 0xFF else { return nil }
            raw = r.suffix(4)
        default: return nil
        }
        guard raw.count == 4 else { return nil }
        return raw.map(String.init).joined(separator: ".")
    }

    /// True when a connection reached the Mac through one of its Tailscale addresses
    /// (the tablet is away from home).
    static func arrivedViaTailnet(_ conn: NWConnection) -> Bool {
        guard let local = ipv4String(conn.currentPath?.localEndpoint) else { return false }
        return isTailnetIPv4(local)
    }

    /// True when a connection reached the Mac through a tailnet that isn't allowed — the
    /// Mac's own address it connected to is a Tailscale one outside the allowlist.
    static func arrivedViaBlockedTailnet(localAddress: String?) -> Bool {
        guard let local = localAddress, isTailnetIPv4(local), let allow = tailnetAllowlist else { return false }
        return !allow.contains(local)
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
                if arrivedViaBlockedTailnet(localAddress: ipv4String(conn.currentPath?.localEndpoint)) {
                    return finish(false)
                }
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
