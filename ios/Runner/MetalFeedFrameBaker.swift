import CoreImage
@preconcurrency import Metal
import UIKit

/// Bakes monitor effects into a reusable Metal texture **off the main thread** for `MetalLiveView`.
///
/// Core Image filter graph construction and `CIContext.render` are CPU-heavy; confining them to a
/// dedicated queue keeps `MTKView.draw(in:)` to a fast blit + present on the main thread.
final class MetalFeedFrameBaker: @unchecked Sendable {
    private struct BakeRequest {
        let image: UIImage
        let effects: LiveImageEffects
        let drawableSize: CGSize
        let pixelFormat: MTLPixelFormat
    }

    private let device: MTLDevice
    private let commandQueue: MTLCommandQueue
    private let ciContext: CIContext
    private let processor: LiveFrameProcessor
    private let workQueue = DispatchQueue(label: "OpenZCine.metal-feed-bake", qos: .userInitiated)
    private let stateLock = NSLock()
    private var bakedState = BakedState()
    private var pendingRequest: BakeRequest?
    private var pendingOnComplete: (@Sendable () -> Void)?
    private var workerBusy = false
    private let workingColorSpace =
        CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
    private var ciRenderTexture: MTLTexture?

    private struct BakedState {
        var texture: MTLTexture?
        var width: Int = 0
        var height: Int = 0
        var pixelFormat: MTLPixelFormat = .invalid
    }

    init(device: MTLDevice, fileStore: LUTFileStore) {
        self.device = device
        // SAFETY: `MetalLiveView` is only constructed when `FeedRenderMode.useMetal` succeeded.
        self.commandQueue = device.makeCommandQueue()!
        self.ciContext = CIContext(
            mtlCommandQueue: commandQueue,
            options: [
                .workingFormat: CIFormat.RGBAh,
                .workingColorSpace: workingColorSpace,
                .cacheIntermediates: false,
            ])
        self.processor = LiveFrameProcessor(fileStore: fileStore)
    }

    /// Queues a GPU bake for `image` at the drawable size. Safe to call from the main thread every frame.
    /// Coalesces to the latest frame when the worker is behind — stale bakes are dropped, not queued.
    func scheduleBake(
        image: UIImage, effects: LiveImageEffects, drawableSize: CGSize,
        pixelFormat: MTLPixelFormat,
        onComplete: (@Sendable () -> Void)? = nil
    ) {
        guard drawableSize.width > 0, drawableSize.height > 0 else { return }
        stateLock.lock()
        pendingRequest = BakeRequest(
            image: image, effects: effects, drawableSize: drawableSize, pixelFormat: pixelFormat)
        pendingOnComplete = onComplete
        let shouldStart = !workerBusy
        if shouldStart { workerBusy = true }
        stateLock.unlock()
        if shouldStart {
            workQueue.async { [self] in self.runNextBake() }
        }
    }

    /// Returns the latest baked texture when it matches the drawable, or `nil` until the first bake lands.
    func bakedTexture(width: Int, height: Int, pixelFormat: MTLPixelFormat) -> MTLTexture? {
        stateLock.lock()
        defer { stateLock.unlock() }
        guard bakedState.width == width,
            bakedState.height == height,
            bakedState.pixelFormat == pixelFormat
        else { return nil }
        return bakedState.texture
    }

    private func runNextBake() {
        stateLock.lock()
        guard let request = pendingRequest else {
            workerBusy = false
            stateLock.unlock()
            return
        }
        pendingRequest = nil
        let onComplete = pendingOnComplete
        pendingOnComplete = nil
        stateLock.unlock()

        bake(request: request) { [self] in
            if let onComplete {
                DispatchQueue.main.async(execute: onComplete)
            }
            workQueue.async { [self] in self.runNextBake() }
        }
    }

    private func bake(request: BakeRequest, finished: @escaping @Sendable () -> Void) {
        autoreleasepool {
            let drawableSize = request.drawableSize
            let pixelFormat = request.pixelFormat
            let width = max(1, Int(drawableSize.width))
            let height = max(1, Int(drawableSize.height))
            guard
                let renderTarget = renderTexture(
                    width: width, height: height, pixelFormat: pixelFormat),
                let commandBuffer = commandQueue.makeCommandBuffer()
            else {
                finished()
                return
            }

            let source: CIImage?
            if request.effects.isIdentity {
                source = CIImage(image: request.image)
            } else {
                source = processor.outputCIImage(for: request.image, effects: request.effects)
            }
            guard let source else {
                finished()
                return
            }

            let scaled = Self.aspectFill(source, into: drawableSize)
            let flipped =
                scaled
                .transformed(by: CGAffineTransform(scaleX: 1, y: -1))
                .transformed(by: CGAffineTransform(translationX: 0, y: drawableSize.height))
            let bounds = CGRect(x: 0, y: 0, width: width, height: height)
            ciContext.render(
                flipped, to: renderTarget, commandBuffer: commandBuffer,
                bounds: bounds, colorSpace: workingColorSpace)
            nonisolated(unsafe) let capturedTarget = renderTarget
            commandBuffer.addCompletedHandler { [self] _ in
                stateLock.lock()
                bakedState.texture = capturedTarget
                bakedState.width = width
                bakedState.height = height
                bakedState.pixelFormat = pixelFormat
                stateLock.unlock()
                finished()
            }
            commandBuffer.commit()
        }
    }

    private func renderTexture(width: Int, height: Int, pixelFormat: MTLPixelFormat) -> MTLTexture?
    {
        if let existing = ciRenderTexture,
            existing.width == width,
            existing.height == height,
            existing.pixelFormat == pixelFormat
        {
            return existing
        }
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: pixelFormat, width: width, height: height, mipmapped: false)
        descriptor.usage = [.shaderRead, .shaderWrite, .renderTarget]
        descriptor.storageMode = .private
        guard let texture = device.makeTexture(descriptor: descriptor) else { return nil }
        ciRenderTexture = texture
        return texture
    }

    /// Scales and centres `image` to cover `size` — aspect-fill, centred.
    private static func aspectFill(_ image: CIImage, into size: CGSize) -> CIImage {
        let extent = image.extent
        guard extent.width > 0, extent.height > 0, size.width > 0, size.height > 0 else {
            return image
        }
        let scale = max(size.width / extent.width, size.height / extent.height)
        let scaled = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let dx = (size.width - scaled.extent.width) / 2 - scaled.extent.origin.x
        let dy = (size.height - scaled.extent.height) / 2 - scaled.extent.origin.y
        return scaled.transformed(by: CGAffineTransform(translationX: dx, y: dy))
    }
}
