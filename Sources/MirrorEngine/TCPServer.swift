// TCPServer.swift — Native TCP frame server for Daylight Mirror.
//
// Sends LZ4-compressed greyscale frames to connected Android clients over raw TCP.
// Protocol: [DA 7E] [flags] [len:4 LE] [payload]. Keyframes are full LZ4, deltas
// are XOR + LZ4. Also sends resolution and brightness/warmth commands.

import Foundation
import Network
import QuartzCore

struct LatencyStats {
    var rttMs: Double = 0
    var rttMinMs: Double = 0
    var rttMaxMs: Double = 0
    var rttAvgMs: Double = 0
    var rttP95Ms: Double = 0
    var acksReceived: Int = 0
    var ackRate: Double = 0
}

class TCPServer {
    let listener: NWListener
    var connections: [NWConnection] = []
    let queue = DispatchQueue(label: "tcp-server")
    let lock = NSLock()
    var lastKeyframeData: Data?
    var onClientCountChanged: ((Int) -> Void)?
    var onLatencyStats: ((LatencyStats) -> Void)?
    private(set) var latencyStats: LatencyStats?
    var frameWidth: UInt16 = 1024 {
        didSet {
            lock.lock(); lastKeyframeData = nil; lock.unlock()
            if oldValue != frameWidth { broadcastResolution() }
        }
    }
    var frameHeight: UInt16 = 768 {
        didSet {
            lock.lock(); lastKeyframeData = nil; lock.unlock()
            if oldValue != frameHeight { broadcastResolution() }
        }
    }

    // Last-sent display state — re-sent to new clients on connect so
    // brightness/warmth don't reset to defaults after a reconnect.
    private var lastBrightness: UInt8 = 128
    private var lastWarmth: UInt8 = 128
    private var lastEinkMode: UInt8 = EinkMode.auto.rawValue

    /// RGB (3 bytes/pixel) instead of greyscale (1 byte/pixel). Announced to each
    /// client before CMD_RESOLUTION so it can size its buffers.
    var isColorMode: Bool = false {
        didSet { if oldValue != isColorMode { broadcastColorMode() } }
    }
    /// Whether the client is a BOOX panel that should receive Onyx frontlight/EPD state.
    var sendsEinkState: Bool = false

    private var _keyframeRequested = false
    /// Set when a client connects; the capture loop sends a fresh keyframe next.
    /// (A cached keyframe can be up to a second stale, and the deltas that follow it
    /// are computed against newer frames — that would corrupt the client's image.)
    func consumeKeyframeRequest() -> Bool {
        lock.lock(); defer { lock.unlock() }
        let r = _keyframeRequested
        _keyframeRequested = false
        return r
    }

    private var sendTimestamps: [UInt32: Double] = [:]
    private let rttLock = NSLock()
    private var rttSamples: [Double] = []
    private let rttWindowSize = 150
    private var totalAcks: Int = 0
    private var lastAckStatsTime: Double = CACurrentMediaTime()
    private var _inflightFrames: Int = 0

    /// Number of frames sent but not yet ACK'd by Android. Thread-safe (reads rttLock).
    var inflightFrames: Int {
        rttLock.lock()
        let val = _inflightFrames
        rttLock.unlock()
        return val
    }

    /// Wireless: also accept paired clients from the LAN (see NetworkAccess).
    let allowNetwork: Bool

    init(port: UInt16, allowNetwork: Bool = false) throws {
        self.allowNetwork = allowNetwork
        let params = NetworkAccess.listenerParameters(allowNetwork: allowNetwork)
        listener = try NWListener(using: params, on: NWEndpoint.Port(rawValue: port)!)
    }

