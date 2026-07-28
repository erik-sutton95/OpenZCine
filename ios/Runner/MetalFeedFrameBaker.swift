import CoreImage
@preconcurrency import Metal
import UIKit

/// Bakes monitor effects into a reusable Metal texture **off the main thread** for `MetalLiveView`.
///
/// Core Image filter graph construction and `CIContext.render` are CPU-heavy; confining them to a
/// dedicated queue keeps `MTKView.draw(in:)` to a fast scale + present on the main thread. The
/// texture is at the feed's own resolution — see ``bakeSize(source:drawable:)``.
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
        /// The drawable this bake was produced *for* — not the texture's own size. The texture is at
        /// source resolution cropped to that drawable's aspect (see ``bakeSize(source:drawable:)``),
        /// so the present scales it; matching on the drawable is what keeps a stale bake from a
        /// previous orientation off the screen.
        var drawableSize: CGSize = .zero
        var pixelFormat: MTLPixelFormat = .invalid
    }

    init(device: MTLDevice, fileStore: LUTFileStore) {
        self.device = device
        // SAFETY: `MetalLiveView` is only constructed when `FeedRenderMode.useMetal` succeeded.
        self.commandQueue = device.makeCommandQueue()!
        self.ciContext = CIContext(
            mtlCommandQueue: commandQueue,
            options: [
                // 8-bit, not half-float. The half-float working space was chosen to stop LUT
                // banding when the frame was read back and handed to a UIImageView; presenting
                // straight to an 8-bit panel removes that reason and halves the bandwidth of every
                // Core Image intermediate — which is the dominant per-frame cost. `MediaLUTExport`
                // deliberately stays at RGBAh: it writes files, where banding matters and a
                // millisecond does not.
                .workingFormat: CIFormat.BGRA8,
                .workingColorSpace: workingColorSpace,
                .cacheIntermediates: false,
            ])
        self.processor = LiveFrameProcessor(fileStore: fileStore)
        // Settle the fused-peaking self-check here rather than on the first peaking frame. It
        // renders both detector implementations once, which measured 486 ms on an iPhone — as a
        // one-off `graph` spike in the middle of a live stream, because a `static let` initialises
        // lazily at first use and first use is the bake thread. Off-thread at renderer construction
        // it lands long before any assist tool is switched on.
        Task.detached(priority: .utility) { _ = ImageEffectsCompositor.fusedPeakingAvailable }
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

    /// Returns the latest baked texture when it was produced for `drawableSize`, or `nil` until the
    /// first bake for that drawable lands.
    ///
    /// The texture is at **source** resolution cropped to the drawable's aspect, so the caller must
    /// scale it to present — its size is on the texture itself, and only its aspect is guaranteed to
    /// match the drawable.
    func bakedTexture(for drawableSize: CGSize, pixelFormat: MTLPixelFormat) -> MTLTexture? {
        stateLock.lock()
        defer { stateLock.unlock() }
        guard bakedState.drawableSize == drawableSize,
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

            // Crop, do not scale. The pre-scale that used to sit here is what made every Core Image
            // kernel evaluate at drawable resolution; see `bakeSize`.
            let extent = source.extent
            let bakeSize = Self.bakeSize(source: extent.size, drawable: drawableSize)
            let width = max(1, Int(bakeSize.width.rounded()))
            let height = max(1, Int(bakeSize.height.rounded()))
            // Centre the visible window on the source and put it at the texture origin, then flip:
            // Core Image's origin is bottom-left, a Metal texture's is top-left.
            let cropX = extent.origin.x + (extent.width - CGFloat(width)) / 2
            let cropY = extent.origin.y + (extent.height - CGFloat(height)) / 2
            let flipped =
                source
                .transformed(by: CGAffineTransform(translationX: -cropX, y: -cropY))
                .transformed(by: CGAffineTransform(scaleX: 1, y: -1))
                .transformed(by: CGAffineTransform(translationX: 0, y: CGFloat(height)))
            let bounds = CGRect(x: 0, y: 0, width: width, height: height)

            guard
                let renderTarget = renderTexture(
                    width: width, height: height, pixelFormat: pixelFormat),
                let commandBuffer = commandQueue.makeCommandBuffer()
            else {
                finished()
                return
            }

            ciContext.render(
                flipped, to: renderTarget, commandBuffer: commandBuffer,
                bounds: bounds, colorSpace: workingColorSpace)
            nonisolated(unsafe) let capturedTarget = renderTarget
            commandBuffer.addCompletedHandler { [self] _ in
                stateLock.lock()
                bakedState.texture = capturedTarget
                bakedState.drawableSize = drawableSize
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

    /// Pixel size of the bake target: the **source** resolution, cropped to the drawable's aspect.
    ///
    /// This used to be the drawable size, with an aspect-fill scale at the top of the Core Image
    /// graph. Core Image concatenates that scale into the samplers of the filters below it, so every
    /// kernel evaluated once per *drawable* pixel — ~2868×1320 of them to show a 1024×576 feed, a 6×
    /// overdraw that measured as a third of the app's CPU. Nothing about the image is defined at
    /// drawable resolution: every stage of `LiveFrameProcessor.outputCIImage` crops to the source
    /// extent, so the graph is a source-space function either way. Only the final upscale moves —
    /// out of Core Image and into the present, where it is one bilinear sample per pixel.
    ///
    /// Cropping rather than fitting is what keeps that present a single uniform scale, with no
    /// letterbox to fill and no aspect distortion. Two guards on the way out: a degenerate or
    /// infinite source extent falls back to the drawable, and a source that out-resolves the panel
    /// bakes at panel size — rendering more pixels than can be shown would make this slower than the
    /// path it replaces (the demo stills are the case that does this).
    static func bakeSize(source: CGSize, drawable: CGSize) -> CGSize {
        guard source.width.isFinite, source.height.isFinite,
            source.width > 0, source.height > 0,
            drawable.width > 0, drawable.height > 0
        else { return drawable }
        let drawableAspect = drawable.width / drawable.height
        let cropped =
            source.width / source.height > drawableAspect
            ? CGSize(width: source.height * drawableAspect, height: source.height)
            : CGSize(width: source.width, height: source.width / drawableAspect)
        return cropped.width > drawable.width ? drawable : cropped
    }
}
