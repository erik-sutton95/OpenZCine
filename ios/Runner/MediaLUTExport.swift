import AVFoundation
import CoreImage
import CoreMedia
import CoreVideo
import Foundation
import UIKit
import os

/// LUT baking for media playback preview and export. Builds the same `CIColorCube` pipeline the live
/// view uses (`cube.rgbaComponents` + `inputCubeDimension`, display-encoded sRGB working space,
/// 16-bit half-float intermediates) and applies it either as a playback `AVVideoComposition`
/// (preview) or baked into a new file via `AVAssetReader` / `AVAssetWriter` (export).
enum MediaLUT {
    private static let logger = Logger(subsystem: "OpenZCine", category: "media-export")

    private static func describe(_ error: Error) -> String {
        let ns = error as NSError
        return "\(ns.domain) code=\(ns.code) \(ns.localizedDescription)"
    }

    private static func trace(_ message: String) {
        logger.info("\(message, privacy: .public)")
    }

    // Match `LiveFrameProcessor`: RGBAh working buffers in display-encoded sRGB so cube
    // trilinear interpolation doesn't posterize when AVFoundation composites 8-bit source frames.
    private static let displayColorSpace =
        CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
    static let renderContext = CIContext(options: [
        .workingFormat: CIFormat.RGBAh,
        .workingColorSpace: displayColorSpace,
        .highQualityDownsample: true,
    ])

    enum ExportError: LocalizedError {
        case sessionSetupFailed
        case failed(String)
        case invalidFilename

        var errorDescription: String? {
            switch self {
            case .sessionSetupFailed: "Couldn't create the export session for this clip."
            case .failed(let reason): "Export failed: \(reason)"
            case .invalidFilename: "Enter a valid filename."
            }
        }
    }

    struct ExportResult: Sendable {
        let videoURL: URL
        let metadataURL: URL?
    }

    /// A live playback composition that bakes `cube` onto every frame. Captures only Sendable values
    /// (cube dimension + data), rebuilding the filter inside the handler so it's concurrency-safe.
    /// Reused for both playback preview and the export session below.
    static func videoComposition(for asset: AVAsset, cube: CubeLUT) -> AVVideoComposition {
        let prepared = cube.preparedForRenderer()
        let dimension = prepared.size
        let cubeData = prepared.rgbaComponents.withUnsafeBytes { Data($0) }
        let composition = AVVideoComposition(asset: asset) { request in
            let source = request.sourceImage
            let extent = source.extent
            guard
                let filter = CIFilter(
                    name: "CIColorCube",
                    parameters: [
                        "inputCubeDimension": dimension,
                        "inputCubeData": cubeData,
                    ])
            else {
                request.finish(with: source, context: renderContext)
                return
            }
            filter.setValue(source.clampedToExtent(), forKey: kCIInputImageKey)
            let output = (filter.outputImage ?? source).cropped(to: extent)
            request.finish(with: output, context: renderContext)
        }
        return composition
    }

    /// Mutable effects holder for a single stable `AVVideoComposition` during clip playback.
    ///
    /// Assist toggles update the locked payload in place so AVFoundation keeps decoding without a
    /// compositor reset. Export still uses the one-shot `videoComposition(for:cube:)` above.
    ///
    /// Scope overlays sample the compositor's *source* frame (pre-LUT / pre-false-colour), matching
    /// live view which reads the raw JPEG — not `AVPlayerItemVideoOutput`, which reflects the graded
    /// presentation.
    final class PlaybackEffectsBox: @unchecked Sendable {
        struct ScopeSnapshot: Sendable {
            let revision: UInt64
            let samples: ScopeSamples
        }

        private struct ScopeState: Sendable {
            var revision: UInt64 = 0
            var samples: ScopeSamples = .empty
            var isActive = false
            var activationGeneration: UInt64 = 0
            var compositionGeneration: UInt64 = 0
            var nextRequestSequence: UInt64 = 0
            var publishedRequestSequence: UInt64 = 0
        }

        private struct ScopeSamplingTicket: Sendable {
            let activationGeneration: UInt64
            let compositionGeneration: UInt64
            let requestSequence: UInt64
        }

        private let effects = OSAllocatedUnfairLock<ImageEffectsCompositor.ResolvedEffects>(
            initialState: ImageEffectsCompositor.ResolvedEffects())
        private let scopeState = OSAllocatedUnfairLock<ScopeState>(initialState: ScopeState())

