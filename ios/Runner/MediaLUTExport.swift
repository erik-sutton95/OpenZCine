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

/// The playback look: builds the same `CIColorCube` pipeline the live view uses
/// (`cube.rgbaComponents` + `inputCubeDimension`, display-encoded sRGB working space, 16-bit
/// half-float intermediates) as a playback `AVVideoComposition`. Exports are the shared
/// delivery owner's (`NikonMediaDeliveryCapture.export`).
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
                    colorSpace: MonitorImageSampling.fileCodeColorSpace),
                let buffer = MonitorImageSampling.rgbaBuffer(
                    from: UIImage(cgImage: cgImage), maxWidth: 200)
            else { return }
            let samples = OpenCineMedia.ScopeSampler.sampleRaw(
                bytes: buffer.data, width: buffer.width, height: buffer.height,
                bytesPerRow: buffer.bytesPerRow, transfer: .rec709, includePoints: true,
                layout: .rgba, stride: ScopeAssistSampling.pointStride,
                includeSampleCoordinates: true, requireCompleteRows: true)
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
}
