// ScreenCapture.swift — CPU-only screen capture with LZ4 delta compression.
//
// Captures the virtual display via CGDisplayStream (loaded at runtime via dlsym
// to bypass macOS 15 SDK deprecation), converts BGRA to RGB (drops alpha),
// then LZ4 compresses (keyframe or XOR delta). Zero GPU usage.

import Foundation
import Darwin
import IOSurface
import CoreImage
import QuartzCore
import CLZ4
import Accelerate

// MARK: - Screen Capture Errors

enum ScreenCaptureError: LocalizedError {
    case permissionDenied
    case contentEnumerationFailed(Error)

    var errorDescription: String? {
        switch self {
        case .permissionDenied:
            return "Screen Recording permission not granted. Open System Settings > Privacy & Security > Screen Recording and enable Daylight Mirror, then restart the app."
        case .contentEnumerationFailed(let underlying):
            return "Could not access screen content (permission may be pending). Grant Screen Recording in System Settings and retry. (\(underlying.localizedDescription))"
        }
    }
}

// MARK: - CGDisplayStream dlsym types

// CGDisplayStream C functions are deprecated in macOS 15 SDK but still exist at
// runtime. We load them via dlsym to avoid compile-time deprecation errors.
private typealias CGDisplayStreamCreateFn = @convention(c) (
    UInt32, Int, Int, Int32, CFDictionary?, DispatchQueue,
    @escaping @convention(block) (Int32, UInt64, IOSurfaceRef?, OpaquePointer?) -> Void
) -> OpaquePointer?
private typealias CGDisplayStreamStartFn = @convention(c) (OpaquePointer) -> Int32
private typealias CGDisplayStreamStopFn = @convention(c) (OpaquePointer) -> Int32

func adaptiveBackpressureThreshold(rttMs: Double) -> Int {
    max(2, min(6, Int(120.0 / max(rttMs, 1.0))))
}

let TRIVIAL_DELTA_THRESHOLD = 512

// MARK: - Screen Capture

class ScreenCapture: NSObject {
    let tcpServer: TCPServer
    let wsServer: WebSocketServer
    let ciContext: CIContext
    let targetDisplayID: CGDirectDisplayID

    // CGDisplayStream runtime handles
    private var cgHandle: UnsafeMutableRawPointer?       // dlopen handle
    private var displayStream: OpaquePointer?            // retained stream ref

    var useColor: Bool = false
    var bytesPerPixel: Int { useColor ? 3 : 1 }

    var currentRGB: UnsafeMutablePointer<UInt8>?
    var previousRGB: UnsafeMutablePointer<UInt8>?
    var deltaBuffer: UnsafeMutablePointer<UInt8>?
    var compressedBuffer: UnsafeMutablePointer<CChar>?
    var frameWidth: Int = 0
    var frameHeight: Int = 0
    var pixelCount: Int = 0
    var bufferSize: Int = 0  // pixelCount * bytesPerPixel

    var frameCount: Int = 0
    var frameSequence: UInt32 = 0
    var skippedFrames: Int = 0
    var forceNextKeyframe: Bool = false
    var lastStatTime: Date = Date()
    var convertTimeSum: Double = 0
    var compressTimeSum: Double = 0
    var statFrames: Int = 0
    var lastCompressedSize: Int = 0

    // VFR idle detection — tile detection handles this (0 dirty tiles = skip frame)
    var consecutiveIdleFrames: Int = 0

    // Jitter tracking: measures interval variance between callbacks
    var lastCallbackTime: Double = 0
    var jitterSamples: [Double] = []
    let jitterWindowSize = 150

    /// Callback: (fps, bandwidthMB, frameSizeKB, totalFrames, rgbMs, compressMs, jitterMs, skipped)
    var onStats: ((Double, Double, Int, Int, Double, Double, Double, Int) -> Void)?

    let expectedWidth: Int
    let expectedHeight: Int

    init(tcpServer: TCPServer, wsServer: WebSocketServer, targetDisplayID: CGDirectDisplayID, width: Int, height: Int, useColor: Bool = false) {
        self.tcpServer = tcpServer
        self.wsServer = wsServer
        self.targetDisplayID = targetDisplayID
        self.expectedWidth = width
        self.expectedHeight = height
        self.useColor = useColor
        self.ciContext = CIContext(options: [.useSoftwareRenderer: false])
        super.init()
    }