    func start() {
        listener.stateUpdateHandler = { state in
            if case .ready = state {
                print("TCP server on tcp://localhost:\(self.listener.port?.rawValue ?? 0)")
            }
        }

        listener.newConnectionHandler = { [weak self] conn in
            guard let self = self else { return }
            let viaNetwork = !NetworkAccess.isLoopback(conn.endpoint)
            if viaNetwork && !self.allowNetwork {
                conn.cancel()
                return
            }
            conn.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    // LAN clients must present the pairing secret before seeing the screen
                    if viaNetwork {
                        NetworkAccess.authenticate(conn, queue: self.queue) { ok in
                            if ok {
                                print("[TCP] Wi-Fi client paired: \(conn.endpoint)")
                                self.admit(conn)
                            } else {
                                print("[TCP] Rejected unpaired client \(conn.endpoint)")
                                conn.cancel()
                            }
                        }
                        return
                    }
                    self.admit(conn)
                case .failed, .cancelled:
                    self.lock.lock()
                    let wasAdmitted = self.connections.contains { $0 === conn }
                    self.connections.removeAll { $0 === conn }
                    let count = self.connections.count
                    self.lock.unlock()
                    guard wasAdmitted else { return }
                    self.onClientCountChanged?(count)
                    print("[TCP] Client disconnected (\(state))")
                default: break
                }
            }
            conn.start(queue: self.queue)
        }

        listener.start(queue: queue)
    }

    /// Start streaming to a connected (and, for Wi-Fi, paired) client.
    private func admit(_ conn: NWConnection) {
                    print("[TCP] Client connected")
                    self.lock.lock()
                    self.connections.append(conn)
                    let count = self.connections.count
                    let cachedKeyframe = self.lastKeyframeData
                    self._keyframeRequested = true
                    self.lock.unlock()
                    self.rttLock.lock()
                    self._inflightFrames = 0
                    self.sendTimestamps.removeAll()
                    self.rttLock.unlock()
                    self.onClientCountChanged?(count)

                    // Pixel format first (buffers are sized from it), then dimensions,
                    // then display state — all before any frame.
                    self.sendColorMode(to: conn)
                    self.sendResolution(to: conn)
                    self.sendDisplayState(to: conn)

                    if let kf = cachedKeyframe {
                        conn.send(content: kf, completion: .contentProcessed { _ in })
                        print("[TCP] Sent cached keyframe (\(kf.count) bytes)")
                    } else {
                        print("[TCP] No cached keyframe yet — client will get next broadcast keyframe")
                    }

                    self.receiveLoop(conn)
    }

    func stop() {
        listener.cancel()
        lock.lock()
        for conn in connections { conn.cancel() }
        connections.removeAll()
        lock.unlock()
    }

    func receiveLoop(_ conn: NWConnection) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, _, error in
            guard let self = self, error == nil, let data = data else { return }
            self.rttLock.lock()
            self.parseAckData(data)
            self.rttLock.unlock()
            self.receiveLoop(conn)
        }
    }

    private var ackParseBuffer = Data()

    /// Must be called with rttLock held.
    private func parseAckData(_ data: Data) {
        ackParseBuffer.append(data)

        var scanned = 0
        while ackParseBuffer.count >= 6 {
            guard ackParseBuffer[ackParseBuffer.startIndex] == MAGIC_ACK[0]
                    && ackParseBuffer[ackParseBuffer.index(ackParseBuffer.startIndex, offsetBy: 1)] == MAGIC_ACK[1] else {
                ackParseBuffer.removeFirst()
                scanned += 1
                if scanned > 256 {
                    ackParseBuffer.removeAll()
                    return
                }
                continue
            }

            let base = ackParseBuffer.startIndex
            let b0 = UInt32(ackParseBuffer[ackParseBuffer.index(base, offsetBy: 2)])
            let b1 = UInt32(ackParseBuffer[ackParseBuffer.index(base, offsetBy: 3)]) << 8
            let b2 = UInt32(ackParseBuffer[ackParseBuffer.index(base, offsetBy: 4)]) << 16
            let b3 = UInt32(ackParseBuffer[ackParseBuffer.index(base, offsetBy: 5)]) << 24
            let seq = b0 | b1 | b2 | b3
            ackParseBuffer.removeFirst(6)

            let now = CACurrentMediaTime()

            guard let sendTime = sendTimestamps.removeValue(forKey: seq) else {
                continue
            }
            _inflightFrames -= 1
            if _inflightFrames < 0 { _inflightFrames = 0 }
            let rtt = (now - sendTime) * 1000.0
            rttSamples.append(rtt)
            if rttSamples.count > rttWindowSize {
                rttSamples.removeFirst(rttSamples.count - rttWindowSize)
            }
            totalAcks += 1

            let sorted = rttSamples.sorted()
            let avg = sorted.reduce(0, +) / Double(sorted.count)
            let p95Index = min(Int(Double(sorted.count) * 0.95), sorted.count - 1)

            let elapsed = now - lastAckStatsTime
            let rate = elapsed > 0 ? Double(totalAcks) / elapsed : 0

            let stats = LatencyStats(
                rttMs: rtt,
                rttMinMs: sorted.first ?? 0,
                rttMaxMs: sorted.last ?? 0,
                rttAvgMs: avg,
                rttP95Ms: sorted[p95Index],
                acksReceived: totalAcks,
                ackRate: rate
            )

            if totalAcks % 30 == 0 {
                print(String(format: "[RTT] last: %.1fms | avg: %.1fms | p95: %.1fms | min: %.1fms | max: %.1fms | acks: %d",
                             stats.rttMs, stats.rttAvgMs, stats.rttP95Ms, stats.rttMinMs, stats.rttMaxMs, stats.acksReceived))
            }

            latencyStats = stats
            onLatencyStats?(stats)
        }
    }

    func broadcast(payload: Data, isKeyframe: Bool, sequenceNumber: UInt32 = 0, tiled: Bool = false) {
        var header = Data(capacity: FRAME_HEADER_SIZE)
        header.append(contentsOf: MAGIC_FRAME)
        header.append(isKeyframe ? FLAG_KEYFRAME : (tiled ? FLAG_TILED : 0))
        var seq = sequenceNumber.littleEndian
        header.append(Data(bytes: &seq, count: 4))
        var len = UInt32(payload.count).littleEndian
        header.append(Data(bytes: &len, count: 4))

        var frame = header
        frame.append(payload)

        let sendTime = CACurrentMediaTime()

        lock.lock()
        if isKeyframe { lastKeyframeData = frame }
        let conns = connections
        lock.unlock()

        rttLock.lock()
        sendTimestamps[sequenceNumber] = sendTime
        _inflightFrames += 1
        // Evict old entries to prevent unbounded growth
        if sendTimestamps.count > 300 {
            let evicted = sendTimestamps.count
            let cutoff = sequenceNumber &- 300
            sendTimestamps = sendTimestamps.filter { $0.key > cutoff }
            _inflightFrames -= (evicted - sendTimestamps.count)
            if _inflightFrames < 0 { _inflightFrames = 0 }
        }
        rttLock.unlock()

        for conn in conns {
            conn.send(content: frame, completion: .contentProcessed { _ in })
        }
    }

    func sendCommand(_ cmd: UInt8, value: UInt8) {
        // Track state so we can re-send on client reconnect
        if cmd == CMD_BRIGHTNESS { lastBrightness = value }
        if cmd == CMD_WARMTH { lastWarmth = value }
        if cmd == CMD_EINK_MODE { lastEinkMode = value }

        var packet = Data(capacity: 4)
        packet.append(contentsOf: MAGIC_CMD)
        packet.append(cmd)
        packet.append(value)

        lock.lock()
        let conns = connections
        lock.unlock()

        for conn in conns {
            conn.send(content: packet, completion: .contentProcessed { _ in })
        }
    }

    /// Broadcast resolution to all connected clients (called when frameWidth/frameHeight change)
    func broadcastResolution() {
        lock.lock()
        let conns = connections
        lock.unlock()
        for conn in conns {
            sendResolution(to: conn)
        }
    }

    /// Re-send current brightness/warmth to a specific client on (re)connect
    /// so the Daylight doesn't revert to defaults.
    func sendDisplayState(to conn: NWConnection) {
        var bPkt = Data(capacity: 4)
        bPkt.append(contentsOf: MAGIC_CMD)
        bPkt.append(CMD_BRIGHTNESS)
        bPkt.append(lastBrightness)
        conn.send(content: bPkt, completion: .contentProcessed { _ in })
        print("[TCP] Sent brightness: \(self.lastBrightness)")

        guard sendsEinkState else { return }
        for (cmd, value) in [(CMD_WARMTH, lastWarmth), (CMD_EINK_MODE, lastEinkMode)] {
            var pkt = Data(capacity: 4)
            pkt.append(contentsOf: MAGIC_CMD)
            pkt.append(cmd)
            pkt.append(value)
            conn.send(content: pkt, completion: .contentProcessed { _ in })
        }
    }

    /// Send pixel format to a specific client: [DA 7F] [05] [0=grey, 1=RGB]
    func sendColorMode(to conn: NWConnection) {
        var packet = Data(capacity: 4)
        packet.append(contentsOf: MAGIC_CMD)
        packet.append(CMD_COLOR_MODE)
        packet.append(isColorMode ? 1 : 0)
        conn.send(content: packet, completion: .contentProcessed { _ in })
        print("[TCP] Sent color mode: \(isColorMode ? "RGB" : "greyscale")")
    }

    private func broadcastColorMode() {
        lock.lock()
        let conns = connections
        _keyframeRequested = true
        lock.unlock()
        for conn in conns { sendColorMode(to: conn) }
    }

    /// Send resolution command to a specific client: [DA 7F] [04] [w:2 LE] [h:2 LE]
    func sendResolution(to conn: NWConnection) {
        var packet = Data(capacity: 7)
        packet.append(contentsOf: MAGIC_CMD)
        packet.append(CMD_RESOLUTION)
        var w = frameWidth.littleEndian
        var h = frameHeight.littleEndian
        packet.append(Data(bytes: &w, count: 2))
        packet.append(Data(bytes: &h, count: 2))
        conn.send(content: packet, completion: .contentProcessed { _ in })
        print("[TCP] Sent resolution: \(self.frameWidth)x\(self.frameHeight)")
    }
}