        /// Updates the composition payload in place. Returns `true` when the effects actually
        /// changed, so the player can force a paused frame to re-render only when needed (and
        /// skip no-op re-sets from unrelated `assistConfiguration` changes, e.g. grid or guides).
        func set(effects: ImageEffectsCompositor.ResolvedEffects) -> Bool {
            self.effects.withLock { current in
                guard current != effects else { return false }
                current = effects
                return true
            }
        }

        func setScopesActive(_ active: Bool) {
            scopeState.withLock {
                if $0.isActive != active {
                    $0.activationGeneration &+= 1
                }
                $0.isActive = active
                if !active {
                    $0.revision &+= 1
                    $0.samples = .empty
                    $0.publishedRequestSequence = 0
                }
            }
        }

        /// Invalidates compositor callbacks retained by an outgoing player item.
        func invalidateScopeComposition() {
            scopeState.withLock {
                $0.compositionGeneration &+= 1
                $0.activationGeneration &+= 1
                $0.nextRequestSequence = 0
                $0.publishedRequestSequence = 0
                $0.revision &+= 1
                $0.samples = .empty
            }
        }

        func readScopeSnapshot() -> ScopeSnapshot {
            scopeState.withLock { ScopeSnapshot(revision: $0.revision, samples: $0.samples) }
        }

        func makeVideoComposition(for asset: AVAsset) -> AVVideoComposition {
            let box = self
            let compositionGeneration = scopeState.withLock { state -> UInt64 in
                state.compositionGeneration &+= 1
                state.activationGeneration &+= 1
                state.nextRequestSequence = 0
                state.publishedRequestSequence = 0
                state.revision &+= 1
                state.samples = .empty
                return state.compositionGeneration
            }
            return AVVideoComposition(asset: asset) { request in
                let source = request.sourceImage
                let extent = source.extent
                box.sampleScopesIfNeeded(
                    from: source, compositionGeneration: compositionGeneration)
                let resolved = box.effects.withLock { $0 }
                let output: CIImage
                if resolved.needsComposition {
                    output = ImageEffectsCompositor.apply(to: source, effects: resolved)
                } else {
                    output = source
                }
                request.finish(with: output.cropped(to: extent), context: renderContext)
            }
        }

        /// Downsamples the decoded (pre-effect) frame into scope bins, throttled like live view.
        private func sampleScopesIfNeeded(
            from source: CIImage, compositionGeneration: UInt64
        ) {
            let ticket = scopeState.withLock { state -> ScopeSamplingTicket? in
                guard state.isActive, state.compositionGeneration == compositionGeneration else {
                    return nil
                }
                // Every composition frame (24–30 Hz) — playback scopes track the clip in
                // real time, matching the live scopes' ~30 Hz cadence.
                state.nextRequestSequence &+= 1
                return ScopeSamplingTicket(
                    activationGeneration: state.activationGeneration,
                    compositionGeneration: compositionGeneration,
                    requestSequence: state.nextRequestSequence)
            }
            guard let ticket else { return }
            // Render the scope tap in the ASSET's own transfer space (BT.709 for camera files),
            // not the composition's sRGB working space: AVFoundation converts 709->sRGB on decode,
            // and without undoing that here playback scopes read systematically different values
            // than live view (which samples raw JPEG codes). [1:1 live/playback invariant]
            guard
                let cgImage = MediaLUT.renderContext.createCGImage(
                    source, from: source.extent, format: .RGBA8,
                    colorSpace: FrameSampling.cameraFileColorSpace),
                let buffer = FrameSampling.rgbaBuffer(
                    from: UIImage(cgImage: cgImage), maxWidth: 200)
            else { return }
            let samples = ScopeSampler.sample(
                rgba: buffer.data, width: buffer.width, height: buffer.height,
                bytesPerRow: buffer.bytesPerRow,
                stride: ScopeAssistSampling.pointStride, includePoints: true)
            scopeState.withLock { state in
                guard state.isActive,
                    state.activationGeneration == ticket.activationGeneration,
                    state.compositionGeneration == ticket.compositionGeneration,
                    ticket.requestSequence > state.publishedRequestSequence
                else { return }
                state.publishedRequestSequence = ticket.requestSequence
                state.revision &+= 1
                state.samples = samples
            }
        }
    }

