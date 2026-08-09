import CoreImage
@preconcurrency import Metal
import UIKit
import os

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
    /// Last aspect-mismatch witness logged (#115) — one line per source→drawable signature.
    private var lastCropSignature: String?
    private var pendingOnComplete: (@Sendable () -> Void)?
    private var workerBusy = false
    private let workingColorSpace =
        CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
    /// Bake targets, cycled — never one texture.
    ///
    /// The present samples the published texture on the main thread while the baker renders the
    /// NEXT frame on its own queue, and the two command buffers have no ordering between them. A
    /// single reused target therefore let the baker overwrite the very texture the present was
    /// mid-scale on: rare, one frame, and visible as a flash. Cycling means the texture being
    /// written is never the one just handed out.
    ///
    /// Three deep to match the drawable queue — a present's command buffer can still be in flight
    /// a frame or two after `draw(in:)` returned, so two would leave the oldest at risk.
    ///
    /// Depth alone is a probability, not a guarantee: three bakes completing inside one present's
    /// command buffer bring the cycle back round to the texture that present is still reading. So
    /// the present holds the texture it was handed and returns it on completion, and a bake never
    /// takes a held one — see `retainedTextures` and ``releaseBakedTexture(_:)``.
    private var ciRenderTextures: [MTLTexture] = []
    private var nextRenderTexture = 0
    /// How many presents are still reading each cycled target, keyed by identity. A target with a
    /// non-zero count is off limits to the baker until every present that took it has completed.
    private var retainedTextures: [ObjectIdentifier: Int] = [:]

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
    /// The returned texture is RETAINED against reuse until the caller hands it back with
    /// ``releaseBakedTexture(_:)`` — which must happen on every path, including the ones that give
    /// up before presenting.
    func bakedTexture(for drawableSize: CGSize, pixelFormat: MTLPixelFormat) -> MTLTexture? {
        stateLock.lock()
        defer { stateLock.unlock() }
        guard bakedState.drawableSize == drawableSize,
            bakedState.pixelFormat == pixelFormat,
            let texture = bakedState.texture
        else { return nil }
        retainedTextures[ObjectIdentifier(texture), default: 0] += 1
        return texture
    }

    /// Releases a texture taken from ``bakedTexture(for:pixelFormat:)``, freeing it for reuse.
    ///
    /// Call from the present command buffer's completion handler, not when `draw(in:)` returns:
    /// the GPU is still sampling the texture after that.
    func releaseBakedTexture(_ texture: MTLTexture) {
        let key = ObjectIdentifier(texture)
        stateLock.lock()
        defer { stateLock.unlock() }
        guard let count = retainedTextures[key] else { return }
        if count <= 1 {
            retainedTextures[key] = nil
        } else {
            retainedTextures[key] = count - 1
        }
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

            // Fit, never crop (see `bakeSize`): the bake keeps the source's own aspect, at the
            // source's own resolution unless the drawable is smaller. In the matched-aspect
            // common case the scale below is 1 and this is exactly the old crop-free path —
            // Core Image kernels still evaluate at source resolution.
            let extent = source.extent
            let bakeSize = Self.bakeSize(source: extent.size, drawable: drawableSize)
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
            let width = max(1, Int(bakeSize.width.rounded()))
            let height = max(1, Int(bakeSize.height.rounded()))
            // Normalize the origin, scale to the bake size, then flip: Core Image's origin is
            // bottom-left, a Metal texture's is top-left.
            let scaleX = CGFloat(width) / extent.width
            let scaleY = CGFloat(height) / extent.height
            let flipped =
                source
                .transformed(
                    by: CGAffineTransform(
                        translationX: -extent.origin.x, y: -extent.origin.y)
                )
                .transformed(by: CGAffineTransform(scaleX: scaleX, y: scaleY))
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

    /// Picks this bake's target. Locked: `retainedTextures` is written by the present's thread and
    /// by command-buffer completion handlers, while this runs on the bake worker.
    private func renderTexture(width: Int, height: Int, pixelFormat: MTLPixelFormat) -> MTLTexture?
    {
        stateLock.lock()
        defer { stateLock.unlock() }
        let matches =
            ciRenderTextures.count == Self.bakeTextureDepth
            && ciRenderTextures.allSatisfy {
                $0.width == width && $0.height == height && $0.pixelFormat == pixelFormat
            }
        if !matches {
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: pixelFormat, width: width, height: height, mipmapped: false)
            descriptor.usage = [.shaderRead, .shaderWrite, .renderTarget]
            descriptor.storageMode = .private
            let built = (0..<Self.bakeTextureDepth).compactMap { _ in
                device.makeTexture(descriptor: descriptor)
            }
            guard built.count == Self.bakeTextureDepth else { return nil }
            ciRenderTextures = built
            nextRenderTexture = 0
            // The old targets are gone from the cycle, but a present handed one before the resize
            // still holds it and still has to be able to give it back.
            retainedTextures = retainedTextures.filter { key, _ in
                ciRenderTextures.contains { ObjectIdentifier($0) == key }
            }
        }
        // Take the next FREE target rather than the next one: a held target is still being read
        // by a present, and writing it is exactly the flash this cycle exists to prevent. When all
        // three are held the bake is dropped, which shows the last good frame for another beat —
        // the right failure, and one the caller already handles.
        for offset in 0..<ciRenderTextures.count {
            let index = (nextRenderTexture + offset) % ciRenderTextures.count
            let texture = ciRenderTextures[index]
            if retainedTextures[ObjectIdentifier(texture)] == nil {
                nextRenderTexture = index + 1
                return texture
            }
        }
        return nil
    }

    /// How many bake targets cycle. Matches the drawable queue's depth — see `ciRenderTextures`.
    private static let bakeTextureDepth = 3

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
        // The upper bound is Metal's own maximum texture dimension: a wider "source" is a CI
        // generator's unbounded extent (CGRect.infinite's size is greatestFiniteMagnitude —
        // FINITE, so `isFinite` alone misses it), not a picture.
        guard source.width.isFinite, source.height.isFinite,
            source.width > 0, source.height > 0,
            source.width <= 16_384, source.height <= 16_384,
            drawable.width > 0, drawable.height > 0
        else { return drawable }
        // FIT, never crop: the bake keeps the source's OWN aspect, downscale-bounded by the
        // drawable so an out-resolving source stays as cheap as the crop it replaces. The
        // present letterboxes the result into the drawable — so a frame/aspect disagreement
        // anywhere upstream shows as bars, never as lost frame edges (#115: the operator is
        // judging framing, and the old crop-to-drawable silently ate a DCI-4K signal's sides).
        let scale = min(drawable.width / source.width, drawable.height / source.height, 1)
        let fitted = CGSize(width: source.width * scale, height: source.height * scale)
        // A source so degenerate it fits below a pixel (CGRect.infinite's size is
        // greatestFiniteMagnitude — FINITE, so the guard above misses it) falls back too.
        guard fitted.width >= 1, fitted.height >= 1 else { return drawable }
        return fitted
    }
}
