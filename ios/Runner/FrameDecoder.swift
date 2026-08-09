import CoreImage
import CoreMedia
import CoreVideo
import ImageIO
import Metal
import UIKit
import VideoToolbox
import os

/// Decodes Nikon live-view JPEG frames to fully-realized bitmaps **off the main actor**.
///
/// `UIImage(data:)` only wraps the JPEG — the actual decode is deferred to draw time, which lands on
/// the main thread when `UIImageView`/Core Image first touches the image. `preparingForDisplay()`
/// forces that decode now (and preserves EXIF orientation/scale, unlike a raw `CGImageSource` path),
/// so the main thread only ever composites an already-decoded frame.
///
/// A single long-lived actor keeps the work off main without spawning a task per frame: the
/// streaming loop is already serial, so it simply `await`s each decode.
actor FrameDecoder {
    private let hardware = JPEGPixelBufferDecoder()
    private let superResolution = LiveFeedSuperResolution()
    private let noiseFilter = LiveFeedNoiseFilter()
    private lazy var ciContext = CIContext(options: [.cacheIntermediates: false])

    /// Clears any latched-off processor so a new live-view session starts fresh.
    ///
    /// This decoder outlives every session — one instance for the app — so a filter that turned
    /// itself off after one bad frame stayed off until the app was force-quit. A transient refusal
    /// is not a permanent verdict about the device.
    func resetProcessors() {
        noiseFilter.reset()
        LiveDenoiseSwitch.decoderReportsUnavailable = nil
    }

    /// Returns `jpeg` decoded into a display-ready `UIImage`, or `nil` if it isn't a readable image.
    /// The result is `sending` — freshly created and not retained here, so it transfers safely back
    /// to the caller's actor.
    func decode(_ jpeg: Data) -> sending UIImage? {
        if !DemoHarness.forcesCPUJPEGDecode, let image = hardwareDecoded(jpeg) { return image }
        return autoreleasepool { UIImage(data: jpeg)?.preparingForDisplay() }
    }

    /// The hardware path: VideoToolbox decodes the camera's motion JPEG straight to `420v`.
    ///
    /// This is what VideoToolbox is genuinely good at, and the camera's stream is exactly its
    /// case: `UIImage(data:)` runs an ImageIO decode on the CPU and expands the chroma-subsampled
    /// original to RGB, where the hardware decoder returns the planes the JPEG already carried.
    ///
    /// Falls back rather than fails — a frame this cannot decode goes back to ImageIO, so the
    /// worst case is the behaviour that shipped before it.
    private func hardwareDecoded(_ jpeg: Data) -> sending UIImage? {
        autoreleasepool {
            guard var buffer = hardware.decode(jpeg) else { return nil }
            if LiveDenoiseSwitch.decoderReadsEnabled,
                let filtered = noiseFilter.filter(
                    buffer, strength: LiveDenoiseSwitch.decoderReadsStrength)
            {
                buffer = filtered
            }
            let image = CIImage(cvPixelBuffer: buffer)
            guard let cgImage = ciContext.createCGImage(image, from: image.extent) else {
                return nil
            }
            return UIImage(cgImage: cgImage)
        }
    }

    /// The super-resolution path: hardware JPEG decode, model, then back to an image.
    ///
    /// Dormant again — by operator decision super resolution moved back to the renderer, AFTER
    /// the effects bake, so the assists keep measuring the true source frame
    /// (`MetalLiveView.Coordinator.encodeSuperResolution`). This path proved the feature worked
    /// (it was where the end-before-start fix first ran) and is kept as the shape a media-export
    /// pipeline would use.
    ///
    /// Deliberately ahead of the effects graph rather than behind it. The camera's motion JPEG is
    /// already `420v` inside, so decoding in hardware lands the model's own format with no colour
    /// conversion at all — the RGB round-trip the renderer-side attempts needed existed only
    /// because `UIImage(data:)` throws the subsampled original away.
    ///
    /// The consequence, which is real: peaking, false colour and zebra now measure an UPSCALED
    /// picture. Their gates were calibrated at source resolution and want re-checking on hardware.
    private func superResolved(_ jpeg: Data) -> sending UIImage? {
        autoreleasepool {
            guard let decoded = hardware.decode(jpeg),
                let upscaled = superResolution.upscale(decoded)
            else { return nil }
            let image = CIImage(cvPixelBuffer: upscaled)
            guard let cgImage = ciContext.createCGImage(image, from: image.extent) else {
                return nil
            }
            return UIImage(cgImage: cgImage)
        }
    }
}