    /// Exports a clip to `Documents/exports/` with optional LUT bake and metadata sidecar.
    /// Runs off the main actor. `progress` (0…1) is `@Sendable`; the caller marshals it to the main actor.
    static func export(
        sourceURL: URL,
        outputFilename: String,
        format: MediaExportFormat,
        cube: CubeLUT?,
        metadata: MediaClipDeliveryMetadata?,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> ExportResult {
        let outputURL = try makeExportURL(filename: outputFilename, format: format)
        progress(0.02)
        trace(
            "export start source=\(sourceURL.lastPathComponent) format=\(format.rawValue) bake=\(cube != nil) dest=\(outputFilename)"
        )

        let truncated = mediaDataExtendsPastEndOfFile(at: sourceURL)
        if truncated {
            trace("source mdat extends past EOF; exporting readable media only")
        }
        let passthrough =
            cube == nil
            && !truncated
            && canPassthroughCopy(sourceURL: sourceURL, outputURL: outputURL, format: format)
        if passthrough {
            trace("export path=passthrough-copy")
            try FileManager.default.copyItem(at: sourceURL, to: outputURL)
            progress(0.9)
        } else {
            trace("export path=reader-writer")
            do {
                try await transcode(
                    sourceURL: sourceURL, outputURL: outputURL, format: format, cube: cube,
                    progress: progress)
            } catch {
                trace("transcode failed \(describe(error))")
                throw mappedExportError(error)
            }
        }

        try await ensureFileReady(at: outputURL)
        guard movieHasFinishedHeader(at: outputURL) else {
            trace("export missing moov header")
            throw ExportError.failed("export file is incomplete")
        }

        if !passthrough {
            await MediaTimecode.copySourceTimecodeTrack(
                from: sourceURL, to: outputURL, as: format.avFileType)
            if !movieHasFinishedHeader(at: outputURL) {
                trace("timecode embed left an incomplete movie")
                throw ExportError.failed("export file is incomplete")
            }
        }

        let metadataURL = try writeMetadataSidecar(metadata, nextTo: outputURL)
        progress(1.0)
        let size =
            (try? FileManager.default.attributesOfItem(atPath: outputURL.path)[.size] as? UInt64)
            ?? 0
        trace("export done file=\(outputURL.lastPathComponent) bytes=\(size)")
        return ExportResult(videoURL: outputURL, metadataURL: metadataURL)
    }

    /// Legacy entry point — bakes LUT into `{baseName}_LUT.mov`.
    static func export(
        sourceURL: URL,
        cube: CubeLUT,
        baseName: String,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> URL {
        let stem = (baseName as NSString).deletingPathExtension
        let result = try await export(
            sourceURL: sourceURL,
            outputFilename: "\(stem)_LUT.mov",
            format: .mov,
            cube: cube,
            metadata: nil,
            progress: progress
        )
        return result.videoURL
    }

    private static func canPassthroughCopy(
        sourceURL: URL, outputURL: URL, format: MediaExportFormat
    ) -> Bool {
        let sourceExt = sourceURL.pathExtension.lowercased()
        let targetExt = format.rawValue
        guard sourceExt == targetExt || (sourceExt == "m4v" && targetExt == "mp4") else {
            return false
        }
        return sourceURL.standardizedFileURL != outputURL.standardizedFileURL
    }

    /// Video+audio composition of `asset`, dropping `tmcd` and other data tracks.
    ///
    /// Nikon ZR proxies attach a per-frame QuickTime timecode track. Feeding that original asset
    /// to `AVAssetExportSession` fails on iOS with `AVErrorInvalidSampleCursor` (−11880), which
    /// is why native Share and Save to Photos both died on the same export path.
    static func audioVisualExportAsset(from asset: AVAsset) async throws -> AVMutableComposition {
        let composition = AVMutableComposition()
        let duration = try await asset.load(.duration)
        let videoTracks = try await asset.loadTracks(withMediaType: .video)
        let audioTracks = try await asset.loadTracks(withMediaType: .audio)
        let timecodeTracks = try await asset.loadTracks(withMediaType: .timecode)
        trace(
            "source tracks video=\(videoTracks.count) audio=\(audioTracks.count) tmcd=\(timecodeTracks.count) duration=\(duration.seconds)"
        )
        guard !videoTracks.isEmpty else { throw ExportError.sessionSetupFailed }

        for track in videoTracks {
            guard
                let dest = composition.addMutableTrack(
                    withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid)
            else { continue }
            do {
                try insert(
                    track, timeRange: try await track.load(.timeRange), into: dest,
                    fallbackDuration: duration)
                dest.preferredTransform = try await track.load(.preferredTransform)
            } catch {
                logger.error(
                    "video insert failed: \(describe(error), privacy: .public)")
                composition.removeTrack(dest)
            }
        }
        guard !(try await composition.loadTracks(withMediaType: .video)).isEmpty else {
            throw ExportError.sessionSetupFailed
        }

        for track in audioTracks {
            guard
                let dest = composition.addMutableTrack(
                    withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)
            else { continue }
            do {
                try insert(
                    track, timeRange: try await track.load(.timeRange), into: dest,
                    fallbackDuration: duration)
            } catch {
                logger.error(
                    "audio insert failed: \(describe(error), privacy: .public)")
                composition.removeTrack(dest)
            }
        }
        return composition
    }

    private static func insert(
        _ source: AVAssetTrack,
        timeRange: CMTimeRange,
        into dest: AVMutableCompositionTrack,
        fallbackDuration: CMTime
    ) throws {
        do {
            try dest.insertTimeRange(timeRange, of: source, at: .zero)
        } catch {
            try dest.insertTimeRange(
                CMTimeRange(start: .zero, duration: fallbackDuration), of: source, at: .zero)
        }
    }

    private static func transcode(
        sourceURL: URL,
        outputURL: URL,
        format: MediaExportFormat,
        cube: CubeLUT?,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws {
        // Device proof 2026-08-23: Nikon proxies can carry a complete `moov` whose `mdat`
        // was cut off (edit list + truncated media). `AVAssetReader` then throws
        // `AVErrorInvalidSampleCursor` (−11880) at the first missing sample. Treating that
        // as end-of-readable-media and calling `finishWriting` yields a playable file;
        // throwing leaves `mdat` size 0 and Photos/Share surface "Invalid sample cursor".
        progress(0.05)
        trace("reader/writer start")
        try await transcodeWithReaderWriter(
            sourceURL: sourceURL, outputURL: outputURL, format: format, cube: cube,
            progress: progress)
        trace("reader/writer completed")
        progress(0.95)
    }

    private static func isInvalidSampleCursor(_ error: Error) -> Bool {
        let ns = error as NSError
        return ns.domain == AVFoundationErrorDomain
            && ns.code == AVError.Code.invalidSampleCursor.rawValue
    }

    private static func mappedExportError(_ error: Error) -> Error {
        if isInvalidSampleCursor(error) {
            return ExportError.failed("this clip's media data is unreadable")
        }
        return error
    }

    private static func isEndOfReadableMedia(_ reader: AVAssetReader, samples: Int) -> Bool {
        switch reader.status {
        case .completed, .cancelled:
            return true
        case .failed:
            if let error = reader.error, isInvalidSampleCursor(error) {
                return true
            }
            return samples > 0
        default:
            return false
        }
    }

    /// `copyNextSampleBuffer` can block forever on a truncated `mdat`. Time out and cancel
    /// the reader so `finishWriting` can still emit a playable file.
    private static let sampleCopyQueue = DispatchQueue(
        label: "ozc.media-export.copy", attributes: .concurrent)

    private final class SampleCopyBox: @unchecked Sendable {
        var sample: CMSampleBuffer?
    }

    private static func copyNextSample(
        from output: AVAssetReaderTrackOutput,
        reader: AVAssetReader,
        timeout: TimeInterval = 8
    ) -> CMSampleBuffer? {
        let box = SampleCopyBox()
        let lock = DispatchSemaphore(value: 0)
        nonisolated(unsafe) let trackOutput = output
        sampleCopyQueue.async {
            box.sample = trackOutput.copyNextSampleBuffer()
            lock.signal()
        }
        if lock.wait(timeout: .now() + timeout) == .timedOut {
            reader.cancelReading()
            _ = lock.wait(timeout: .now() + 1)
            trace("copyNext timed out status=\(reader.status.rawValue)")
        }
        return box.sample
    }

    private static func transcodeWithReaderWriter(
        sourceURL: URL,
        outputURL: URL,
        format: MediaExportFormat,
        cube: CubeLUT?,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws {
        let asset = AVURLAsset(
            url: sourceURL, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
        guard let videoTrack = try await asset.loadTracks(withMediaType: .video).first else {
            throw ExportError.sessionSetupFailed
        }
        let audioTrack = try await asset.loadTracks(withMediaType: .audio).first
        let naturalSize = try await videoTrack.load(.naturalSize)
        let transform = try await videoTrack.load(.preferredTransform)
        // Encode in the track's coded size and stamp `preferredTransform`. Using the
        // display size *and* the transform double-rotates ZR proxies that carry ±90°.
        let width = max(16, Int(abs(naturalSize.width).rounded()))
        let height = max(16, Int(abs(naturalSize.height).rounded()))
        let duration = try await asset.load(.duration)
        let progressDuration = scaledProgressDuration(for: sourceURL, headerDuration: duration)
        trace(
            "reader tracks coded=\(width)x\(height) duration=\(duration.seconds) progressDuration=\(progressDuration.seconds) audio=\(audioTrack != nil)"
        )

        let videoReader = try AVAssetReader(asset: asset)
        let videoOutput = AVAssetReaderTrackOutput(
            track: videoTrack,
            outputSettings: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
            ])
        videoOutput.alwaysCopiesSampleData = true
        guard videoReader.canAdd(videoOutput) else { throw ExportError.sessionSetupFailed }
        videoReader.add(videoOutput)

        var audioReader: AVAssetReader?
        var audioOutput: AVAssetReaderTrackOutput?
        if let audioTrack {
            let reader = try AVAssetReader(asset: asset)
            let output = AVAssetReaderTrackOutput(
                track: audioTrack, outputSettings: audioPCMSettings())
            output.alwaysCopiesSampleData = true
            if reader.canAdd(output) {
                reader.add(output)
                audioReader = reader
                audioOutput = output
            }
        }

        let writer = try AVAssetWriter(outputURL: outputURL, fileType: format.avFileType)
        let videoInput = AVAssetWriterInput(
            mediaType: .video,
            outputSettings: [
                AVVideoCodecKey: AVVideoCodecType.h264,
                AVVideoWidthKey: width,
                AVVideoHeightKey: height,
            ])
        videoInput.expectsMediaDataInRealTime = false
        videoInput.transform = transform
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: videoInput,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: width,
                kCVPixelBufferHeightKey as String: height,
            ])
        guard writer.canAdd(videoInput) else { throw ExportError.sessionSetupFailed }
        writer.add(videoInput)

        var audioInput: AVAssetWriterInput?
        if audioOutput != nil, let audioTrack {
            let input = AVAssetWriterInput(
                mediaType: .audio, outputSettings: await audioAACSettings(for: audioTrack))
            input.expectsMediaDataInRealTime = false
            if writer.canAdd(input) {
                writer.add(input)
                audioInput = input
            }
        }

        guard writer.startWriting() else {
            throw writer.error ?? ExportError.sessionSetupFailed
        }
        guard videoReader.startReading() else {
            throw mappedExportError(videoReader.error ?? ExportError.sessionSetupFailed)
        }
        if let audioReader, !audioReader.startReading() {
            trace("audio reader skipped \(audioReader.error.map(describe) ?? "nil")")
            audioInput?.markAsFinished()
            audioInput = nil
            audioOutput = nil
        }

        let filter = cube.flatMap(colorCubeFilter(for:))
        let stats: ReaderWriterStats
        do {
            stats = try await appendReaderWriterSamples(
                videoReader: videoReader,
                videoOutput: videoOutput,
                videoInput: videoInput,
                adaptor: adaptor,
                audioReader: audioReader,
                audioOutput: audioOutput,
                audioInput: audioInput,
                writer: writer,
                filter: filter,
                duration: progressDuration,
                progress: progress)
        } catch {
            trace("pump threw \(describe(error)); cancelling writer")
            videoInput.markAsFinished()
            audioInput?.markAsFinished()
            writer.cancelWriting()
            throw error
        }

        videoInput.markAsFinished()
        audioInput?.markAsFinished()
        await writer.finishWriting()
        guard writer.status == .completed, stats.videoFrames > 0 else {
            trace(
                "writer failed status=\(writer.status.rawValue) video=\(stats.videoFrames) \(writer.error.map(describe) ?? "nil")"
            )
            try? FileManager.default.removeItem(at: outputURL)
            throw writer.error
                ?? mappedExportError(
                    videoReader.error ?? ExportError.failed("export"))
        }
        trace(
            "writer finished frames=\(stats.videoFrames) audio=\(stats.audioSamples) lastPTS=\(stats.lastVideoPTS.seconds) truncated=\(stats.endedEarly)"
        )
    }

    private static func colorCubeFilter(for cube: CubeLUT) -> CIFilter? {
        let prepared = cube.preparedForRenderer()
        let cubeData = prepared.rgbaComponents.withUnsafeBytes { Data($0) }
        return CIFilter(
            name: "CIColorCube",
            parameters: [
                "inputCubeDimension": prepared.size,
                "inputCubeData": cubeData,
            ])
    }

    private struct ReaderWriterStats {
        var videoFrames = 0
        var audioSamples = 0
        var lastVideoPTS = CMTime.zero
        var endedEarly = false
        var sessionStarted = false
    }

    private static func audioPCMSettings() -> [String: Any] {
        [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ]
    }

    private static func audioAACSettings(for track: AVAssetTrack) async -> [String: Any] {
        var sampleRate = 48_000.0
        var channels = 2
        if let format = try? await track.load(.formatDescriptions).first,
            let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(format)?.pointee
        {
            if asbd.mSampleRate > 0 { sampleRate = asbd.mSampleRate }
            if asbd.mChannelsPerFrame > 0 { channels = Int(asbd.mChannelsPerFrame) }
        }
        return [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: channels,
            AVEncoderBitRateKey: 192_000,
        ]
    }

    private static func appendReaderWriterSamples(
        videoReader: AVAssetReader,
        videoOutput: AVAssetReaderTrackOutput,
        videoInput: AVAssetWriterInput,
        adaptor: AVAssetWriterInputPixelBufferAdaptor,
        audioReader: AVAssetReader?,
        audioOutput: AVAssetReaderTrackOutput?,
        audioInput: AVAssetWriterInput?,
        writer: AVAssetWriter,
        filter: CIFilter?,
        duration: CMTime,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> ReaderWriterStats {
        var stats = ReaderWriterStats()
        var videoDone = false
        var audioDone = audioOutput == nil || audioInput == nil
        var idleSpins = 0
        while !videoDone || !audioDone {
            if Task.isCancelled {
                videoReader.cancelReading()
                audioReader?.cancelReading()
                writer.cancelWriting()
                throw CancellationError()
            }
            var progressed = false
            if !videoDone {
                let videoReady = videoInput.isReadyForMoreMediaData
                let videoReaderStopped =
                    videoReader.status == .failed || videoReader.status == .completed
                    || videoReader.status == .cancelled
                if videoReady {
                    if let sample = copyNextSample(from: videoOutput, reader: videoReader) {
                        startWriterSessionIfNeeded(
                            writer, stats: &stats,
                            at: CMSampleBufferGetPresentationTimeStamp(sample))
                        try appendVideoSample(sample, adaptor: adaptor, filter: filter)
                        stats.videoFrames += 1
                        stats.lastVideoPTS = CMSampleBufferGetPresentationTimeStamp(sample)
                        if duration.seconds > 0, stats.lastVideoPTS.seconds > 0 {
                            let fraction = stats.lastVideoPTS.seconds / duration.seconds
                            progress(min(0.9, 0.05 + 0.85 * fraction))
                        }
                        progressed = true
                    } else if isEndOfReadableMedia(videoReader, samples: stats.videoFrames) {
                        if videoReader.status == .failed {
                            stats.endedEarly = true
                            trace(
                                "video readable-end frames=\(stats.videoFrames) \(videoReader.error.map(describe) ?? "nil")"
                            )
                            progress(0.9)
                        }
                        videoDone = true
                        progressed = true
                    } else if videoReaderStopped {
                        videoDone = true
                        progressed = true
                    }
                } else if videoReaderStopped {
                    videoDone = true
                    progressed = true
                }
            }
            if !audioDone, let audioOutput, let audioInput, let audioReader {
                let audioReady = audioInput.isReadyForMoreMediaData
                let audioReaderStopped =
                    audioReader.status == .failed || audioReader.status == .completed
                    || audioReader.status == .cancelled
                if audioReady {
                    if let sample = copyNextSample(from: audioOutput, reader: audioReader) {
                        startWriterSessionIfNeeded(
                            writer, stats: &stats,
                            at: CMSampleBufferGetPresentationTimeStamp(sample))
                        if audioInput.append(sample) {
                            stats.audioSamples += 1
                            progressed = true
                        } else {
                            trace("audio append stopped \(writer.error.map(describe) ?? "nil")")
                            audioDone = true
                            progressed = true
                        }
                    } else if isEndOfReadableMedia(audioReader, samples: stats.audioSamples) {
                        if audioReader.status == .failed {
                            stats.endedEarly = true
                            trace(
                                "audio readable-end samples=\(stats.audioSamples) \(audioReader.error.map(describe) ?? "nil")"
                            )
                        }
                        audioDone = true
                        progressed = true
                    } else if audioReaderStopped {
                        audioDone = true
                        progressed = true
                    }
                } else if audioReaderStopped {
                    audioDone = true
                    progressed = true
                }
            }
            if writer.status == .failed {
                throw writer.error ?? ExportError.failed("export")
            }
            if !progressed {
                idleSpins += 1
                // Writer back-pressure plus a failed reader used to spin forever and
                // never `finishWriting`. After ~500ms with no progress, drop a stopped track.
                if idleSpins == 50 {
                    if !videoDone,
                        videoReader.status == .failed || videoReader.status == .completed
                    {
                        videoDone = true
                        stats.endedEarly = true
                        trace("video idle-stop frames=\(stats.videoFrames)")
                    }
                    if !audioDone,
                        let audioReader,
                        audioReader.status == .failed || audioReader.status == .completed
                    {
                        audioDone = true
                        stats.endedEarly = true
                        trace("audio idle-stop samples=\(stats.audioSamples)")
                    }
                }
                if idleSpins >= 500, stats.videoFrames > 0 {
                    videoDone = true
                    audioDone = true
                    stats.endedEarly = true
                    trace("idle timeout frames=\(stats.videoFrames) audio=\(stats.audioSamples)")
                }
                try await Task.sleep(for: .milliseconds(10))
            } else {
                idleSpins = 0
            }
        }
        if stats.videoFrames == 0 {
            throw mappedExportError(
                videoReader.error ?? ExportError.failed("this clip's media data is unreadable"))
        }
        return stats
    }

    private static func startWriterSessionIfNeeded(
        _ writer: AVAssetWriter, stats: inout ReaderWriterStats, at time: CMTime
    ) {
        guard !stats.sessionStarted else { return }
        writer.startSession(atSourceTime: time)
        stats.sessionStarted = true
    }

    private static func appendVideoSample(
        _ sample: CMSampleBuffer,
        adaptor: AVAssetWriterInputPixelBufferAdaptor,
        filter: CIFilter?
    ) throws {
        let timestamp = CMSampleBufferGetPresentationTimeStamp(sample)
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sample) else {
            throw ExportError.failed("video")
        }
        if let filter {
            let source = CIImage(cvPixelBuffer: pixelBuffer)
            filter.setValue(source.clampedToExtent(), forKey: kCIInputImageKey)
            let output = (filter.outputImage ?? source).cropped(to: source.extent)
            var rendered: CVPixelBuffer?
            if let pool = adaptor.pixelBufferPool {
                CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &rendered)
            }
            if rendered == nil {
                let width = CVPixelBufferGetWidth(pixelBuffer)
                let height = CVPixelBufferGetHeight(pixelBuffer)
                CVPixelBufferCreate(
                    kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA, nil, &rendered)
            }
            guard let rendered else { throw ExportError.failed("pixel buffer") }
            renderContext.render(output, to: rendered)
            if !adaptor.append(rendered, withPresentationTime: timestamp) {
                throw ExportError.failed("video")
            }
            return
        }
        if !adaptor.append(pixelBuffer, withPresentationTime: timestamp) {
            throw ExportError.failed("video")
        }
    }

    private static func makeExportURL(filename: String, format: MediaExportFormat) throws -> URL {
        let trimmed = filename.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw ExportError.invalidFilename }

        let exports = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("exports", isDirectory: true)
        try FileManager.default.createDirectory(at: exports, withIntermediateDirectories: true)

        var name = trimmed
        if (name as NSString).pathExtension.isEmpty {
            name = "\(name).\(format.rawValue)"
        }
        let url = exports.appendingPathComponent(name)
        try? FileManager.default.removeItem(at: url)
        return url
    }

