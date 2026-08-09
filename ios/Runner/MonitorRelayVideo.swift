import CoreImage
import Foundation
import UIKit
import VideoToolbox
import os

private let videoLogger = Logger(subsystem: "com.opencapture.openzcine", category: "relay-video")

/// Hardware HEVC for the relay's picture stream.
///
/// ## Why the relay stopped passing JPEGs through
///
/// A live-view JPEG is ~100 KB; at 25 fps that is ~20 Mbit/s, and on a set router every relayed
/// frame crosses the air FOUR times (camera→router→host→router→viewer), so the viewer's share of
/// a busy channel delivered 8–11 fps. Hardware HEVC carries the same picture at roughly a quarter
/// of the bytes for effectively zero CPU — the A-series encoder block does the work — which is
/// the difference between a viewer that tracks the host and one that slideshows.
///
/// The JPEG pass-through survives as the fallback (`FrameCodec.jpeg` on the wire): an encoder
/// that fails to come up must degrade to a heavier picture, never to no picture.
///
/// ## The keyframe discipline
///
/// Unlike JPEG, an HEVC frame references the frames before it. Three rules keep that sound over a
/// lossy relay, and they live in three places on purpose:
/// - a joiner needs a keyframe first — the HOST forces one when a peer connects;
/// - a peer that skipped frames under backpressure needs a keyframe to resume — the host tracks
///   that per peer and asks the encoder;
/// - a decoder that failed needs a keyframe to recover — the VIEWER skips until one arrives.
final class MonitorRelayVideoEncoder: @unchecked Sendable {
    struct EncodedFrame: @unchecked Sendable {
        let data: Data
        let isKeyframe: Bool
        /// VPS/SPS/PPS, present on keyframes so a joiner can build a decoder from the stream.
        let parameterSets: [Data]?
    }

    /// Starting rate. The relay carries LOG footage that every watcher contrast-stretches
    /// through a LUT, so quantization noise the flat image hides becomes blotching on their
    /// screens — the budget is sized for the content, not the pixel count, and still runs
    /// well under the JPEG stream it replaced. Adapted live against viewer backpressure
    /// (`RelayBitrateAdaptation`); mid-session `AverageBitRate` updates are the same mechanism
    /// production WebRTC uses on this encoder.
    private static let initialBitsPerSecond = RelayBitrateAdaptation.ladder[0]
    /// Latency-vs-quality stance; drives the encoder's own keyframe cadence. Forced keyframes
    /// (joins, resumes) are profile-independent, so a joiner never waits longer either way.
    private let profile: RelayEncoderProfile

    init(profile: RelayEncoderProfile) {
        self.profile = profile
    }
    /// Minimum spacing between FORCED keyframes. A keyframe is 3–8× the bytes of a predicted
    /// frame; a permanently-slow viewer re-requesting one on every skip would turn the whole
    /// stream keyframe-heavy and degrade every other viewer with it. One second matches
    /// deployed WebRTC-server practice for coalescing keyframe requests; a join or resume waits
    /// at most this long — the request stays latched, never dropped.
    private static let minSecondsBetweenForcedKeyframes: CFAbsoluteTime = 1.0

    private let queue = DispatchQueue(
        label: "com.opencapture.openzcine.relay-encode", qos: .userInitiated)
    private var session: VTCompressionSession?
    private var sessionWidth = 0
    private var sessionHeight = 0
    private var frameIndex: Int64 = 0
    private var forceKeyframe = true
    private var lastForcedKeyframeAt: CFAbsoluteTime = 0
    /// Current targets; survive session rebuilds (size changes) and adaptation steps.
    private var targetBitsPerSecond = MonitorRelayVideoEncoder.initialBitsPerSecond
    /// Worst permitted frame QP, stepped WITH the bitrate: strict at full budget (a sag must
    /// degrade to dropped frames, never to mush an operator would misread as a focus problem),
    /// relaxed on the low rungs where a cap the rate controller cannot honor would keep the
    /// stream oversized right when shrinking it is the whole point.
    private var targetMaxFrameQP = RelayBitrateAdaptation.maxFrameQPLadder[0]