/// A `CVPixelBuffer` format as the four characters it actually is — `875704438` is unreadable
/// in a report line and `420v` is the answer.
private func fourCCName(_ format: OSType) -> String {
    let bytes = [24, 16, 8, 0].map { UInt8((format >> $0) & 0xFF) }
    let text = String(decoding: bytes, as: UTF8.self)
    return text.allSatisfy { $0.isASCII && !$0.isNewline } ? text : String(format)
}

/// Decodes Nikon live-view JPEG frames to `420v` pixel buffers in hardware.
///
/// The camera's live view is motion JPEG, and `420v` — biplanar YCbCr 4:2:0, video range — is what
/// a JPEG already *is* internally. Decoding through VideoToolbox therefore lands the frame in the
/// exact format the super-resolution processor demands, with no colour conversion at any point:
/// the RGB round-trip that path used before existed only because `UIImage(data:)` throws the
/// chroma-subsampled original away and hands back RGB.
///
/// One session per (width, height). The dimensions come from the JPEG's own header via ImageIO,
/// which reads the SOF marker without decoding a pixel.
final class JPEGPixelBufferDecoder {
    private let log = Logger(subsystem: "OpenZCine", category: "LiveView")
    private var session: VTDecompressionSession?
    private var format: CMFormatDescription?
    private var size: (width: Int, height: Int)?
    /// Whether the session forces the preferred planar format. Starts true, and drops to native
    /// output after one refusal: the simulator's software JPEG decoder rejects forced `420v` for
    /// the camera's 4:2:2 stream, while macOS and device hardware convert it happily — the same
    /// frame, probed both ways. Native mode hands back whatever the decoder produces and lets the
    /// consumer adapt.
    private var forcesPreferredFormat = true
    /// What the last decode actually did — surfaced on the debug key, because a silent fallback
    /// here is invisible from the operator's chair and takes every hardware-path feature with it.
    private(set) var report = "idle"

    deinit {
        if let session {
            VTDecompressionSessionInvalidate(session)
        }
    }

    /// The pixel format every frame comes back in — the one the model wants.
    static let pixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange

    /// Reads a JPEG's dimensions from its header without decoding it.
    static func dimensions(of jpeg: Data) -> (width: Int, height: Int)? {
        guard let source = CGImageSourceCreateWithData(jpeg as CFData, nil),
            let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
            let width = properties[kCGImagePropertyPixelWidth] as? Int,
            let height = properties[kCGImagePropertyPixelHeight] as? Int,
            width > 0, height > 0
        else { return nil }
        return (width, height)
    }

    /// Decodes one frame, or nil if the data is not a JPEG this decoder can take.
    func decode(_ jpeg: Data) -> CVPixelBuffer? {
        guard let dimensions = Self.dimensions(of: jpeg) else {
            report = "not a JPEG"
            return nil
        }
        if let buffer = attempt(jpeg, dimensions: dimensions) { return buffer }
        // The stricter forced-format session refused this frame. Retry once in native mode and
        // stay there — per stream, not per frame, so a working mode is found exactly once.
        guard forcesPreferredFormat else { return nil }
        forcesPreferredFormat = false
        size = nil
        return attempt(jpeg, dimensions: dimensions)
    }

