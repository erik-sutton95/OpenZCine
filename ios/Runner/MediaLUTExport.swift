import AVFoundation
import CoreImage
import CoreMedia
import CoreVideo
import Foundation
import OpenCineApple
import OpenCineMedia
import OpenZCineCore
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

    /// Mutable effects holder for a single stable `AVVideoComposition` during clip playback.
    ///
    /// Assist toggles update the locked payload in place so AVFoundation keeps decoding without a
    /// compositor reset.
    ///
    /// Scope overlays sample the compositor's *source* frame (pre-LUT / pre-false-colour), matching
    /// live view which reads the raw JPEG — not `AVPlayerItemVideoOutput`, which reflects the graded
    /// presentation.
    final class PlaybackEffectsBox: @unchecked Sendable {
        struct ScopeSnapshot: Sendable {
            let revision: UInt64
            let samples: OpenCineMedia.ScopeSamples
        }

        private struct ScopeState: Sendable {
            var revision: UInt64 = 0
            var samples: OpenCineMedia.ScopeSamples = .empty
            var isActive = false
            /// The clip's transfer: the shared tap weighs luma by it, as live view does.
            var transfer = MonitorTransfer.rec709
            var activationGeneration: UInt64 = 0
            var compositionGeneration: UInt64 = 0
            var nextRequestSequence: UInt64 = 0
            var publishedRequestSequence: UInt64 = 0
        }

        private struct ScopeSamplingTicket: Sendable {
            let transfer: MonitorTransfer
            let activationGeneration: UInt64
            let compositionGeneration: UInt64
            let requestSequence: UInt64
        }

        private let effects = OSAllocatedUnfairLock<ImageEffectsCompositor.ResolvedEffects>(
            initialState: ImageEffectsCompositor.ResolvedEffects())
        private let scopeState = OSAllocatedUnfairLock<ScopeState>(initialState: ScopeState())
        /// The shared working raster the scope tap reads, as in live view.
        private let raster = MonitorWorkingRaster()

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

        func setScopesActive(_ active: Bool, transfer: MonitorTransfer = .rec709) {
            scopeState.withLock {
                if $0.isActive != active {
                    $0.activationGeneration &+= 1
                }
                $0.isActive = active
                $0.transfer = transfer
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
                    transfer: state.transfer,
                    activationGeneration: state.activationGeneration,
                    compositionGeneration: compositionGeneration,
                    requestSequence: state.nextRequestSequence)
            }
            guard let ticket else { return }
            // Render the scope tap in the ASSET's own transfer space (BT.709 for camera files),
            // not the composition's sRGB working space: AVFoundation converts 709->sRGB on decode,
            // and without undoing that here playback scopes read systematically different values
            // than live view (which samples raw JPEG codes). The tap is the shared engine's
            // (working raster, decimated 200-wide copy, the clip transfer's luma), so a clip
            // reads exactly as live view. [1:1 live/playback invariant]
            guard
                let cgImage = MediaLUT.renderContext.createCGImage(
                    source, from: source.extent, format: .RGBA8,
                    colorSpace: MonitorImageSampling.fileCodeColorSpace),
                let buffer = raster.prepared(cgImage),
                let tap = LiveFrameTap.copyBGRA8(
                    buffer, maxWidth: OpenCineMedia.ScopeSampler.maxWidth)
            else { return }
            let samples = OpenCineMedia.ScopeSampler.sampleRaw(
                bytes: tap.bytes, width: tap.width, height: tap.height,
                bytesPerRow: tap.bytesPerRow, transfer: ticket.transfer, includePoints: true)
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
        do {
            let result = try await MonitorReaderWriterMediaExporter.export(
                sourceURL: sourceURL,
                outputURL: outputURL,
                format: sharedFormat(format),
                cube: cube?.preparedForRenderer(),
                metadata: metadata,
                diagnostics: { trace($0) },
                timecodeDiagnostics: { traceTimecode($0) },
                progress: progress)
            return ExportResult(videoURL: result.videoURL, metadataURL: result.metadataURL)
        } catch let error as MonitorReaderWriterMediaExporter.ExportError {
            throw appExportError(error)
        }
    }

    static func audioVisualExportAsset(from asset: AVAsset) async throws -> AVMutableComposition {
        do {
            return try await MonitorReaderWriterMediaExporter.audioVisualExportAsset(
                from: asset, diagnostics: { traceComposition($0) })
        } catch let error as MonitorReaderWriterMediaExporter.ExportError {
            throw appExportError(error)
        }
    }

    private static let timecodeLogger = Logger(subsystem: "OpenZCine", category: "media-timecode")

    private static func traceTimecode(_ diagnostic: MonitorMovieTimecode.Diagnostic) {
        switch diagnostic.level {
        case .information: timecodeLogger.info("\(diagnostic.message, privacy: .public)")
        case .error: timecodeLogger.error("\(diagnostic.message, privacy: .public)")
        }
    }

    private static func traceComposition(_ message: String) {
        if message.hasPrefix("video insert failed:") || message.hasPrefix("audio insert failed:") {
            logger.error("\(message, privacy: .public)")
        } else {
            trace(message)
        }
    }

    private static func sharedFormat(_ format: MediaExportFormat)
        -> MonitorReaderWriterMediaExporter.Format
    {
        switch format {
        case .mov: .mov
        case .mp4: .mp4
        }
    }

    private static func appExportError(_ error: MonitorReaderWriterMediaExporter.ExportError)
        -> ExportError
    {
        switch error {
        case .sessionSetupFailed: .sessionSetupFailed
        case .failed(let reason): .failed(reason)
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
}

/// Options passed from the delivery sheet into the Frame.io upload path.
struct MediaDeliveryUploadOptions: Sendable {
    let filename: String
    let bakeLUT: Bool
    let cube: CubeLUT?
    let metadata: MediaClipDeliveryMetadata?
    var forceReupload: Bool = false
}