    /// Retargets the stream on the LIVE session — the adaptation path. When the dynamic rate
    /// set is refused, the session is invalidated instead: the next frame rebuilds at the
    /// stored targets, which always works (a size change already proves that path). The QP set
    /// is best-effort — an encoder that refuses it keeps the previous cap until a rebuild.
    func setTarget(bitsPerSecond: Int, maxFrameQP: Int) {
        queue.async {
            self.targetBitsPerSecond = bitsPerSecond
            self.targetMaxFrameQP = maxFrameQP
            guard let session = self.session else { return }
            let rateStatus = VTSessionSetProperty(
                session, key: kVTCompressionPropertyKey_AverageBitRate,
                value: bitsPerSecond as CFNumber)
            // Byte-per-second window beside the average. 2x, not tighter: a hard 1-second
            // window sized close to the average crushes the frames right after every keyframe
            // — a periodic blotch pulse watchers can see.
            VTSessionSetProperty(
                session, key: kVTCompressionPropertyKey_DataRateLimits,
                value: [Double(bitsPerSecond) / 8 * 2.0, 1.0] as CFArray)
            VTSessionSetProperty(
                session, key: kVTCompressionPropertyKey_MaxAllowedFrameQP,
                value: maxFrameQP as CFNumber)
            if rateStatus != noErr {
                videoLogger.info("relay bitrate retarget via rebuild (\(rateStatus))")
                VTCompressionSessionInvalidate(session)
                self.session = nil
            }
        }
    }
    /// Encoded output captured by the in-flight frame's handler.
    private var captured: EncodedFrame?

    /// Ensures the next encoded frame decodes standalone. Idempotent; safe from any thread.
    func requestKeyframe() {
        queue.async { self.forceKeyframe = true }
    }

    func invalidate() {
        queue.async {
            if let session = self.session {
                VTCompressionSessionInvalidate(session)
                self.session = nil
            }
        }
    }

    /// Encodes one frame. `completion` receives nil when the encoder is unavailable — the caller
    /// falls back to JPEG rather than dropping the picture.
    func encode(_ image: CGImage, completion: @escaping @Sendable (EncodedFrame?) -> Void) {
        queue.async { completion(self.encodeSync(image)) }
    }

    private func encodeSync(_ image: CGImage) -> EncodedFrame? {
        let width = image.width
        let height = image.height
        guard width > 0, height > 0 else { return nil }
        // A stream-size change (thermal step-down, preset change) needs a fresh session; HEVC
        // cannot change dimensions mid-stream.
        if session == nil || width != sessionWidth || height != sessionHeight {
            rebuildSession(width: width, height: height)
        }
        guard let session else { return nil }

        guard let pool = VTCompressionSessionGetPixelBufferPool(session) else { return nil }
        var pooled: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pooled) == kCVReturnSuccess,
            let pixelBuffer = pooled
        else { return nil }
        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        if let context = CGContext(
            data: CVPixelBufferGetBaseAddress(pixelBuffer),
            width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: CVPixelBufferGetBytesPerRow(pixelBuffer),
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                | CGBitmapInfo.byteOrder32Little.rawValue)
        {
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        }
        CVPixelBufferUnlockBaseAddress(pixelBuffer, [])
        // The input's own tags, matching the session's output tags exactly: VideoToolbox
        // colour-matches whenever they differ, and an untagged RGB buffer invites it to guess.
        // Identical tags make the RGB→YCbCr matrixing the ONLY conversion in the pipeline.
        CVBufferSetAttachment(
            pixelBuffer, kCVImageBufferColorPrimariesKey,
            kCVImageBufferColorPrimaries_ITU_R_709_2, .shouldPropagate)
        CVBufferSetAttachment(
            pixelBuffer, kCVImageBufferTransferFunctionKey,
            kCVImageBufferTransferFunction_sRGB, .shouldPropagate)
        CVBufferSetAttachment(
            pixelBuffer, kCVImageBufferYCbCrMatrixKey,
            kCVImageBufferYCbCrMatrix_ITU_R_709_2, .shouldPropagate)