    func start() async throws {
        // Pre-check screen recording permission
        guard CGPreflightScreenCaptureAccess() else {
            throw ScreenCaptureError.permissionDenied
        }

        frameWidth = expectedWidth
        frameHeight = expectedHeight
        pixelCount = frameWidth * frameHeight
        bufferSize = pixelCount * bytesPerPixel

        currentRGB = .allocate(capacity: bufferSize)
        previousRGB = .allocate(capacity: bufferSize)
        deltaBuffer = .allocate(capacity: bufferSize)
        let maxCompressed = LZ4_compressBound(Int32(bufferSize))
        compressedBuffer = .allocate(capacity: Int(maxCompressed))
        previousRGB!.initialize(repeating: 0, count: bufferSize)

        print("Capturing display: \(expectedWidth)x\(expectedHeight) pixels (ID: \(targetDisplayID)) [\(useColor ? "color" : "greyscale")]")

        // Load CGDisplayStream functions via dlsym
        guard let cg = dlopen("/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics", RTLD_LAZY) else {
            throw ScreenCaptureError.contentEnumerationFailed(
                NSError(domain: "ScreenCapture", code: -1,
                        userInfo: [NSLocalizedDescriptionKey: "Failed to dlopen CoreGraphics"]))
        }
        cgHandle = cg

        guard let createSym = dlsym(cg, "CGDisplayStreamCreateWithDispatchQueue"),
              let startSym = dlsym(cg, "CGDisplayStreamStart"),
              let stopSym = dlsym(cg, "CGDisplayStreamStop") else {
            throw ScreenCaptureError.contentEnumerationFailed(
                NSError(domain: "ScreenCapture", code: -2,
                        userInfo: [NSLocalizedDescriptionKey: "Failed to resolve CGDisplayStream symbols"]))
        }
        // Suppress unused variable warning — stopSym is resolved here to fail fast,
        // but the actual stop function is loaded again in stop() for lifetime safety.
        _ = stopSym

        let createFn = unsafeBitCast(createSym, to: CGDisplayStreamCreateFn.self)
        let startFn = unsafeBitCast(startSym, to: CGDisplayStreamStartFn.self)

        // CGDisplayStream configuration
        let properties: NSDictionary = [
            "kCGDisplayStreamMinimumFrameTime": NSNumber(value: 1.0 / Double(TARGET_FPS)),
            "kCGDisplayStreamShowCursor": kCFBooleanTrue as Any
        ]

        let captureQueue = DispatchQueue(label: "capture", qos: .userInteractive)
        let pixelFormat: Int32 = 1111970369  // kCVPixelFormatType_32BGRA (0x42475241)

        // Create the display stream
        guard let stream = createFn(
            targetDisplayID,
            frameWidth,
            frameHeight,
            pixelFormat,
            properties as CFDictionary,
            captureQueue,
            { [weak self] (status: Int32, _: UInt64, surface: IOSurfaceRef?, _: OpaquePointer?) in
                self?.handleFrame(status: status, surface: surface)
            }
        ) else {
            throw ScreenCaptureError.contentEnumerationFailed(
                NSError(domain: "ScreenCapture", code: -3,
                        userInfo: [NSLocalizedDescriptionKey: "CGDisplayStreamCreateWithDispatchQueue returned nil"]))
        }

        // Retain the stream reference — without this it gets deallocated
        displayStream = stream
        let cfStream = Unmanaged<CFTypeRef>.fromOpaque(UnsafeRawPointer(stream))
        _ = cfStream.retain()

        // Start capture
        let result = startFn(stream)
        guard result == 0 else {
            throw ScreenCaptureError.contentEnumerationFailed(
                NSError(domain: "ScreenCapture", code: Int(result),
                        userInfo: [NSLocalizedDescriptionKey: "CGDisplayStreamStart failed with code \(result)"]))
        }

        lastStatTime = Date()
        let modeName = useColor ? "RGB" : "greyscale"
        print("Capture started at \(TARGET_FPS)fps -- CGDisplayStream + \(modeName) + LZ4 delta (zero GPU)")
    }

    /// Switch between greyscale and color mode. Reallocates buffers and forces a keyframe.
    func setColorMode(_ color: Bool) {
        useColor = color
        let newSize = pixelCount * bytesPerPixel
        bufferSize = newSize

        currentRGB?.deallocate()
        previousRGB?.deallocate()
        deltaBuffer?.deallocate()
        compressedBuffer?.deallocate()

        currentRGB = .allocate(capacity: bufferSize)
        previousRGB = .allocate(capacity: bufferSize)
        deltaBuffer = .allocate(capacity: bufferSize)
        let maxCompressed = LZ4_compressBound(Int32(bufferSize))
        compressedBuffer = .allocate(capacity: Int(maxCompressed))
        previousRGB!.initialize(repeating: 0, count: bufferSize)
        forceNextKeyframe = true
        consecutiveIdleFrames = 0
        print("[Capture] Switched to \(color ? "color" : "greyscale") mode (\(bytesPerPixel) bytes/pixel)")
    }

