import UIKit

/// Bakes monitor analysis effects (LUT, peaking, zebra, false colour) **off the main actor**.
///
/// Core Image's `createCGImage` readback is expensive; confining `LiveFrameProcessor` to this actor
/// keeps that work off the UI thread while the streaming loop awaits each bake.
actor LiveFrameRenderer {
    private let processor: LiveFrameProcessor

    init(fileStore: LUTFileStore) {
        processor = LiveFrameProcessor(fileStore: fileStore)
    }

    /// Returns `image` with `effects` baked in, or unchanged when nothing is active.
    func render(_ image: UIImage, effects: LiveImageEffects) -> sending UIImage {
        // The opt-in Metal feed bakes assists off-main in `MetalFeedFrameBaker` — never read back to CPU.
        guard !FeedRenderMode.metalFeedEnabled else {
            processor.evictRenderCache()
            return image
        }
        return autoreleasepool { processor.render(image, effects: effects) }
    }

    /// Bakes a static/demo frame for the UIImageView fallback even when Metal was selected at
    /// launch. Unlike ``render(_:effects:)``, this explicit fallback must not return the raw source.
    func renderStaticFrame(_ image: UIImage, effects: LiveImageEffects) -> sending UIImage {
        autoreleasepool { processor.render(image, effects: effects) }
    }

    /// Releases the baked-frame memo so the streaming loop does not retain two full-resolution
    /// bitmaps (input + output) across frame boundaries.
    func evictCachedRender() {
        processor.evictRenderCache()
    }

    /// Evicts the prior frame's memo and bakes `effects` into `image` in **one** actor hop — the
    /// streaming loop calls this per displayed frame, and two round-trips per frame at ~30 fps is
    /// measurable scheduler overhead.
    func renderReplacingCache(_ image: UIImage, effects: LiveImageEffects) -> sending UIImage {
        processor.evictRenderCache()
        guard !FeedRenderMode.metalFeedEnabled else { return image }
        return autoreleasepool { processor.render(image, effects: effects) }
    }
}