    private static func writeMetadataSidecar(
        _ metadata: MediaClipDeliveryMetadata?, nextTo videoURL: URL
    ) throws -> URL? {
        guard let metadata else { return nil }
        let url = videoURL.deletingPathExtension().appendingPathExtension("meta.json")
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(metadata)
        try data.write(to: url, options: .atomic)
        return url
    }

    /// True when the file has a finished QuickTime/`moov` header, not just an open `mdat`.
    static func movieHasFinishedHeader(at url: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        let fileSize = (try? handle.seekToEnd()) ?? 0
        var offset: UInt64 = 0
        while offset + 8 <= fileSize {
            try? handle.seek(toOffset: offset)
            guard let sizeBytes = try? handle.read(upToCount: 4), sizeBytes.count == 4,
                let typeBytes = try? handle.read(upToCount: 4), typeBytes.count == 4
            else { return false }
            var atomSize = sizeBytes.reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
            let type = String(bytes: typeBytes, encoding: .ascii) ?? ""
            if atomSize == 1 {
                guard let ext = try? handle.read(upToCount: 8), ext.count == 8 else { return false }
                atomSize = ext.reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
            }
            if type == "moov" { return true }
            if atomSize < 8 || atomSize == 0 { return false }
            offset += atomSize
        }
        return false
    }

