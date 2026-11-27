// ScreenCapture.swift — CPU-only screen capture with vImage SIMD + LZ4 delta.
//
// Captures the virtual display via CGDisplayStream (loaded at runtime via dlsym
// to bypass macOS 15 SDK deprecation), converts BGRA to greyscale (1 B/px) or RGB
// (3 B/px, for color e-ink) using vImage SIMD, optionally sharpens with a Laplacian
// convolution, applies a gamma+contrast LUT, then sends either an LZ4 keyframe or
// a lossless delta. Deltas are tiled: only 64x64 tiles that changed are XORed and
// compressed, so typing a character costs a few hundred bytes. Zero GPU usage.

import Foundation
import Darwin
import IOSurface
import CoreImage
import QuartzCore
import Accelerate
import CLZ4

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
    let wsServer: WebSocketServer?
    let ciContext: CIContext
    let targetDisplayID: CGDirectDisplayID

    // CGDisplayStream runtime handles
    private var cgHandle: UnsafeMutableRawPointer?       // dlopen handle
    private(set) var displayStream: OpaquePointer?         // retained stream ref

    /// Converted frame (greyscale or RGB) and the frame the client currently shows.
    /// Invariant: `previousGray` always equals the client's buffer after a send.
    var currentGray: UnsafeMutablePointer<UInt8>?
    var previousGray: UnsafeMutablePointer<UInt8>?
    var deltaBuffer: UnsafeMutablePointer<UInt8>?
    var compressedBuffer: UnsafeMutablePointer<CChar>?
    var compressedCapacity: Int = 0
    var sharpenTemp: UnsafeMutablePointer<UInt8>?  // Pre-sharpen buffer (grey: 1 B/px, color: BGRA 4 B/px)
    var tileDelta: UnsafeMutablePointer<UInt8>?    // Scratch for one tile's XOR delta
    var dirtyBitmap: [UInt8] = []

    /// RGB (3 B/px) instead of greyscale. Fixed for the stream's lifetime.
    let useColor: Bool
    var bytesPerPixel: Int { useColor ? 3 : 1 }
    var bufferSize: Int = 0
    /// Capture rate for this stream (the DC-1 runs at 60, e-ink panels at 30).
    let targetFPS: Int
    /// Frames between scheduled keyframes. Tiled deltas are lossless, so keyframes are
    /// only a safety net (and the base for clients that join mid-stream).
    var keyframeInterval: Int { targetFPS * 3 }
    var contrastLUT: [UInt8] = Array(0...255)       // Combined gamma+contrast LUT
    var lastContrastAmount: Double = 1.0           // Tracks when to rebuild LUT
    var lastGammaAmount: Double = 1.0              // Tracks when to rebuild LUT
    var sharpenAmount: Double = 1.0                // 0=none, 1=mild, 2=strong, 3=max
    var contrastAmount: Double = 1.0               // 1.0=off, >1=enhanced
    var gammaAmount: Double = 1.2                  // Gamma correction for reflective displays
    /// Atomic flag to prevent handleFrame() from accessing deallocated buffers during stop().
    /// Set before CGDisplayStreamStop, checked at top of handleFrame().
    private var isStopped: Bool = false
    private let stoppedLock = NSLock()
    var frameWidth: Int = 0
    var frameHeight: Int = 0
    var pixelCount: Int = 0

    var frameCount: Int = 0
    var frameSequence: UInt32 = 0
    var skippedFrames: Int = 0
    var forceNextKeyframe: Bool = false
    var lastStatTime: Date = Date()
    var convertTimeSum: Double = 0
    var compressTimeSum: Double = 0
    var statFrames: Int = 0
    var sentStatFrames: Int = 0   // frames actually sent (idle callbacks excluded)
    var tiledFrames: Int = 0
    var lastCompressedSize: Int = 0

    // Jitter tracking: measures interval variance between callbacks
    var lastCallbackTime: Double = 0
    var jitterSamples: [Double] = []
    let jitterWindowSize = 150

    /// Callback: (fps, bandwidthMB, frameSizeKB, totalFrames, greyMs, compressMs, jitterMs)
    var onStats: ((Double, Double, Int, Int, Double, Double, Double, Int) -> Void)?

    let expectedWidth: Int
    let expectedHeight: Int

    init(tcpServer: TCPServer, wsServer: WebSocketServer?, targetDisplayID: CGDirectDisplayID,
         width: Int, height: Int, useColor: Bool = false, targetFPS: Int = TARGET_FPS) {
        self.tcpServer = tcpServer
        self.wsServer = wsServer
        self.targetDisplayID = targetDisplayID
        self.expectedWidth = width
        self.expectedHeight = height
        self.useColor = useColor
        self.targetFPS = targetFPS
        self.ciContext = CIContext(options: [.useSoftwareRenderer: false])
        super.init()
    }

    func start() async throws {
        isStopped = false

        // Pre-check screen recording permission
        guard CGPreflightScreenCaptureAccess() else {
            throw ScreenCaptureError.permissionDenied
        }

        frameWidth = expectedWidth
        frameHeight = expectedHeight
        pixelCount = frameWidth * frameHeight
        bufferSize = pixelCount * bytesPerPixel

        currentGray = .allocate(capacity: bufferSize)
        previousGray = .allocate(capacity: bufferSize)
        deltaBuffer = .allocate(capacity: bufferSize)
        sharpenTemp = .allocate(capacity: pixelCount * (useColor ? 4 : 1))
        tileDelta = .allocate(capacity: TILE_SIZE * TILE_SIZE * bytesPerPixel)
        let tileCount = tileCols * tileRows
        dirtyBitmap = [UInt8](repeating: 0, count: (tileCount + 7) / 8)
        // Room for a full-frame LZ4 block, or a tiled payload (header + bitmap +
        // per-tile length prefix + per-tile LZ4 slack).
        compressedCapacity = Int(LZ4_compressBound(Int32(bufferSize))) + tileCount * 24 + dirtyBitmap.count + 64
        compressedBuffer = .allocate(capacity: compressedCapacity)
        previousGray!.initialize(repeating: 0, count: bufferSize)

        print("Capturing display: \(expectedWidth)x\(expectedHeight) pixels (ID: \(targetDisplayID)) [\(useColor ? "RGB" : "greyscale"), \(targetFPS)fps]")

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
            "kCGDisplayStreamMinimumFrameTime": NSNumber(value: 1.0 / Double(targetFPS)),
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
        print("Capture started at \(targetFPS)fps -- CGDisplayStream + vImage + tiled LZ4 delta (zero GPU)")
    }

    func stop() async {
        // Set stopped flag BEFORE stopping the stream — prevents in-flight
        // handleFrame() callbacks from accessing buffers we're about to deallocate.
        stoppedLock.lock()
        isStopped = true
        stoppedLock.unlock()

        stopStream()
        // Let any in-flight callbacks on captureQueue drain before releasing
        try? await Task.sleep(for: .milliseconds(100))
        releaseStream()

        if let cg = cgHandle {
            dlclose(cg)
            cgHandle = nil
        }
        currentGray?.deallocate(); currentGray = nil
        previousGray?.deallocate(); previousGray = nil
        deltaBuffer?.deallocate(); deltaBuffer = nil
        sharpenTemp?.deallocate(); sharpenTemp = nil
        tileDelta?.deallocate(); tileDelta = nil
        compressedBuffer?.deallocate(); compressedBuffer = nil
    }

    var tileCols: Int { (frameWidth + TILE_SIZE - 1) / TILE_SIZE }
    var tileRows: Int { (frameHeight + TILE_SIZE - 1) / TILE_SIZE }

    /// Stop the CGDisplayStream without releasing buffers.
    private func stopStream() {
        guard let stream = displayStream else { return }
        if let cg = cgHandle, let stopSym = dlsym(cg, "CGDisplayStreamStop") {
            let stopFn = unsafeBitCast(stopSym, to: CGDisplayStreamStopFn.self)
            _ = stopFn(stream)
        }
    }

    /// Release the retained CGDisplayStream CFTypeRef.
    private func releaseStream() {
        guard let stream = displayStream else { return }
        let cfStream = Unmanaged<CFTypeRef>.fromOpaque(UnsafeRawPointer(stream))
        cfStream.release()
        displayStream = nil
    }

    /// Restart the CGDisplayStream after a display sleep/wake cycle (clamshell mode).
    /// Tears down the old stream and creates a new one targeting the same display,
    /// keeping all buffers and state intact. Forces a keyframe on the next frame.
    func restartStream() async {
        NSLog("[Capture] Restarting CGDisplayStream for display %d...", targetDisplayID)

        // Stop old stream
        stoppedLock.lock()
        isStopped = true
        stoppedLock.unlock()

        stopStream()
        try? await Task.sleep(for: .milliseconds(200))
        releaseStream()

        // Reset frame state for clean restart
        stoppedLock.lock()
        isStopped = false
        stoppedLock.unlock()
        forceNextKeyframe = true
        frameCount = 0
        lastCallbackTime = 0

        // Re-create stream using existing cgHandle (CoreGraphics dylib)
        guard let cg = cgHandle else {
            // Re-open CoreGraphics if handle was lost
            guard let newCg = dlopen("/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics", RTLD_LAZY) else {
                NSLog("[Capture] FATAL: Failed to dlopen CoreGraphics on restart")
                return
            }
            cgHandle = newCg
            return await restartStream()  // retry with new handle
        }

        guard let createSym = dlsym(cg, "CGDisplayStreamCreateWithDispatchQueue"),
              let startSym = dlsym(cg, "CGDisplayStreamStart") else {
            NSLog("[Capture] FATAL: Failed to resolve CGDisplayStream symbols on restart")
            return
        }

        let createFn = unsafeBitCast(createSym, to: CGDisplayStreamCreateFn.self)
        let startFn = unsafeBitCast(startSym, to: CGDisplayStreamStartFn.self)

        let properties: NSDictionary = [
            "kCGDisplayStreamMinimumFrameTime": NSNumber(value: 1.0 / Double(targetFPS)),
            "kCGDisplayStreamShowCursor": kCFBooleanTrue as Any
        ]

        let captureQueue = DispatchQueue(label: "capture", qos: .userInteractive)
        let pixelFormat: Int32 = 1111970369  // kCVPixelFormatType_32BGRA

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
            NSLog("[Capture] Failed to create new CGDisplayStream — display %d may be unavailable", targetDisplayID)
            return
        }

        displayStream = stream
        let cfStream = Unmanaged<CFTypeRef>.fromOpaque(UnsafeRawPointer(stream))
        _ = cfStream.retain()

        let result = startFn(stream)
        if result == 0 {
            NSLog("[Capture] CGDisplayStream restarted successfully for display %d", targetDisplayID)
        } else {
            NSLog("[Capture] CGDisplayStreamStart failed on restart with code %d", result)
        }
    }

    // MARK: - Frame callback

    private func handleFrame(status: Int32, surface: IOSurfaceRef?) {
        // Status codes:
        // 0 = FrameComplete, 1 = FrameIdle, 2 = FrameBlank, 3 = Stopped
        guard status == 0, let surface = surface else { return }

        // Check stopped flag to avoid accessing deallocated buffers (#49)
        stoppedLock.lock()
        let shouldStop = isStopped
        stoppedLock.unlock()
        guard !shouldStop else { return }

        let t0 = CACurrentMediaTime()

        if lastCallbackTime > 0 {
            let interval = (t0 - lastCallbackTime) * 1000.0
            let expectedInterval = 1000.0 / Double(targetFPS)
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

        // Log actual IOSurface dimensions on first frame to verify CGDisplayStream
        // is delivering full backing pixel resolution (critical for HiDPI modes).
        if frameCount == 0 {
            let surfW = IOSurfaceGetWidth(surface)
            let surfH = IOSurfaceGetHeight(surface)
            let surfBPP = IOSurfaceGetBytesPerElement(surface)
            NSLog("[Capture] IOSurface: %dx%d, %d bpp, rowBytes=%d (expected %dx%d)",
                  surfW, surfH, surfBPP, rowBytes, frameWidth, frameHeight)
        }

        guard let cur = currentGray, let prev = previousGray, let comp = compressedBuffer else {
            IOSurfaceUnlock(surface, .readOnly, nil)
            return
        }

        var srcBuffer = vImage_Buffer(
            data: baseAddress,
            height: vImagePixelCount(frameHeight),
            width: vImagePixelCount(frameWidth),
            rowBytes: rowBytes
        )
        let sharpAmt = sharpenAmount
        let a = Int16(sharpAmt * 4)  // Laplacian weight, divisor 4 → 0.25 steps
        let center = 4 + 4 * a       // (1 + 4*amount) * divisor
        var kernel: [Int16] = [0, -a, 0, -a, center, -a, 0, -a, 0]

        if useColor {
            // BGRA → (optional sharpen in BGRA) → RGB888
            var rgbBuffer = vImage_Buffer(
                data: cur, height: vImagePixelCount(frameHeight),
                width: vImagePixelCount(frameWidth), rowBytes: frameWidth * 3
            )
            if sharpAmt > 0.01, let tmp = sharpenTemp {
                var sharpBuffer = vImage_Buffer(
                    data: tmp, height: vImagePixelCount(frameHeight),
                    width: vImagePixelCount(frameWidth), rowBytes: frameWidth * 4
                )
                vImageConvolve_ARGB8888(
                    &srcBuffer, &sharpBuffer, nil, 0, 0, &kernel, 3, 3, 4, nil,
                    vImage_Flags(kvImageEdgeExtend)
                )
                vImageConvert_BGRA8888toRGB888(&sharpBuffer, &rgbBuffer, vImage_Flags(kvImageNoFlags))
            } else {
                vImageConvert_BGRA8888toRGB888(&srcBuffer, &rgbBuffer, vImage_Flags(kvImageNoFlags))
            }
        } else {
            var matrix: [Int16] = [29, 150, 77, 0]  // BGRA → luma (BT.601), divisor 256
            var preBias: [Int16] = [0, 0, 0, 0]
            var dstBuffer = vImage_Buffer(
                data: cur, height: vImagePixelCount(frameHeight),
                width: vImagePixelCount(frameWidth), rowBytes: frameWidth
            )
            if sharpAmt > 0.01, let tmp = sharpenTemp {
                var preSharpenBuffer = vImage_Buffer(
                    data: tmp, height: vImagePixelCount(frameHeight),
                    width: vImagePixelCount(frameWidth), rowBytes: frameWidth
                )
                vImageMatrixMultiply_ARGB8888ToPlanar8(
                    &srcBuffer, &preSharpenBuffer, &matrix, 256, &preBias, 0,
                    vImage_Flags(kvImageNoFlags)
                )
                vImageConvolve_Planar8(
                    &preSharpenBuffer, &dstBuffer, nil, 0, 0,
                    &kernel, 3, 3, 4, 0, vImage_Flags(kvImageEdgeExtend)
                )
            } else {
                vImageMatrixMultiply_ARGB8888ToPlanar8(
                    &srcBuffer, &dstBuffer, &matrix, 256, &preBias, 0,
                    vImage_Flags(kvImageNoFlags)
                )
            }
        }

        // Combined gamma + contrast via one LUT, applied to every byte (grey or R/G/B)
        // with vImage's SIMD table lookup. Gamma lifts midtones for reflective panels;
        // contrast pushes light borders darker and text blacker.
        let contrastAmt = contrastAmount
        let gammaAmt = gammaAmount
        if abs(contrastAmt - 1.0) > 0.01 || abs(gammaAmt - 1.0) > 0.01 {
            if contrastAmt != lastContrastAmount || gammaAmt != lastGammaAmount {
                contrastLUT = (0..<256).map { i in
                    var val = Double(i) / 255.0
                    if abs(gammaAmt - 1.0) > 0.01 { val = pow(val, 1.0 / gammaAmt) }
                    val *= 255.0
                    if abs(contrastAmt - 1.0) > 0.01 { val = 128.0 + contrastAmt * (val - 128.0) }
                    return UInt8(max(0, min(255, Int(val))))
                }
                lastContrastAmount = contrastAmt
                lastGammaAmount = gammaAmt
            }
            var lutBuffer = vImage_Buffer(
                data: cur, height: vImagePixelCount(frameHeight),
                width: vImagePixelCount(frameWidth * bytesPerPixel), rowBytes: frameWidth * bytesPerPixel
            )
            contrastLUT.withUnsafeBufferPointer { lut in
                _ = vImageTableLookUp_Planar8(&lutBuffer, &lutBuffer, lut.baseAddress!, vImage_Flags(kvImageNoFlags))
            }
        }

        let t1 = CACurrentMediaTime()

        if tcpServer.consumeKeyframeRequest() { forceNextKeyframe = true }

        // Drop frames when Android can't keep up — send only the latest
        let inflight = tcpServer.inflightFrames
        let isScheduledKeyframe = (frameCount % keyframeInterval == 0)

        let rtt = tcpServer.latencyStats?.rttAvgMs ?? 15.0
        let adaptiveThreshold = adaptiveBackpressureThreshold(rttMs: rtt)
        if inflight > adaptiveThreshold && !isScheduledKeyframe {
            skippedFrames += 1
            forceNextKeyframe = true  // the client's base is now unknown — resync
            IOSurfaceUnlock(surface, .readOnly, nil)
            frameCount += 1
            return
        }

        let isKeyframe = isScheduledKeyframe || forceNextKeyframe
        var sent = false

        if isKeyframe {
            forceNextKeyframe = false
            let compressedSize = LZ4_compress_default(
                cur, comp, Int32(bufferSize), Int32(compressedCapacity)
            )
            let payload = Data(bytes: comp, count: Int(compressedSize))
            tcpServer.broadcast(payload: payload, isKeyframe: true, sequenceNumber: frameSequence)
            lastCompressedSize = Int(compressedSize)
            sent = true
        } else {
            let (dirty, total) = markDirtyTiles(cur: cur, prev: prev)
            if dirty == 0 {
                skippedFrames += 1  // Nothing changed — the client already has this frame
            } else if dirty * 2 > total {
                // Mostly dirty (scrolling, video) — one whole-frame XOR delta compresses better
                xorDelta(cur, prev, into: deltaBuffer!, count: bufferSize)
                let compressedSize = LZ4_compress_default(
                    deltaBuffer!, comp, Int32(bufferSize), Int32(compressedCapacity)
                )
                let payload = Data(bytes: comp, count: Int(compressedSize))
                tcpServer.broadcast(payload: payload, isKeyframe: false, sequenceNumber: frameSequence)
                lastCompressedSize = Int(compressedSize)
                sent = true
            } else {
                let size = encodeTiledDelta(cur: cur, prev: prev, into: comp)
                let payload = Data(bytes: comp, count: size)
                tcpServer.broadcast(payload: payload, isKeyframe: false, sequenceNumber: frameSequence, tiled: true)
                lastCompressedSize = size
                tiledFrames += 1
                sent = true
            }
        }

        if sent {
            frameSequence &+= 1
            sentStatFrames += 1
            // The client now shows `cur` — it becomes the base for the next delta.
            previousGray = cur
            currentGray = prev
        }

        let t2 = CACurrentMediaTime()

        if wsServer?.hasClients == true {
            let ciImage = CIImage(ioSurface: unsafeBitCast(surface, to: IOSurface.self))
            let grayImage = useColor ? ciImage
                : ciImage.applyingFilter("CIColorControls", parameters: [kCIInputSaturationKey: 0.0])
            if let jpegData = ciContext.jpegRepresentation(
                of: grayImage,
                colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
                options: [kCGImageDestinationLossyCompressionQuality as CIImageRepresentationOption: JPEG_QUALITY]
            ) {
                wsServer?.broadcast(jpegData)
            }
        }

        IOSurfaceUnlock(surface, .readOnly, nil)

        frameCount += 1
        statFrames += 1
        convertTimeSum += (t1 - t0) * 1000
        compressTimeSum += (t2 - t1) * 1000

        let now = Date()
        if now.timeIntervalSince(lastStatTime) >= 5.0 {
            // FPS = frames actually delivered to the device (idle callbacks excluded)
            let fps = Double(sentStatFrames) / now.timeIntervalSince(lastStatTime)
            let avgConvert = statFrames > 0 ? convertTimeSum / Double(statFrames) : 0
            let avgCompress = statFrames > 0 ? compressTimeSum / Double(statFrames) : 0
            let bw = Double(lastCompressedSize) * fps / 1024 / 1024
            let avgJitter = jitterSamples.isEmpty ? 0.0 : jitterSamples.reduce(0, +) / Double(jitterSamples.count)

            print(String(format: "FPS: %.1f | %@: %.1fms | lz4+delta: %.1fms | jitter: %.1fms | frame: %dKB | ~%.1fMB/s | tiled: %d | total: %d | skipped: %d",
                         fps, useColor ? "rgb" : "grey", avgConvert, avgCompress, avgJitter,
                         lastCompressedSize / 1024, bw, tiledFrames, frameCount, skippedFrames))
            onStats?(fps, bw, lastCompressedSize / 1024, frameCount, avgConvert, avgCompress, avgJitter, skippedFrames)

            statFrames = 0
            sentStatFrames = 0
            tiledFrames = 0
            convertTimeSum = 0
            compressTimeSum = 0
            lastStatTime = now
        }
    }

    // MARK: - Delta encoding

    /// Compare `cur` and `prev` tile by tile (row memcmp, early exit) and fill
    /// `dirtyBitmap`. Returns (dirty tiles, total tiles).
    private func markDirtyTiles(cur: UnsafeMutablePointer<UInt8>, prev: UnsafeMutablePointer<UInt8>) -> (Int, Int) {
        let bpp = bytesPerPixel
        let cols = tileCols, rows = tileRows
        let stride = frameWidth * bpp
        for i in 0..<dirtyBitmap.count { dirtyBitmap[i] = 0 }
        var dirty = 0
        for ty in 0..<rows {
            let tileH = min(TILE_SIZE, frameHeight - ty * TILE_SIZE)
            for tx in 0..<cols {
                let rowLen = min(TILE_SIZE, frameWidth - tx * TILE_SIZE) * bpp
                var offset = ty * TILE_SIZE * stride + tx * TILE_SIZE * bpp
                for _ in 0..<tileH {
                    if memcmp(cur + offset, prev + offset, rowLen) != 0 {
                        let idx = ty * cols + tx
                        dirtyBitmap[idx >> 3] |= UInt8(1 << (idx & 7))
                        dirty += 1
                        break
                    }
                    offset += stride
                }
            }
        }
        return (dirty, cols * rows)
    }

    /// Tiled payload: [cols:2][rows:2][bitmap] then, per dirty tile in row-major order,
    /// [lz4_len:4][LZ4(XOR of the tile's rows, packed)]. Returns the payload size.
    private func encodeTiledDelta(cur: UnsafeMutablePointer<UInt8>, prev: UnsafeMutablePointer<UInt8>,
                                  into out: UnsafeMutablePointer<CChar>) -> Int {
        let bpp = bytesPerPixel
        let cols = tileCols, rows = tileRows
        let stride = frameWidth * bpp
        let raw = UnsafeMutableRawPointer(out)
        raw.storeBytes(of: UInt16(cols).littleEndian, toByteOffset: 0, as: UInt16.self)
        raw.storeBytes(of: UInt16(rows).littleEndian, toByteOffset: 2, as: UInt16.self)
        var pos = 4
        dirtyBitmap.withUnsafeBytes { bm in
            (raw + pos).copyMemory(from: bm.baseAddress!, byteCount: bm.count)
        }
        pos += dirtyBitmap.count

        guard let scratch = tileDelta else { return pos }
        for ty in 0..<rows {
            let tileH = min(TILE_SIZE, frameHeight - ty * TILE_SIZE)
            for tx in 0..<cols {
                let idx = ty * cols + tx
                guard dirtyBitmap[idx >> 3] & UInt8(1 << (idx & 7)) != 0 else { continue }
                let rowLen = min(TILE_SIZE, frameWidth - tx * TILE_SIZE) * bpp
                var src = ty * TILE_SIZE * stride + tx * TILE_SIZE * bpp
                var packed = 0
                for _ in 0..<tileH {
                    xorDelta(cur + src, prev + src, into: scratch + packed, count: rowLen)
                    packed += rowLen
                    src += stride
                }
                let n = LZ4_compress_default(
                    scratch, out + pos + 4, Int32(packed), Int32(compressedCapacity - pos - 4)
                )
                raw.storeBytes(of: UInt32(n).littleEndian, toByteOffset: pos, as: UInt32.self)
                pos += 4 + Int(n)
            }
        }
        return pos
    }

    /// out = a XOR b, 16 bytes at a time.
    @inline(__always)
    private func xorDelta(_ a: UnsafeMutablePointer<UInt8>, _ b: UnsafeMutablePointer<UInt8>,
                          into out: UnsafeMutablePointer<UInt8>, count: Int) {
        var i = 0
        while i + 16 <= count {
            let x = UnsafeRawPointer(a + i).loadUnaligned(as: SIMD16<UInt8>.self)
            let y = UnsafeRawPointer(b + i).loadUnaligned(as: SIMD16<UInt8>.self)
            UnsafeMutableRawPointer(out + i).storeBytes(of: x ^ y, as: SIMD16<UInt8>.self)
            i += 16
        }
        while i < count {
            out[i] = a[i] ^ b[i]
            i += 1
        }
    }
}