        // Honor a latched keyframe request only past the storm limit; the latch survives an
        // deferred honor, so a joiner is never dropped — only spaced.
        let now = CFAbsoluteTimeGetCurrent()
        let honorsKeyframe =
            forceKeyframe && now - lastForcedKeyframeAt >= Self.minSecondsBetweenForcedKeyframes
        let properties: CFDictionary? =
            honorsKeyframe
            ? [kVTEncodeFrameOptionKey_ForceKeyFrame: kCFBooleanTrue as Any] as CFDictionary
            : nil
        if honorsKeyframe {
            forceKeyframe = false
            lastForcedKeyframeAt = now
        }
        captured = nil
        let timestamp = CMTime(value: frameIndex, timescale: 600)
        frameIndex += 24  // Nominal cadence only; RealTime encoding does not pace on it.
        let status = VTCompressionSessionEncodeFrame(
            session, imageBuffer: pixelBuffer, presentationTimeStamp: timestamp,
            duration: .invalid, frameProperties: properties, infoFlagsOut: nil
        ) { [weak self] status, _, sampleBuffer in
            guard status == noErr, let sampleBuffer else { return }
            self?.captured = Self.extract(from: sampleBuffer)
        }
        guard status == noErr else {
            videoLogger.error("relay encode failed: \(status)")
            return nil
        }
        // RealTime + no reordering: draining synchronously hands the frame back on this queue.
        VTCompressionSessionCompleteFrames(session, untilPresentationTimeStamp: timestamp)
        return captured
    }

    private func rebuildSession(width: Int, height: Int) {
        if let session {
            VTCompressionSessionInvalidate(session)
            self.session = nil
        }
        var created: VTCompressionSession?
        let status = VTCompressionSessionCreate(
            allocator: nil, width: Int32(width), height: Int32(height),
            codecType: kCMVideoCodecType_HEVC, encoderSpecification: nil,
            imageBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
            ] as CFDictionary,
            compressedDataAllocator: nil, outputCallback: nil, refcon: nil,
            compressionSessionOut: &created)
        guard status == noErr, let created else {
            videoLogger.error("relay encoder unavailable: \(status)")
            return
        }
        VTSessionSetProperty(
            created, key: kVTCompressionPropertyKey_RealTime, value: kCFBooleanTrue)
        // Main10, with an 8-bit source: the two extra bits of internal precision are the
        // cheapest smoothing there is for the flat gradients log footage is full of — banding
        // and dark-area blocking come from transform quantization, not from the source depth.
        // Hardware-native encode and decode on every device the app targets.
        VTSessionSetProperty(
            created, key: kVTCompressionPropertyKey_ProfileLevel,
            value: kVTProfileLevel_HEVC_Main10_AutoLevel)
        // No B-frames: reordering buys compression at the cost of latency, and a monitor is the
        // one consumer that always takes latency as the loss.
        VTSessionSetProperty(
            created, key: kVTCompressionPropertyKey_AllowFrameReordering, value: kCFBooleanFalse)
        // A bitrate sag degrades to dropped frames, never to mush an operator would misread as
        // a focus problem. (The speed-over-quality hint tried here traded visibly worse mode
        // decisions for headroom this encoder never needed at live-view sizes — reverted.)
        VTSessionSetProperty(
            created, key: kVTCompressionPropertyKey_MaxAllowedFrameQP,
            value: targetMaxFrameQP as CFNumber)
        // Explicit colour tags, written into the stream — and chosen for an IDENTITY round
        // trip, not for broadcast convention. The source pixels are sRGB (decoded JPEG drawn
        // through CoreGraphics); tagging them BT.709-transfer made the decode side apply a
        // 709→sRGB transfer conversion the content never had — a shadows/contrast shift every
        // watcher LUT then amplified. Both ends of this wire are our own code, so the stream
        // says what the pixels ARE: sRGB transfer, 709 primaries (identical to sRGB's), 709
        // matrix. Decoder attachments then cancel exactly.
        VTSessionSetProperty(
            created, key: kVTCompressionPropertyKey_ColorPrimaries,
            value: kCMFormatDescriptionColorPrimaries_ITU_R_709_2)
        VTSessionSetProperty(
            created, key: kVTCompressionPropertyKey_TransferFunction,
            value: kCMFormatDescriptionTransferFunction_sRGB)
        VTSessionSetProperty(
            created, key: kVTCompressionPropertyKey_YCbCrMatrix,
            value: kCMFormatDescriptionYCbCrMatrix_ITU_R_709_2)
        VTSessionSetProperty(
            created, key: kVTCompressionPropertyKey_AverageBitRate,
            value: targetBitsPerSecond as CFNumber)
        VTSessionSetProperty(
            created, key: kVTCompressionPropertyKey_DataRateLimits,
            value: [Double(targetBitsPerSecond) / 8 * 2.0, 1.0] as CFArray)
        VTSessionSetProperty(
            created, key: kVTCompressionPropertyKey_MaxKeyFrameInterval,
            value: profile.maxKeyframeInterval as CFNumber)
        VTCompressionSessionPrepareToEncodeFrames(created)
        session = created
        sessionWidth = width
        sessionHeight = height
        forceKeyframe = true
        videoLogger.info("relay HEVC encoder up: \(width)x\(height)")
    }

    private static func extract(from sampleBuffer: CMSampleBuffer) -> EncodedFrame? {
        let isKeyframe: Bool = {
            guard
                let attachments = CMSampleBufferGetSampleAttachmentsArray(
                    sampleBuffer, createIfNecessary: false) as? [[CFString: Any]],
                let first = attachments.first
            else { return true }
            return !(first[kCMSampleAttachmentKey_NotSync] as? Bool ?? false)
        }()

        var parameterSets: [Data]?
        if isKeyframe, let format = CMSampleBufferGetFormatDescription(sampleBuffer) {
            var count = 0
            CMVideoFormatDescriptionGetHEVCParameterSetAtIndex(
                format, parameterSetIndex: 0, parameterSetPointerOut: nil,
                parameterSetSizeOut: nil, parameterSetCountOut: &count,
                nalUnitHeaderLengthOut: nil)
            var sets: [Data] = []
            for index in 0..<count {
                var pointer: UnsafePointer<UInt8>?
                var size = 0
                CMVideoFormatDescriptionGetHEVCParameterSetAtIndex(
                    format, parameterSetIndex: index, parameterSetPointerOut: &pointer,
                    parameterSetSizeOut: &size, parameterSetCountOut: nil,
                    nalUnitHeaderLengthOut: nil)
                if let pointer { sets.append(Data(bytes: pointer, count: size)) }
            }
            if !sets.isEmpty { parameterSets = sets }
        }

        guard let blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else { return nil }
        var length = 0
        var pointer: UnsafeMutablePointer<CChar>?
        guard
            CMBlockBufferGetDataPointer(
                blockBuffer, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: &length,
                dataPointerOut: &pointer) == kCMBlockBufferNoErr,
            let pointer, length > 0
        else { return nil }
        return EncodedFrame(
            data: Data(bytes: pointer, count: length), isKeyframe: isKeyframe,
            parameterSets: parameterSets)
    }
}