    private func attempt(_ jpeg: Data, dimensions: (width: Int, height: Int)) -> CVPixelBuffer? {
        guard prepare(for: dimensions), let session, let format else { return nil }

        var blockBuffer: CMBlockBuffer?
        var payload = jpeg
        let created = payload.withUnsafeMutableBytes { raw -> OSStatus in
            guard let base = raw.baseAddress else { return -1 }
            return CMBlockBufferCreateWithMemoryBlock(
                allocator: kCFAllocatorDefault, memoryBlock: base, blockLength: raw.count,
                blockAllocator: kCFAllocatorNull, customBlockSource: nil, offsetToData: 0,
                dataLength: raw.count, flags: 0, blockBufferOut: &blockBuffer)
        }
        guard created == noErr, let blockBuffer else { return nil }

        var sampleBuffer: CMSampleBuffer?
        var sampleSize = jpeg.count
        guard
            CMSampleBufferCreateReady(
                allocator: kCFAllocatorDefault, dataBuffer: blockBuffer, formatDescription: format,
                sampleCount: 1, sampleTimingEntryCount: 0, sampleTimingArray: nil,
                sampleSizeEntryCount: 1, sampleSizeArray: &sampleSize,
                sampleBufferOut: &sampleBuffer) == noErr,
            let sampleBuffer
        else { return nil }

        // `_1xRealTime` and no async flag: the caller is a serial streaming loop that wants this
        // frame, not a queue of them.
        nonisolated(unsafe) var decoded: CVPixelBuffer?
        let status = VTDecompressionSessionDecodeFrame(
            session, sampleBuffer: sampleBuffer, flags: [],
            infoFlagsOut: nil
        ) { status, _, buffer, _, _ in
            if status == noErr { decoded = buffer }
        }
        guard status == noErr else {
            report = "hw err \(status)"
            log.error("Live feed: hardware JPEG decode failed with \(status, privacy: .public).")
            return nil
        }
        VTDecompressionSessionWaitForAsynchronousFrames(session)
        if let decoded {
            report = "hw \(fourCCName(CVPixelBufferGetPixelFormatType(decoded)))"
        } else {
            report = "hw empty"
        }
        return decoded
    }

    /// Builds (or rebuilds) the session for a frame size, tearing down the previous one.
    private func prepare(for dimensions: (width: Int, height: Int)) -> Bool {
        if size?.width == dimensions.width, size?.height == dimensions.height, session != nil {
            return true
        }
        if let session {
            VTDecompressionSessionInvalidate(session)
            self.session = nil
        }
        var description: CMFormatDescription?
        guard
            CMVideoFormatDescriptionCreate(
                allocator: kCFAllocatorDefault, codecType: kCMVideoCodecType_JPEG,
                width: Int32(dimensions.width), height: Int32(dimensions.height),
                extensions: nil, formatDescriptionOut: &description) == noErr,
            let description
        else { return false }

        // Prefer `420v` — the chroma-subsampled planes the JPEG already carries — but a decoder
        // that refuses the conversion gets asked for its native output instead (see
        // `forcesPreferredFormat`).
        var attributes: [String: Any] = [
            kCVPixelBufferWidthKey as String: dimensions.width,
            kCVPixelBufferHeightKey as String: dimensions.height,
            kCVPixelBufferMetalCompatibilityKey as String: true,
            kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any](),
        ]
        if forcesPreferredFormat {
            attributes[kCVPixelBufferPixelFormatTypeKey as String] = Self.pixelFormat
        }
        var created: VTDecompressionSession?
        let status = VTDecompressionSessionCreate(
            allocator: kCFAllocatorDefault, formatDescription: description,
            decoderSpecification: nil, imageBufferAttributes: attributes as CFDictionary,
            outputCallback: nil, decompressionSessionOut: &created)
        guard status == noErr, let created else {
            log.error(
                "Live feed: no hardware JPEG decoder for \(dimensions.width, privacy: .public)×\(dimensions.height, privacy: .public) (\(status, privacy: .public))."
            )
            return false
        }
        session = created
        format = description
        size = dimensions
        return true
    }
}

/// Runs VideoToolbox super resolution over a decoded live-view frame, entirely off the render
/// thread.
///
/// This lives on the decode side rather than in the renderer, and that placement is the point.
/// Every earlier attempt drove the processor from `draw(in:)`, where the header forbids it — "ML
/// model loading may take longer than a frame time. Avoid blocking the UI thread or stalling frame
/// rendering pipelines during this call" — and where a Metal command buffer's encode order and
/// Core Image's snapshot semantics both had to be reasoned about. Here there is no command buffer,
/// no drawable, and no draw callback: a frame goes in and a frame comes out, on a thread that is
/// allowed to take its time.
///
/// The chain is `420v` end to end. The camera sends motion JPEG, which already carries
/// chroma-subsampled planes, so the hardware decoder hands over the model's own format and the
/// pixel transfer below resizes within it. No colour conversion happens anywhere on the way in.
final class LiveFeedSuperResolution {
    private let log = Logger(subsystem: "OpenZCine", category: "LiveView")
    /// `AnyObject` because a stored property cannot carry `@available`.
    private var processorBox: AnyObject?
    private var transfer: VTPixelTransferSession?
    private var sourcePool: CVPixelBufferPool?
    private var destinationPool: CVPixelBufferPool?
    private var key: (width: Int, height: Int, scale: Float)?
    /// Latched after a refusal so a device that cannot run the model stops paying per frame.
    private var unavailable = false