    /// True when an `mdat` atom's declared size runs past EOF — Nikon proxies (and partial
    /// caches) can ship a complete `moov` for more media than the file actually contains.
    static func mediaDataExtendsPastEndOfFile(at url: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        let fileSize = (try? handle.seekToEnd()) ?? 0
        var offset: UInt64 = 0
        while offset + 8 <= fileSize {
            try? handle.seek(toOffset: offset)
            guard let sizeBytes = try? handle.read(upToCount: 4), sizeBytes.count == 4,
                let typeBytes = try? handle.read(upToCount: 4), typeBytes.count == 4
            else { return false }
            var atomSize = sizeBytes.reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
            let type = String(bytes: typeBytes, encoding: .ascii) ?? ""
            if atomSize == 1 {
                guard let ext = try? handle.read(upToCount: 8), ext.count == 8 else { return false }
                atomSize = ext.reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
            }
            if type == "mdat", atomSize >= 8, offset + atomSize > fileSize {
                return true
            }
            if atomSize < 8 { return false }
            offset += atomSize
        }
        return false
    }

    /// Header duration scaled by how much of `mdat` is actually on disk.
    ///
    /// Nikon proxies can advertise a full clip duration while the file was cut off halfway
    /// through media data. Progress uses this so the bar isn't stuck at ~50% of a lying header.
    static func scaledProgressDuration(for url: URL, headerDuration: CMTime) -> CMTime {
        guard headerDuration.isNumeric, headerDuration.seconds > 0,
            let fraction = mdatAvailableFraction(at: url), fraction > 0, fraction < 0.98
        else { return headerDuration }
        return CMTimeMultiplyByFloat64(headerDuration, multiplier: fraction)
    }

