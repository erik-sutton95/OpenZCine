import CoreImage
@preconcurrency import Metal
import OpenCineApple
import UIKit
import os

/// Source calibration and diagnostic adapter; shared native runtime owns bake work and targets.
final class MetalFeedFrameBaker: @unchecked Sendable {
    let native: MonitorFrameBaker
    /// Accessed only by the native baker's serial preparation queue.
    private let processor: LiveFrameProcessor
    private var lastCropSignature: String?

    init(device: MTLDevice, fileStore: LUTFileStore) {
        native = MonitorFrameBaker(
            device: device, workingSpace: .encodedSRGB,
            scheduling: .waitForGPUCompletion, unavailableTarget: .drop)
        processor = LiveFrameProcessor(fileStore: fileStore)
        Task.detached(priority: .utility) { _ = ImageEffectsCompositor.fusedPeakingAvailable }
    }

    func scheduleBake(
        image: UIImage, effects: LiveImageEffects, drawableSize: CGSize,
        pixelFormat: MTLPixelFormat, source: LiveFrameSampleBus.Source? = nil,
        onComplete: (@Sendable () -> Void)? = nil
    ) {
        nonisolated(unsafe) let capturedImage = image
        native.scheduleBake(
            preparing: { [self] in
                let source =
                    effects.isIdentity
                    ? CIImage(image: capturedImage)
                    : processor.outputCIImage(for: capturedImage, effects: effects)
                guard let source else { return nil }
                let extent = source.extent
                // #115 witness: with fit semantics an aspect disagreement now shows as bars in the
                // present rather than lost frame edges, but it still means a layout upstream lied
                // about the aspect — one line per signature says which numbers disagree.
                if extent.height > 0, drawableSize.height > 0 {
                    let sourceAspect = extent.width / extent.height
                    let drawableAspect = drawableSize.width / drawableSize.height
                    let signature =
                        "\(Int(extent.width))x\(Int(extent.height))->"
                        + "\(Int(drawableSize.width))x\(Int(drawableSize.height))"
                    if abs(sourceAspect / drawableAspect - 1) > 0.02,
                        signature != lastCropSignature
                    {
                        lastCropSignature = signature
                        Logger(subsystem: "com.opencapture.openzcine", category: "metal-feed")
                            .warning(
                                "metal feed letterboxing \(signature, privacy: .public): source aspect \(String(format: "%.3f", sourceAspect), privacy: .public) vs drawable \(String(format: "%.3f", drawableAspect), privacy: .public)"
                            )
                    }
                }
                return source
            }, drawableSize: drawableSize, pixelFormat: pixelFormat, unmanaged: false,
            source: source.map { MonitorFrameBakeSource(lease: $0) },
            onComplete: {
                if let onComplete { DispatchQueue.main.async(execute: onComplete) }
            })
    }

    func acquireFrame(for drawableSize: CGSize, pixelFormat: MTLPixelFormat) -> MonitorFrameBaker
        .Frame?
    {
        native.acquireFrame(for: drawableSize, pixelFormat: pixelFormat)
    }
    func bakedTexture(for drawableSize: CGSize, pixelFormat: MTLPixelFormat) -> MTLTexture? {
        native.bakedTexture(for: drawableSize, pixelFormat: pixelFormat)
    }
    func releaseBakedTexture(_ texture: MTLTexture) { native.releaseBakedTexture(texture) }
    func reset() { native.reset() }
    func close() { native.close() }
    static func bakeSize(source: CGSize, drawable: CGSize) -> CGSize {
        MonitorFrameBaker.bakeSize(source: source, drawable: drawable)
    }
}
