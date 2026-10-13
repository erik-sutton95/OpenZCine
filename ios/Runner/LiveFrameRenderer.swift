import CoreImage
import OpenCineMedia
import UIKit

import class OpenCineCameraVocabulary.CustomLUTStore

/// Bakes monitor analysis effects (LUT, peaking, zebra, false colour) **off the main actor**.
///
/// Core Image's `createCGImage` readback is expensive; confining `LiveFrameProcessor` to this actor
/// keeps that work off the UI thread while the streaming loop awaits each bake.
actor LiveFrameRenderer {
    private let processor: LiveFrameProcessor
    private let previewContext = CIContext(options: [
        .workingFormat: CIFormat.BGRA8,
        .workingColorSpace: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
        .cacheIntermediates: false,
    ])

    init(fileStore: CustomLUTStore) {
        processor = LiveFrameProcessor(fileStore: fileStore)
    }

    /// Bakes a static/demo frame for the UIImageView fallback even when Metal was selected at
    /// launch. Unlike ``renderReplacingCache(_:effects:)``, this explicit fallback must not return
    /// the raw source.
    func renderStaticFrame(_ image: UIImage, effects: LiveImageEffects) -> sending UIImage {
        autoreleasepool { processor.render(image, effects: effects) }
    }

    /// Uses the native calibrated graph at source resolution, then bounds its readback.
    func renderInspectorFrame(_ image: UIImage, effects: LiveImageEffects) -> CGImage? {
        autoreleasepool {
            guard let input = CIImage(image: image, options: [.colorSpace: NSNull()]),
                !input.extent.isEmpty
            else { return nil }
            let output: CIImage
            if effects.isIdentity {
                output = input
            } else {
                guard let rendered = processor.outputInspectorCIImage(for: image, effects: effects)
                else {
                    return nil
                }
                output = rendered
            }
            let extent = output.extent
            let scale = min(
                1,
                CGFloat(MonitorInspectorImageSizing.maximumDimension)
                    / max(extent.width, extent.height))
            let fitted = output.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
            guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
            return previewContext.createCGImage(
                fitted, from: fitted.extent, format: .RGBA8, colorSpace: colorSpace)
        }
    }

    /// Releases the baked-frame memo so the streaming loop does not retain two full-resolution
    /// bitmaps (input + output) across frame boundaries.
    func evictCachedRender() {
        processor.evictRenderCache()
    }

    /// Evicts the prior frame's memo and bakes `effects` into `image` in **one** actor hop - the
    /// streaming loop calls this per displayed frame, and two round-trips per frame at ~30 fps is
    /// measurable scheduler overhead.
    func renderReplacingCache(_ image: UIImage, effects: LiveImageEffects) -> sending UIImage {
        processor.evictRenderCache()
        guard !FeedRenderMode.metalFeedEnabled else { return image }
        return autoreleasepool { processor.render(image, effects: effects) }
    }
}