    deinit {
        if #available(iOS 26.0, *) { (processorBox as? VTFrameProcessor)?.endSession() }
    }

    /// Upscales `frame`, or returns nil to leave the caller with what it already had.
    func upscale(_ frame: CVPixelBuffer) -> CVPixelBuffer? {
        #if targetEnvironment(simulator)
            return nil
        #else
            guard #available(iOS 26.0, *), !unavailable,
                VTLowLatencySuperResolutionScalerConfiguration.isSupported
            else { return nil }

            let source = (
                width: CVPixelBufferGetWidth(frame), height: CVPixelBufferGetHeight(frame)
            )
            guard source.width > 0, source.height > 0 else { return nil }
            // The processor tops out below a Quality-preset feed (960×960 against 1024×576), so the
            // frame is shrunk to fit first — 6% of width to buy a whole ML upscale.
            let ceiling: (width: Int, height: Int)
            if let maximum = VTLowLatencySuperResolutionScalerConfiguration.maximumDimensions {
                ceiling = (Int(maximum.width), Int(maximum.height))
            } else {
                ceiling = source
            }
            // `scale: 0` disables the helper's panel clause, which is right here: this runs before
            // the frame reaches a drawable, so only the processor's own ceiling binds.
            let input = FeedUpscaler.superResolutionInputSize(
                source: source, target: source, scale: 0, maximum: ceiling)
            let offered = VTLowLatencySuperResolutionScalerConfiguration.supportedScaleFactors(
                frameWidth: input.width, frameHeight: input.height)
            // Capped at ×2 rather than taking the largest on offer. With no panel to measure
            // against, a ×4 of a 960×540 input is a 3840×2160 buffer per frame — the same
            // memory blow-up that starved the drawable queue when the quality model ran, and
            // more resolution than any monitor here can show.
            guard let scale = offered.filter({ $0 <= 2 }).max() ?? offered.min() else {
                return nil
            }

            guard prepare(input: input, scale: scale) else { return nil }
            guard let processor = processorBox as? VTFrameProcessor, let sourcePool,
                let destinationPool
            else { return nil }

            var scaled: CVPixelBuffer?
            guard
                CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, sourcePool, &scaled)
                    == kCVReturnSuccess, let scaled
            else { return nil }
            if let transfer {
                guard
                    VTPixelTransferSessionTransferImage(transfer, from: frame, to: scaled) == noErr
                else { return fail("the frame could not be resized for the model") }
            }

            var destination: CVPixelBuffer?
            guard
                CVPixelBufferPoolCreatePixelBuffer(
                    kCFAllocatorDefault, destinationPool, &destination) == kCVReturnSuccess,
                let destination
            else { return nil }

            let time = CMTime(value: CMTimeValue(frameCount), timescale: 600)
            frameCount += 1
            guard
                let sourceFrame = VTFrameProcessorFrame(
                    buffer: scaled, presentationTimeStamp: time),
                let destinationFrame = VTFrameProcessorFrame(
                    buffer: destination, presentationTimeStamp: time)
            else { return nil }

