import AVFoundation
import CoreImage
import Foundation
import UIKit
import os

/// LUT baking for media playback preview and export. Builds the same `CIColorCube` pipeline the live
/// view uses (`cube.rgbaComponents` + `inputCubeDimension`, display-encoded sRGB working space,
/// 16-bit half-float intermediates) and applies it either as a playback `AVVideoComposition`
/// (preview) or baked into a new file via `AVAssetExportSession` (export).
enum MediaLUT {
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
        let dimension = cube.size
        let cubeData = cube.rgbaComponents.withUnsafeBytes { Data($0) }
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

        let passthrough =
            cube == nil
            && canPassthroughCopy(sourceURL: sourceURL, outputURL: outputURL, format: format)
        if passthrough {
            try FileManager.default.copyItem(at: sourceURL, to: outputURL)
            progress(0.9)
        } else {
            try await transcode(
                sourceURL: sourceURL, outputURL: outputURL, format: format, cube: cube,
                progress: progress)
        }

        try await ensureFileReady(at: outputURL)

        if !passthrough {
            // The export session drops the camera's tmcd track; restore it from the source so
            // Frame.io and NLEs keep the R3D NE / N-RAW master's start timecode.
            await MediaTimecode.copySourceTimecodeTrack(
                from: sourceURL, to: outputURL, as: format.avFileType)
        }

        let metadataURL = try writeMetadataSidecar(metadata, nextTo: outputURL)
        progress(1.0)
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

    private static func transcode(
        sourceURL: URL,
        outputURL: URL,
        format: MediaExportFormat,
        cube: CubeLUT?,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws {
        let asset = AVURLAsset(url: sourceURL)
        guard
            let session = AVAssetExportSession(
                asset: asset, presetName: AVAssetExportPresetHighestQuality)
        else { throw ExportError.sessionSetupFailed }

        if let cube {
            session.videoComposition = videoComposition(for: asset, cube: cube)
        }
        progress(0.05)

        let reporter = ExportProgressReporter(session: session, report: progress)
        let progressTask = Task { await reporter.poll() }
        defer { progressTask.cancel() }

        if #available(iOS 18, *) {
            try await session.export(to: outputURL, as: format.avFileType)
        } else {
            session.outputURL = outputURL
            session.outputFileType = format.avFileType
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
                nonisolated(unsafe) let exportSession = session
                exportSession.exportAsynchronously {
                    if exportSession.status == .completed {
                        cont.resume()
                    } else {
                        cont.resume(throwing: exportSession.error ?? ExportError.failed("export"))
                    }
                }
            }
        }
        progress(0.95)
    }

    /// Polls `AVAssetExportSession.progress` during transcode without crossing Swift 6 sendability.
    private final class ExportProgressReporter: @unchecked Sendable {
        private let session: AVAssetExportSession
        private let report: @Sendable (Double) -> Void

        init(session: AVAssetExportSession, report: @escaping @Sendable (Double) -> Void) {
            self.session = session
            self.report = report
        }

        func poll() async {
            while !Task.isCancelled {
                let exportProgress = Double(session.progress)
                if exportProgress > 0 {
                    report(0.05 + exportProgress * 0.85)
                }
                try? await Task.sleep(for: .milliseconds(180))
            }
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
