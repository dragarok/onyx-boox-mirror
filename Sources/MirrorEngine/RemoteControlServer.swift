// RemoteControlServer.swift — lets the device itself start mirroring.
//
// Always listening while the app runs, even when mirroring is stopped:
//   - over USB the device reaches it through an adb reverse tunnel (loopback, trusted);
//   - with Wireless on it also listens on the LAN and advertises the Mac via Bonjour
//     (_daylight-mirror._tcp); LAN clients must open with the pairing secret
//     ([DA 75][secret:16], see NetworkAccess).
// The companion app asks STATUS to learn the Mac is there, shows a Mirror / Second
// monitor chooser, then sends START <mode>.
//
// One request per connection — a text line, answered with one line, then closed:
//   STATUS                 → OK <idle|starting|running|stopping|error> <mirror|extended> <Mac name>
//   START [mirror|extend]  → start (or switch mode); no mode = the Mac's current setting
//   RELEASE                → the device is done: stop, if the device started it

import Foundation
import Network
import SystemConfiguration

final class RemoteControlServer {
    private var listener: NWListener?
    private let queue = DispatchQueue(label: "remote-control")
    /// (command line, arrived over Tailscale) → reply line
    private let handler: @MainActor (String, Bool) -> String
    private(set) var allowNetwork = false

    init(handler: @escaping @MainActor (String, Bool) -> String) {
        self.handler = handler
    }

    /// The Mac's user-visible name ("Alex's MacBook Pro").
    static var computerName: String {
        (SCDynamicStoreCopyComputerName(nil, nil) as String?) ?? "Mac"
    }

    /// (Re)start listening; `allowNetwork` adds the LAN + Bonjour on top of loopback.
    func start(allowNetwork: Bool) {
        if listener != nil && allowNetwork == self.allowNetwork { return }
        stop()
        self.allowNetwork = allowNetwork
        do {
            let l = try NWListener(using: NetworkAccess.listenerParameters(allowNetwork: allowNetwork),
                                   on: NWEndpoint.Port(rawValue: REMOTE_PORT)!)
            if allowNetwork {
                l.service = NWListener.Service(name: Self.computerName, type: "_daylight-mirror._tcp")
            }
            l.newConnectionHandler = { [weak self] conn in self?.handle(conn) }
            l.stateUpdateHandler = { state in
                if case .failed(let error) = state {
                    NSLog("[Remote] Listener failed: %@", "\(error)")
                }
            }
            l.start(queue: queue)
            listener = l
            NSLog("[Remote] Listening on port %d (%@)", REMOTE_PORT, allowNetwork ? "USB + Wi-Fi" : "USB only")
        } catch {
            NSLog("[Remote] Could not listen on port %d: %@", REMOTE_PORT, "\(error)")
        }
    }

    func stop() {
        listener?.cancel()
        listener = nil
    }

    private func handle(_ conn: NWConnection) {
        let viaNetwork = !NetworkAccess.isLoopback(conn.endpoint)
        if viaNetwork && !allowNetwork {
            conn.cancel()
            return
        }
        conn.stateUpdateHandler = { [weak self] state in
            guard let self, case .ready = state else { return }
            if viaNetwork {
                NetworkAccess.authenticate(conn, queue: self.queue) { ok in
                    if ok {
                        self.readCommand(conn)
                    } else {
                        NSLog("[Remote] Rejected unpaired client %@", "\(conn.endpoint)")
                        conn.cancel()
                    }
                }
            } else {
                self.readCommand(conn)
            }
        }
        conn.start(queue: queue)
        queue.asyncAfter(deadline: .now() + 10) { conn.cancel() }  // never hold a slot open
    }

    private func readCommand(_ conn: NWConnection, buffer: Data = Data()) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 128) { [weak self] data, _, done, error in
            guard let self else { return }
            var buf = buffer
            if let data { buf.append(data) }
            if let nl = buf.firstIndex(of: 0x0A) {
                let line = String(decoding: buf[buf.startIndex..<nl], as: UTF8.self)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                let handler = self.handler
                let viaTailnet = NetworkAccess.arrivedViaTailnet(conn)
                Task { @MainActor in
                    let reply = handler(line, viaTailnet)
                    conn.send(content: Data((reply + "\n").utf8), completion: .contentProcessed { _ in
                        conn.cancel()
                    })
                }
            } else if error != nil || done || buf.count >= 128 {
                conn.cancel()
            } else {
                self.readCommand(conn, buffer: buf)
            }
        }
    }
}