            // The COMMAND-BUFFER entry point, awaited on this thread.
            //
            // `processWithParameters:completionHandler:` is not usable for this configuration:
            // it segfaults inside VideoToolbox's own `dispatch_async` — `EXC_BAD_ACCESS` at a
            // fixed null offset — in three different contexts (render thread, background thread,
            // buffers from `CVPixelBufferCreate`, buffers from a pool). Same crash every time, so
            // it is the call, not the caller.
            //
            // This side can wait properly, unlike the renderer: no drawable is blocked, so the
            // buffer is committed and awaited and the result is genuinely finished on return.
            guard let queue = commandQueue, let buffer = queue.makeCommandBuffer() else {
                return nil
            }
            processor.process(
                with: buffer,
                parameters: VTLowLatencySuperResolutionScalerParameters(
                    sourceFrame: sourceFrame, destinationFrame: destinationFrame))
            buffer.commit()
            buffer.waitUntilCompleted()
            if let error = buffer.error {
                return fail("the model failed — \(error.localizedDescription)")
            }
            return destination
        #endif
    }

    private var frameCount: Int64 = 0
    /// The model's own queue. Nothing else runs on it, and nothing waits on a drawable.
    private lazy var commandQueue = MTLCreateSystemDefaultDevice()?.makeCommandQueue()

    private func fail(_ reason: String) -> CVPixelBuffer? {
        unavailable = true
        log.error("Live feed: super resolution off — \(reason, privacy: .public).")
        return nil
    }

    #if !targetEnvironment(simulator)
        @available(iOS 26.0, *)
        private func prepare(input: (width: Int, height: Int), scale: Float) -> Bool {
            if key?.width == input.width, key?.height == input.height, key?.scale == scale,
                processorBox != nil
            {
                return true
            }
            let configuration = VTLowLatencySuperResolutionScalerConfiguration(
                frameWidth: input.width, frameHeight: input.height, scaleFactor: scale)
            let output = (
                width: Int((Double(input.width) * Double(scale)).rounded()),
                height: Int((Double(input.height) * Double(scale)).rounded())
            )
            guard
                let sourcePool = Self.pool(
                    attributes: configuration.sourcePixelBufferAttributes, size: input),
                let destinationPool = Self.pool(
                    attributes: configuration.destinationPixelBufferAttributes, size: output)
            else { return false }

            var transfer: VTPixelTransferSession?
            VTPixelTransferSessionCreate(
                allocator: kCFAllocatorDefault, pixelTransferSessionOut: &transfer)

            // End the OLD session if one exists, and build the new one on a FRESH processor.
            //
            // Never `endSession()` on a just-created processor. Every failure in the saga above
            // traced to exactly that: a defensive "reset" called end-before-first-start, and
            // endSession tears down internal state that `init` created and `startSession` does not
            // rebuild. The two entry points then fail in the two ways a nil internal object fails:
            // `processWithParameters:` reaches it through `dispatch_async` — a C call — and
            // segfaults at a fixed null offset, while `processWithCommandBuffer:` reaches it
            // through ObjC messaging, where nil silently swallows every call — a session that
            // starts, accepts frames, errors never, and writes nothing.
            if let old = processorBox as? VTFrameProcessor { old.endSession() }
            processorBox = nil
            let processor = VTFrameProcessor()
            do {
                try processor.startSession(configuration: configuration)
            } catch {
                _ = fail("the session was refused: \(error.localizedDescription)")
                return false
            }
            processorBox = processor
            self.transfer = transfer
            self.sourcePool = sourcePool
            self.destinationPool = destinationPool
            key = (input.width, input.height, scale)
            log.info(
                "Live feed: super resolution \(input.width, privacy: .public)×\(input.height, privacy: .public) → \(output.width, privacy: .public)×\(output.height, privacy: .public)."
            )
            return true
        }
    #endif

    /// A pool built from the processor's OWN attributes, which is what the framework asks for.
    static func pool(attributes: [String: Any], size: (width: Int, height: Int))
        -> CVPixelBufferPool?
    {
        var resolved = attributes
        resolved[kCVPixelBufferWidthKey as String] = size.width
        resolved[kCVPixelBufferHeightKey as String] = size.height
        resolved[kCVPixelBufferMetalCompatibilityKey as String] = true
        if resolved[kCVPixelBufferIOSurfacePropertiesKey as String] == nil {
            resolved[kCVPixelBufferIOSurfacePropertiesKey as String] = [String: Any]()
        }
        var pool: CVPixelBufferPool?
        guard
            CVPixelBufferPoolCreate(kCFAllocatorDefault, nil, resolved as CFDictionary, &pool)
                == kCVReturnSuccess
        else { return nil }
        return pool
    }
}