    /// Available `mdat` payload / declared payload when the atom runs past EOF; otherwise `nil`.
    static func mdatAvailableFraction(at url: URL) -> Double? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        let fileSize = (try? handle.seekToEnd()) ?? 0
        var offset: UInt64 = 0
        while offset + 8 <= fileSize {
            try? handle.seek(toOffset: offset)
            guard let sizeBytes = try? handle.read(upToCount: 4), sizeBytes.count == 4,
                let typeBytes = try? handle.read(upToCount: 4), typeBytes.count == 4
            else { return nil }
            var atomSize = sizeBytes.reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
            let type = String(bytes: typeBytes, encoding: .ascii) ?? ""
            var header: UInt64 = 8
            if atomSize == 1 {
                guard let ext = try? handle.read(upToCount: 8), ext.count == 8 else { return nil }
                atomSize = ext.reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
                header = 16
            }
            if type == "mdat", atomSize >= header, offset + atomSize > fileSize {
                let declaredPayload = atomSize - header
                let available = fileSize - (offset + header)
                guard declaredPayload > 0 else { return nil }
                return Double(available) / Double(declaredPayload)
            }
            if atomSize < 8 { return nil }
            offset += atomSize
        }
        return nil
    }

    /// Waits briefly for AVFoundation / copy writes to become readable on disk.
    private static func ensureFileReady(at url: URL) async throws {
        for _ in 0..<20 {
            if FileManager.default.fileExists(atPath: url.path),
                let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
                let size = attrs[.size] as? UInt64, size > 0
            {
                return
            }
            try await Task.sleep(for: .milliseconds(25))
        }
        throw ExportError.failed("export file not available")
    }
}

/// Options passed from the delivery sheet into the Frame.io upload path.
struct MediaDeliveryUploadOptions: Sendable {
    let filename: String
    let bakeLUT: Bool
    let cube: CubeLUT?
    let metadata: MediaClipDeliveryMetadata?
    var forceReupload: Bool = false
}