/// The viewer's half: HEVC frames back into the CGImage-backed `UIImage`s the monitor pipeline
/// requires (the scope tap hard-guards on `cgImage`).
final class MonitorRelayVideoDecoder: @unchecked Sendable {
    private let queue = DispatchQueue(
        label: "com.opencapture.openzcine.relay-decode", qos: .userInitiated)
    private var session: VTDecompressionSession?
    private var formatDescription: CMVideoFormatDescription?
    /// The parameter sets the current session was built from, to detect a format change.
    private var activeParameterSets: [Data] = []
    /// True until a keyframe decodes — at join, and again after any failure. Predicted frames
    /// against a broken reference chain decode into smearing, which reads as a corrupt feed.
    private var needsKeyframe = true
    private let renderContext = CIContext(options: [.cacheIntermediates: false])

    func invalidate() {
        queue.async {
            if let session = self.session {
                VTDecompressionSessionInvalidate(session)
                self.session = nil
            }
            self.formatDescription = nil
            self.activeParameterSets = []
            self.needsKeyframe = true
        }
    }

    /// Decodes one frame; nil when it cannot be decoded yet (awaiting a keyframe) or at all.
    func decode(
        _ data: Data, isKeyframe: Bool, parameterSets: [Data]?,
        completion: @escaping @Sendable (UIImage?) -> Void
    ) {
        queue.async {
            completion(
                self.decodeSync(data, isKeyframe: isKeyframe, parameterSets: parameterSets))
        }
    }