/// VideoToolbox's temporal noise filter over the live-view stream.
///
/// A far better fit for this pipeline than the super-resolution processor was. It takes the source
/// pixel format explicitly, so a hardware-decoded `420v` frame goes straight in; the destination
/// matches the source, so nothing is converted; and there is no scale factor and no dimension
/// ceiling to work around. It needs one reference frame, which a live stream has by definition —
/// the frame before this one.
///
/// It was also the instrument that implicated our own code: this and the super-resolution scaler
/// share no implementation, yet failed identically — which pointed away from either model and at
/// the one line both ran through, the `endSession()` issued to a fresh processor before its first
/// `startSession` (see `LiveFeedSuperResolution.prepare`). Reachable via `ZC_DEMO_DENOISE`.
final class LiveFeedNoiseFilter {
    private let log = Logger(subsystem: "OpenZCine", category: "LiveView")
    private var processorBox: AnyObject?
    private var destinationPool: CVPixelBufferPool?
    private var key: (width: Int, height: Int, format: OSType)?
    private var previous: CVPixelBuffer?
    private var frameCount: Int64 = 0
    private var unavailable = false
    private lazy var commandQueue = MTLCreateSystemDefaultDevice()?.makeCommandQueue()
    /// What the last call actually did — surfaced on the debug key beside the decoder's own line.
    private(set) var report = "idle"
    /// Set when the filter refuses the decoder's native format and frames convert into
    /// ``filterFormat`` on the way in (the reference chain then lives in that format too).
    private var inputTransfer: VTPixelTransferSession?
    private var inputPool: CVPixelBufferPool?
    /// The format the filter actually runs in — its own pick, not ours.
    private var filterFormat: OSType = 0
    /// Frames held back so the filter can see the FUTURE. Its length is the latency this costs.
    private var pending: [CVPixelBuffer] = []
    /// How many future frames the processor says it can use (`nextFrameCount`).
    private var nextFrameCount = 0