    func stop() async {
        if let stream = displayStream {
            // Load stop function
            if let cg = cgHandle, let stopSym = dlsym(cg, "CGDisplayStreamStop") {
                let stopFn = unsafeBitCast(stopSym, to: CGDisplayStreamStopFn.self)
                _ = stopFn(stream)
            }
            // Release the retained CFTypeRef
            let cfStream = Unmanaged<CFTypeRef>.fromOpaque(UnsafeRawPointer(stream))
            cfStream.release()
            displayStream = nil
        }
        if let cg = cgHandle {
            dlclose(cg)
            cgHandle = nil
        }
        currentRGB?.deallocate(); currentRGB = nil
        previousRGB?.deallocate(); previousRGB = nil
        deltaBuffer?.deallocate(); deltaBuffer = nil
        compressedBuffer?.deallocate(); compressedBuffer = nil
    }

    // MARK: - Frame callback

    private func handleFrame(status: Int32, surface: IOSurfaceRef?) {
        // Status codes:
        // 0 = FrameComplete, 1 = FrameIdle, 2 = FrameBlank, 3 = Stopped
        guard status == 0, let surface = surface else { return }

        // Guard against race: stop() deallocates buffers while callback is in-flight.
        // Capture local copies so stop() can't nil them out mid-frame.
        guard let curBuf = currentRGB, let prevBuf = previousRGB,
              let deltaBuf = deltaBuffer, let compBuf = compressedBuffer else { return }
        // Local copies protect against stop() nilling ivars mid-frame.
        // From here on, use curBuf/prevBuf/deltaBuf/compBuf — never force-unwrap the ivars.

        let t0 = CACurrentMediaTime()

        if lastCallbackTime > 0 {
            let interval = (t0 - lastCallbackTime) * 1000.0
            let expectedInterval = 1000.0 / Double(TARGET_FPS)
            let jitter = abs(interval - expectedInterval)
            jitterSamples.append(jitter)
            if jitterSamples.count > jitterWindowSize {
                jitterSamples.removeFirst(jitterSamples.count - jitterWindowSize)
            }
        }
        lastCallbackTime = t0

        IOSurfaceLock(surface, .readOnly, nil)
        let baseAddress = IOSurfaceGetBaseAddress(surface)
        let rowBytes = IOSurfaceGetBytesPerRow(surface)

        // vImage SIMD conversion: BGRA → greyscale or RGB
        let src = baseAddress.assumingMemoryBound(to: UInt8.self)
        var srcBuf = vImage_Buffer(data: src, height: vImagePixelCount(frameHeight),
                                   width: vImagePixelCount(frameWidth), rowBytes: rowBytes)

        if useColor {
            // Color: BGRA → RGB via vImageConvert_BGRA8888toRGB888
            var dstBuf = vImage_Buffer(data: curBuf, height: vImagePixelCount(frameHeight),
                                       width: vImagePixelCount(frameWidth), rowBytes: frameWidth * 3)
            vImageConvert_BGRA8888toRGB888(&srcBuf, &dstBuf, vImage_Flags(kvImageNoFlags))
        } else {
            // Greyscale: BGRA → Planar8 via matrix multiply (BT.601 luma)
            // BGRA channel order: weights are [B, G, R, A]
            var dstBuf = vImage_Buffer(data: curBuf, height: vImagePixelCount(frameHeight),
                                       width: vImagePixelCount(frameWidth), rowBytes: frameWidth)
            var matrix: [Int16] = [114, 587, 299, 0]  // BT.601: B=114, G=587, R=299
            vImageMatrixMultiply_ARGB8888ToPlanar8(
                &srcBuf, &dstBuf, &matrix, 1000,
                nil, 0, vImage_Flags(kvImageNoFlags))
        }

        let t1 = CACurrentMediaTime()

        // Drop frames when Android can't keep up — send only the latest
        let inflight = tcpServer.inflightFrames
        let isScheduledKeyframe = (frameCount % KEYFRAME_INTERVAL == 0)

        let rtt = tcpServer.latencyStats?.rttAvgMs ?? 15.0
        let adaptiveThreshold = adaptiveBackpressureThreshold(rttMs: rtt)
        if inflight > adaptiveThreshold && !isScheduledKeyframe {
            skippedFrames += 1
            forceNextKeyframe = true
            // Still swap buffers so curBuf stays fresh for next delta base
            previousRGB = curBuf
            currentRGB = prevBuf

            IOSurfaceUnlock(surface, .readOnly, nil)
            frameCount += 1
            return
        }

        let isKeyframe = isScheduledKeyframe || forceNextKeyframe
        if forceNextKeyframe { forceNextKeyframe = false }
        let seq = frameSequence
        frameSequence &+= 1

        if isKeyframe {
            consecutiveIdleFrames = 0
            let compressedSize = LZ4_compress_default(
                curBuf, compBuf, Int32(bufferSize),
                LZ4_compressBound(Int32(bufferSize))
            )
            let payload = Data(bytes: compBuf, count: Int(compressedSize))
            tcpServer.broadcast(payload: payload, isKeyframe: true, sequenceNumber: seq)
            lastCompressedSize = Int(compressedSize)
        } else {
            // Tile-based dirty detection: compare tiles, send only changed ones
            let bpp = bytesPerPixel
            let tileCols = (frameWidth + TILE_SIZE - 1) / TILE_SIZE
            let tileRows = (frameHeight + TILE_SIZE - 1) / TILE_SIZE
            let tileCount = tileCols * tileRows
            let bitmapBytes = (tileCount + 7) / 8

            // Build dirty bitmap — compare each tile row-by-row with memcmp
            var dirtyBitmap = [UInt8](repeating: 0, count: bitmapBytes)
            var dirtyCount = 0

            for ty in 0..<tileRows {
                let tileH = min(TILE_SIZE, frameHeight - ty * TILE_SIZE)
                for tx in 0..<tileCols {
                    let tileW = min(TILE_SIZE, frameWidth - tx * TILE_SIZE)
                    let tileIdx = ty * tileCols + tx
                    var isDirty = false

                    for row in 0..<tileH {
                        let y = ty * TILE_SIZE + row
                        let offset = (y * frameWidth + tx * TILE_SIZE) * bpp
                        let rowLen = tileW * bpp
                        if memcmp(curBuf + offset, prevBuf + offset, rowLen) != 0 {
                            isDirty = true
                            break
                        }
                    }
                    if isDirty {
                        dirtyBitmap[tileIdx / 8] |= UInt8(1 << (tileIdx % 8))
                        dirtyCount += 1
                    }
                }
            }

            if dirtyCount == 0 {
                // No change — skip frame entirely
                skippedFrames += 1
                frameSequence &-= 1
                consecutiveIdleFrames += 1
            } else if dirtyCount > tileCount / 2 {
                // >50% dirty — full-frame XOR delta (existing path)
                consecutiveIdleFrames = 0
                var i = 0
                while i + 16 <= bufferSize {
                    let cur = UnsafeRawPointer(curBuf + i).loadUnaligned(as: SIMD16<UInt8>.self)
                    let prev = UnsafeRawPointer(prevBuf + i).loadUnaligned(as: SIMD16<UInt8>.self)
                    let xor = cur ^ prev
                    UnsafeMutableRawPointer(deltaBuf + i).storeBytes(of: xor, as: SIMD16<UInt8>.self)
                    i += 16
                }
                while i < bufferSize {
                    deltaBuf[i] = curBuf[i] ^ prevBuf[i]
                    i += 1
                }
                let compressedSize = LZ4_compress_default(
                    deltaBuf, compBuf, Int32(bufferSize),
                    LZ4_compressBound(Int32(bufferSize))
                )
                if compressedSize < TRIVIAL_DELTA_THRESHOLD {
                    skippedFrames += 1
                    frameSequence &-= 1
                } else {
                    let payload = Data(bytes: compBuf, count: Int(compressedSize))
                    tcpServer.broadcast(payload: payload, isKeyframe: false, sequenceNumber: seq)
                }
                lastCompressedSize = Int(compressedSize)
            } else {
                // Tiled frame: XOR + LZ4 compress only dirty tiles
                consecutiveIdleFrames = 0
                var tiledPayload = Data()
                // Header: [tile_cols:2LE] [tile_rows:2LE] [bitmap]
                var cols16 = UInt16(tileCols).littleEndian
                var rows16 = UInt16(tileRows).littleEndian
                tiledPayload.append(Data(bytes: &cols16, count: 2))
                tiledPayload.append(Data(bytes: &rows16, count: 2))
                tiledPayload.append(contentsOf: dirtyBitmap)

                let tilePixelSize = TILE_SIZE * TILE_SIZE * bpp
                let tileMaxCompressed = LZ4_compressBound(Int32(tilePixelSize))
                let tileDelta = UnsafeMutablePointer<UInt8>.allocate(capacity: tilePixelSize)
                let tileCompressed = UnsafeMutablePointer<CChar>.allocate(capacity: Int(tileMaxCompressed))

                for ty in 0..<tileRows {
                    let tileH = min(TILE_SIZE, frameHeight - ty * TILE_SIZE)
                    for tx in 0..<tileCols {
                        let tileIdx = ty * tileCols + tx
                        guard dirtyBitmap[tileIdx / 8] & UInt8(1 << (tileIdx % 8)) != 0 else { continue }

                        let tileW = min(TILE_SIZE, frameWidth - tx * TILE_SIZE)
                        var deltaOffset = 0

                        for row in 0..<tileH {
                            let y = ty * TILE_SIZE + row
                            let srcOffset = (y * frameWidth + tx * TILE_SIZE) * bpp
                            let rowLen = tileW * bpp
                            // XOR this tile row
                            var j = 0
                            while j + 16 <= rowLen {
                                let cur = UnsafeRawPointer(curBuf + srcOffset + j).loadUnaligned(as: SIMD16<UInt8>.self)
                                let prev = UnsafeRawPointer(prevBuf + srcOffset + j).loadUnaligned(as: SIMD16<UInt8>.self)
                                UnsafeMutableRawPointer(tileDelta + deltaOffset + j).storeBytes(of: cur ^ prev, as: SIMD16<UInt8>.self)
                                j += 16
                            }
                            while j < rowLen {
                                tileDelta[deltaOffset + j] = curBuf[srcOffset + j] ^ prevBuf[srcOffset + j]
                                j += 1
                            }
                            deltaOffset += rowLen
                        }

                        let compSize = LZ4_compress_default(
                            tileDelta, tileCompressed, Int32(deltaOffset),
                            tileMaxCompressed
                        )
                        var compLen = UInt32(compSize).littleEndian
                        tiledPayload.append(Data(bytes: &compLen, count: 4))
                        tiledPayload.append(Data(bytes: tileCompressed, count: Int(compSize)))
                    }
                }

                tileDelta.deallocate()
                tileCompressed.deallocate()

                tcpServer.broadcast(payload: tiledPayload, isKeyframe: false,
                                    sequenceNumber: seq, flags: FLAG_TILED)
                lastCompressedSize = tiledPayload.count
            }
        }

        previousRGB = curBuf
        currentRGB = prevBuf

        let t2 = CACurrentMediaTime()

        if wsServer.hasClients {
            let ciImage = CIImage(ioSurface: unsafeBitCast(surface, to: IOSurface.self))
            if let jpegData = ciContext.jpegRepresentation(
                of: ciImage,
                colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
                options: [kCGImageDestinationLossyCompressionQuality as CIImageRepresentationOption: JPEG_QUALITY]
            ) {
                wsServer.broadcast(jpegData)
            }
        }

        IOSurfaceUnlock(surface, .readOnly, nil)

        frameCount += 1
        statFrames += 1
        convertTimeSum += (t1 - t0) * 1000
        compressTimeSum += (t2 - t1) * 1000

        let now = Date()
        if now.timeIntervalSince(lastStatTime) >= 5.0 {
            let fps = Double(statFrames) / now.timeIntervalSince(lastStatTime)
            let avgConvert = statFrames > 0 ? convertTimeSum / Double(statFrames) : 0
            let avgCompress = statFrames > 0 ? compressTimeSum / Double(statFrames) : 0
            let bw = Double(lastCompressedSize) * fps / 1024 / 1024
            let avgJitter = jitterSamples.isEmpty ? 0.0 : jitterSamples.reduce(0, +) / Double(jitterSamples.count)

            let modeLabel = useColor ? "rgb" : "grey"
            print(String(format: "FPS: %.1f | %@: %.1fms | lz4+delta: %.1fms | jitter: %.1fms | frame: %dKB | ~%.1fMB/s | total: %d | skipped: %d",
                         fps, modeLabel, avgConvert, avgCompress, avgJitter, lastCompressedSize / 1024, bw, frameCount, skippedFrames))
            onStats?(fps, bw, lastCompressedSize / 1024, frameCount, avgConvert, avgCompress, avgJitter, skippedFrames)

            statFrames = 0
            convertTimeSum = 0
            compressTimeSum = 0
            lastStatTime = now
        }
    }
}
