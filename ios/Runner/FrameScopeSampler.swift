import UIKit

/// Samples a live-view JPEG frame into scope data (per-channel histograms + waveform/parade points)
/// **off the main actor**.
///
/// The previous path ran the `CGContext` downsample + the per-pixel `ScopeSampler` loop on the
/// `@MainActor` model. Here a single long-lived actor does that work off-main and returns the
/// `Sendable` `ScopeSamples`; the serial streaming loop just `await`s it. Decoding the JPEG again
/// (rather than reusing the display image) avoids sending a non-`Sendable` `UIImage` across the actor
/// boundary, and the cost is bounded — scopes sample at most ~12 Hz and only when a scope is
/// shown. The GPU path (`MPSImageHistogram` + an additive-blend scatter) supersedes this entirely —
/// see `docs/design/plans/2026-06-29-gpu-acceleration-design.md`.
actor FrameScopeSampler {
    /// Samples a decoded live-view frame (no JPEG re-decode).
    func sample(
        from image: UIImage, maxWidth: Int, stride: Int, includePoints: Bool = true
    ) -> ScopeSamples {
        autoreleasepool {
            guard let buffer = FrameSampling.rgbaBuffer(from: image, maxWidth: maxWidth)
            else { return .empty }
            return ScopeSampler.sample(
                rgba: buffer.data, width: buffer.width, height: buffer.height,
                bytesPerRow: buffer.bytesPerRow, stride: stride, includePoints: includePoints)
        }
    }

    func sample(
        _ jpeg: Data, maxWidth: Int, stride: Int, includePoints: Bool = true
    ) -> ScopeSamples {
        autoreleasepool {
            guard let image = UIImage(data: jpeg) else { return .empty }
            return sample(
                from: image, maxWidth: maxWidth, stride: stride, includePoints: includePoints)
        }
    }
}