    #if !targetEnvironment(simulator)
        /// Converts a native-format frame into the format the filter chose.
        private func convertToPreferred(_ frame: CVPixelBuffer) -> CVPixelBuffer? {
            guard let inputTransfer, let inputPool else { return nil }
            var scratch: CVPixelBuffer?
            guard
                CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, inputPool, &scratch)
                    == kCVReturnSuccess, let scratch
            else { return nil }
            guard
                VTPixelTransferSessionTransferImage(inputTransfer, from: frame, to: scratch)
                    == noErr
            else { return nil }
            return scratch
        }
    #endif

    deinit {
        if #available(iOS 26.0, *) { (processorBox as? VTFrameProcessor)?.endSession() }
    }

    /// Turns the filter off for this session and SAYS WHY, where the operator can see it.
    ///
    /// Every one of these used to be a `log.error` and a silent latch — invisible from the
    /// operator's chair, so "noise reduction stopped working" was the only symptom available. The
    /// reason now reaches the settings row, which is also what stops the switch sitting there
    /// looking armed over a filter that has given up.
    @discardableResult
    private func disable(_ reason: String) -> Bool {
        unavailable = true
        report = reason
        LiveDenoiseSwitch.decoderReportsUnavailable = reason
        log.error("Live feed: noise reduction off — \(reason, privacy: .public).")
        return false
    }

    /// Forgets a latched refusal and the frame history behind it.
    func reset() {
        unavailable = false
        previous = nil
        pending.removeAll()
        key = nil
        report = "idle"
    }

    /// Denoises `frame`, or returns nil to leave the caller with what it already had.
    func filter(_ frame: CVPixelBuffer, strength: Float) -> CVPixelBuffer? {
        #if targetEnvironment(simulator)
            return nil
        #else
            // A latched failure keeps ITS report — overwriting it with a generic word is how a
            // one-frame "cfg refused 420v" read as "unsupported" from the operator's chair.
            if unavailable { return nil }
            guard #available(iOS 26.0, *), VTTemporalNoiseFilterConfiguration.isSupported else {
                report = "OS says unsupported"
                return nil
            }
            var size = (
                width: CVPixelBufferGetWidth(frame), height: CVPixelBufferGetHeight(frame),
                format: CVPixelBufferGetPixelFormatType(frame)
            )
            var source = frame
            guard prepare(size) else { return nil }
            // The filter may have refused the decoder's native format and configured for `420v`
            // instead — in that mode every frame converts on the way in, references included.
            if inputTransfer != nil {
                guard let converted = convertToPreferred(frame) else {
                    report = "transfer err"
                    return nil
                }
                source = converted
                size.format = filterFormat
            }
            guard let processor = processorBox as? VTFrameProcessor, let destinationPool,
                let queue = commandQueue
            else { return nil }

            // A WINDOW, not a single reference: the processor reports how many past and future
            // frames it can use (1 and 2 on this hardware), and giving it none of the future ones
            // was running it at its weakest. Future frames mean holding the picture back — the
            // filter denoises frame N only once N+1 and N+2 exist — so this costs exactly
            // `nextFrameCount` frames of latency, spent deliberately.
            pending.append(source)
            let futureWanted = nextFrameCount
            guard pending.count > futureWanted else {
                report = "filling (\(pending.count)/\(futureWanted + 1))"
                return nil
            }
            // The oldest queued frame is the one being denoised; everything after it is future.
            let current = pending.removeFirst()
            let futures = Array(pending.prefix(futureWanted))
            let pastFrames = previous.map { [$0] } ?? []
            guard !pastFrames.isEmpty || !futures.isEmpty else {
                previous = current
                report = "seeding"
                return nil
            }

            var destination: CVPixelBuffer?
            guard
                CVPixelBufferPoolCreatePixelBuffer(
                    kCFAllocatorDefault, destinationPool, &destination) == kCVReturnSuccess,
                let destination
            else { return nil }
            // Carry the decoder's colour tags onto the output. The source buffer arrives tagged
            // (matrix, primaries, transfer) by VideoToolbox; a pool buffer carries nothing, and
            // Core Image reading an untagged buffer falls back to defaults — a small matrix/range
            // mismatch whose classic look is slightly lifted blacks. This is the same asymmetry
            // that showed as an exposure lift on the decode-side super-resolution path.
            if let attachments = CVBufferCopyAttachments(current, .shouldPropagate) {
                CVBufferSetAttachments(destination, attachments, .shouldPropagate)
            }

            // Presentation stamps must be in real order across past → current → future, because
            // that ordering is how the processor knows which way time runs.
            frameCount += 1
            let step = CMTimeValue(frameCount)
            let time = CMTime(value: step, timescale: 600)
            guard
                let sourceFrame = VTFrameProcessorFrame(
                    buffer: current, presentationTimeStamp: time),
                let destinationFrame = VTFrameProcessorFrame(
                    buffer: destination, presentationTimeStamp: time)
            else { return nil }
            let pastReferences = pastFrames.enumerated().compactMap { index, buffer in
                VTFrameProcessorFrame(
                    buffer: buffer,
                    presentationTimeStamp: CMTime(
                        value: step - CMTimeValue(pastFrames.count - index), timescale: 600))
            }
            let futureReferences = futures.enumerated().compactMap { index, buffer in
                VTFrameProcessorFrame(
                    buffer: buffer,
                    presentationTimeStamp: CMTime(
                        value: step + CMTimeValue(index + 1), timescale: 600))
            }
            guard
                let parameters = VTTemporalNoiseFilterParameters(
                    sourceFrame: sourceFrame,
                    nextFrames: futureReferences,
                    previousFrames: pastReferences,
                    destinationFrame: destinationFrame,
                    filterStrength: max(0, min(1, strength)),
                    hasDiscontinuity: false)
            else { return nil }

            guard let buffer = queue.makeCommandBuffer() else { return nil }
            processor.process(with: buffer, parameters: parameters)
            buffer.commit()
            buffer.waitUntilCompleted()
            if let error = buffer.error {
                _ = disable("the model failed (\((error as NSError).code))")
                return nil
            }
            previous = current
            report = "ran \(fourCCName(size.format)) ±\(pastFrames.count)/\(futures.count)"
            return destination
        #endif
    }

    #if !targetEnvironment(simulator)
        @available(iOS 26.0, *)
        private func prepare(_ size: (width: Int, height: Int, format: OSType)) -> Bool {
            if key?.width == size.width, key?.height == size.height, key?.format == size.format,
                processorBox != nil
            {
                return true
            }
            // The filter's format is ITS choice, not ours. Probed on macOS 26 it accepts ONLY
            // Apple's compressed-memory YCbCr family (`&8v0`, `-8v0`, …) — never plain `420v`,
            // which is why every earlier configure "refused" and the operator read a dead toggle.
            // So: try the frame's own format first (free when it works), then walk the filter's
            // published list and convert frames into the first one it takes. A pixel transfer is
            // a hardware blit; the compressed formats are the GPU's native furniture.
            var candidates: [OSType] = [size.format]
            candidates.append(
                contentsOf: VTTemporalNoiseFilterConfiguration.supportedSourcePixelFormats.filter {
                    $0 != size.format
                })
            var chosenFormat = size.format
            var configuration: VTTemporalNoiseFilterConfiguration?
            for candidate in candidates {
                if let config = VTTemporalNoiseFilterConfiguration(
                    frameWidth: size.width, frameHeight: size.height,
                    sourcePixelFormat: candidate)
                {
                    chosenFormat = candidate
                    configuration = config
                    break
                }
            }
            guard let configuration else {
                return disable(
                    "this camera format is not one it takes (\(fourCCName(size.format)))")
            }
            if chosenFormat == size.format {
                inputTransfer = nil
                inputPool = nil
            } else {
                var transfer: VTPixelTransferSession?
                VTPixelTransferSessionCreate(
                    allocator: kCFAllocatorDefault, pixelTransferSessionOut: &transfer)
                let attributes: [String: Any] = [
                    kCVPixelBufferPixelFormatTypeKey as String: chosenFormat,
                    kCVPixelBufferWidthKey as String: size.width,
                    kCVPixelBufferHeightKey as String: size.height,
                    kCVPixelBufferMetalCompatibilityKey as String: true,
                    kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any](),
                ]
                var pool: CVPixelBufferPool?
                CVPixelBufferPoolCreate(
                    kCFAllocatorDefault, nil, attributes as CFDictionary, &pool)
                guard let transfer, let pool else {
                    return disable("the frame could not be converted for it")
                }
                inputTransfer = transfer
                inputPool = pool
            }
            filterFormat = chosenFormat
            // How far ahead this processor can see. Clamped to two frames: it is latency on a
            // focus monitor, and the operator agreed to spend it, not to spend an unbounded
            // amount of it if a future OS raises the number.
            nextFrameCount = min(configuration.nextFrameCount ?? 0, 2)
            pending.removeAll()
            guard
                let pool = LiveFeedSuperResolution.pool(
                    attributes: configuration.destinationPixelBufferAttributes,
                    size: (size.width, size.height))
            else { return false }

            // End the OLD session if one exists, and build the new one on a FRESH processor.
            //
            // Never `endSession()` on a just-created processor. Every failure in the saga above
            // traced to exactly that: a defensive "reset" called end-before-first-start, and
            // endSession tears down internal state that `init` created and `startSession` does not
            // rebuild. The two entry points then fail in the two ways a nil internal object fails:
            // `processWithParameters:` reaches it through `dispatch_async` — a C call — and
            // segfaults at a fixed null offset, while `processWithCommandBuffer:` reaches it
            // through ObjC messaging, where nil silently swallows every call — a session that
            // starts, accepts frames, errors never, and writes nothing.
            if let old = processorBox as? VTFrameProcessor { old.endSession() }
            processorBox = nil
            let processor = VTFrameProcessor()
            do {
                try processor.startSession(configuration: configuration)
            } catch {
                return disable("the session was refused (\((error as NSError).code))")
            }
            processorBox = processor
            destinationPool = pool
            // A new session owns a new history: references from the old one describe a stream
            // this processor never saw.
            previous = nil
            pending.removeAll()
            key = size
            log.info(
                "Live feed: temporal noise filter \(size.width, privacy: .public)×\(size.height, privacy: .public), \(self.nextFrameCount, privacy: .public) future frame(s)."
            )
            return true
        }
    #endif
}