    private func decodeSync(_ data: Data, isKeyframe: Bool, parameterSets: [Data]?) -> UIImage? {
        if let parameterSets, parameterSets != activeParameterSets {
            rebuildSession(parameterSets: parameterSets)
        }
        guard let session, let formatDescription else { return nil }
        if needsKeyframe && !isKeyframe { return nil }

        var blockBuffer: CMBlockBuffer?
        let status = data.withUnsafeBytes { (bytes: UnsafeRawBufferPointer) -> OSStatus in
            var created: CMBlockBuffer?
            let allocate = CMBlockBufferCreateWithMemoryBlock(
                allocator: nil, memoryBlock: nil, blockLength: data.count, blockAllocator: nil,
                customBlockSource: nil, offsetToData: 0, dataLength: data.count, flags: 0,
                blockBufferOut: &created)
            guard allocate == kCMBlockBufferNoErr, let created else { return allocate }
            let copy = CMBlockBufferReplaceDataBytes(
                with: bytes.baseAddress!, blockBuffer: created, offsetIntoDestination: 0,
                dataLength: data.count)
            guard copy == kCMBlockBufferNoErr else { return copy }
            blockBuffer = created
            return kCMBlockBufferNoErr
        }
        guard status == kCMBlockBufferNoErr, let blockBuffer else { return nil }

        var sampleBuffer: CMSampleBuffer?
        var sampleSize = data.count
        guard
            CMSampleBufferCreateReady(
                allocator: nil, dataBuffer: blockBuffer, formatDescription: formatDescription,
                sampleCount: 1, sampleTimingEntryCount: 0, sampleTimingArray: nil,
                sampleSizeEntryCount: 1, sampleSizeArray: &sampleSize,
                sampleBufferOut: &sampleBuffer) == noErr,
            let sampleBuffer
        else { return nil }

        var decoded: CVImageBuffer?
        let decodeStatus = VTDecompressionSessionDecodeFrame(
            session, sampleBuffer: sampleBuffer, flags: [], infoFlagsOut: nil
        ) { status, _, imageBuffer, _, _ in
            guard status == noErr else { return }
            decoded = imageBuffer
        }
        guard decodeStatus == noErr, let imageBuffer = decoded else {
            // The reference chain is broken; predicted frames are garbage until a keyframe.
            needsKeyframe = true
            return nil
        }
        needsKeyframe = false

        let ciImage = CIImage(cvImageBuffer: imageBuffer)
        guard let cgImage = renderContext.createCGImage(ciImage, from: ciImage.extent) else {
            return nil
        }
        return UIImage(cgImage: cgImage)
    }

    private func rebuildSession(parameterSets: [Data]) {
        if let session {
            VTDecompressionSessionInvalidate(session)
            self.session = nil
        }
        formatDescription = nil
        activeParameterSets = []
        needsKeyframe = true

        // Flattened into ONE contiguous buffer so the pointers handed to CoreMedia stay valid
        // for the whole create call. Per-set pointers escaped from `withUnsafeBytes` are undefined
        // behaviour — and for parameter sets it bites immediately, because they are small enough
        // for Data's inline storage, so the escaped pointer refers to a dead stack copy. That
        // presented as CoreMedia rejecting every (perfectly valid) parameter set with -12712.
        let sizes = parameterSets.map(\.count)
        var flattened: [UInt8] = []
        flattened.reserveCapacity(sizes.reduce(0, +))
        for set in parameterSets { flattened.append(contentsOf: set) }
        var format: CMVideoFormatDescription?
        let status = flattened.withUnsafeBufferPointer { buffer -> OSStatus in
            guard let base = buffer.baseAddress else {
                return kCMFormatDescriptionError_InvalidParameter
            }
            var pointers: [UnsafePointer<UInt8>] = []
            var offset = 0
            for size in sizes {
                pointers.append(base + offset)
                offset += size
            }
            return CMVideoFormatDescriptionCreateFromHEVCParameterSets(
                allocator: nil, parameterSetCount: pointers.count,
                parameterSetPointers: pointers, parameterSetSizes: sizes, nalUnitHeaderLength: 4,
                extensions: nil, formatDescriptionOut: &format)
        }
        guard status == noErr, let format else {
            videoLogger.error("relay decoder format rejected: \(status)")
            return
        }
        var created: VTDecompressionSession?
        let sessionStatus = VTDecompressionSessionCreate(
            allocator: nil, formatDescription: format, decoderSpecification: nil,
            imageBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
            ] as CFDictionary,
            outputCallback: nil, decompressionSessionOut: &created)
        guard sessionStatus == noErr, let created else {
            videoLogger.error("relay decoder unavailable: \(sessionStatus)")
            return
        }
        session = created
        formatDescription = format
        activeParameterSets = parameterSets
        videoLogger.info("relay HEVC decoder up")
    }
}
