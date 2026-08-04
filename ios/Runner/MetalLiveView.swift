import Metal
import MetalKit
import MetalPerformanceShaders
import SwiftUI
import UIKit
import os

// MetalFX is a device-only framework — there is no `MetalFX.framework` in the iOS Simulator SDK,
// so an unconditional import breaks `just ios-build` and `just ios-test`. Every use below is behind
// the same check, with a `false`-returning stub for the simulator that routes to Lanczos.
#if canImport(MetalFX)
    import MetalFX
#endif

/// Selects the live-view feed renderer. GPU-native `MetalLiveView` by default, falling back to the
/// `UIImageView` path (`LiveFrameView`) on any device without Metal or after a render failure.
///
/// This used to be off unless `ZC_METAL_FEED=1` was set, on the reasoning that an unvalidated GPU
/// path must never regress the shipping feed. What that reasoning missed is the cost of the path it
/// was protecting: the `UIImageView` route reads every rendered frame back off the GPU as `RGBAh`,
/// eight bytes a pixel — roughly 4.7 MB per frame and 140 MB/s at 30 fps — only for SwiftUI to
/// upload it again to display. Measured on an iPhone 16 Pro Max that pipeline ran 35.4 ms of CPU
/// against 2.5 ms of GPU per frame and held 28 fps with the energy gauge in the red. Being careful
/// about the new path was costing more than the risk it avoided.
///
/// `ZC_DEMO_CPU_FEED=1` forces the old path back for an A/B or if the GPU route ever misbehaves;
/// ``disableMetalFeed(_:)`` does the same automatically and permanently after a render failure.
enum FeedRenderMode {
    static let useMetal: Bool =
        !DemoHarness.forceCPUFeed && MTLCreateSystemDefaultDevice() != nil

    private static let metalFeedEnabledState = OSAllocatedUnfairLock(initialState: true)

    /// Runtime gate for the Metal feed — stays off after a persistent render failure so the app
    /// falls back to `LiveFrameView` without per-frame `CIRenderDestination` error spam.
    static var metalFeedEnabled: Bool {
        useMetal && metalFeedEnabledState.withLock { $0 }
    }

    /// Disables the Metal feed for the rest of the process (logged once).
    static func disableMetalFeed(_ reason: String) {
        let wasEnabled = metalFeedEnabledState.withLock { state in
            let was = state
            state = false
            return was
        }
        if wasEnabled {
            Logger(subsystem: "OpenZCine", category: "LiveView").error(
                "Metal live feed disabled — falling back to UIImageView: \(reason, privacy: .public)"
            )
            NotificationCenter.default.post(name: .metalFeedDisabled, object: nil)
        }
    }

}

enum MetalCaptureLabels {
    static let liveFeed = "OpenZCine.LiveFeed"
}

extension Notification.Name {
    /// Posted once when the Metal live feed falls back to `LiveFrameView`.
    static let metalFeedDisabled = Notification.Name("OpenZCine.metalFeedDisabled")
}

/// GPU-native live-view feed: renders the frame (with monitor effects) on the GPU via Core Image,
/// then scales into the `MTKView` drawable — no `createCGImage` GPU→CPU readback. Core Image cannot
/// write CAMetalLayer drawables directly (they lack `MTLTextureUsageShaderWrite`), so CI renders to
/// a private intermediate texture and the present copies it to the swapchain texture.
///
/// That intermediate is at the *feed's* resolution, not the drawable's (see
/// `MetalFeedFrameBaker.bakeSize`), so the present is a scale rather than a copy — one bilinear
/// sample per drawable pixel instead of a whole Core Image graph per drawable pixel.
///
/// Opt-in alternative to `LiveFrameView` (see `FeedRenderMode`). **Needs on-device validation** — the
/// vertical flip, crop, and colour-space handling below are correct by the documented pattern
/// but only a GPU capture against the live ZR confirms orientation/aspect/colour pixel-for-pixel.
struct MetalLiveView: UIViewRepresentable {
    let image: UIImage
    let effects: LiveImageEffects
    let fileStore: LUTFileStore

    func makeCoordinator() -> Coordinator { Coordinator(fileStore: fileStore) }

    func makeUIView(context: Context) -> MTKView {
        let view = MTKView(frame: .zero, device: context.coordinator.device)
        view.delegate = context.coordinator
        // CI never writes the layer drawable directly — we blit from an intermediate texture — but
        // both upscalers in `draw(in:)` do, from a compute kernel, so the drawable texture needs
        // `.shaderWrite`. `framebufferOnly = false` is what grants it (there is no `usage` knob on
        // `CAMetalLayer`), and the MPS path already depended on it — do not set this back to true.
        view.framebufferOnly = false
        if let metalLayer = view.layer as? CAMetalLayer {
            metalLayer.framebufferOnly = false
        }
        view.isPaused = true  // Push model: redraw only when a new frame arrives (setNeedsDisplay).
        view.enableSetNeedsDisplay = true
        view.colorPixelFormat = .bgra8Unorm
        // Fit, never fill: a frame/picture aspect mismatch must letterbox, not crop —
        // the operator loses exactly the frame edges they are checking (#115).
        view.contentMode = .scaleAspectFit
        view.clipsToBounds = true
        context.coordinator.update(image: image, effects: effects)
        context.coordinator.attach(view: view)
        return view
    }

    func updateUIView(_ uiView: MTKView, context: Context) {
        let needsRedraw = context.coordinator.update(image: image, effects: effects)
        context.coordinator.noteDrawableSize(uiView.drawableSize)
        if needsRedraw {
            uiView.setNeedsDisplay()
        }
    }

    /// Owns the Metal objects for the feed. Core Image baking runs off-main in `MetalFeedFrameBaker`;
    /// `draw(in:)` only scales the latest baked texture into the swapchain drawable.
    final class Coordinator: NSObject, MTKViewDelegate {
        let device: MTLDevice
        private let commandQueue: MTLCommandQueue
        private let baker: MetalFeedFrameBaker
        /// Fallback upscale from the source-resolution bake to the drawable — see
        /// `MetalFeedFrameBaker.bakeSize`. A blit encoder cannot scale, and a fullscreen quad would
        /// need a new `.metal` file in the target; MPS needs neither and is already linked
        /// (`ScopeTraceMetalView`).
        ///
        /// Lanczos, not the bilinear this started as. Bilinear was chosen only to match what Core
        /// Image's own affine upscale did, and at the ratio actually in play — a ~1024×471 bake
        /// presented at 2868×1320, so 2.8× linear — it is the weakest kernel available for the job.
        /// Lanczos costs a few more taps on one pass over the drawable and resolves real edges
        /// noticeably better. It does ring slightly on JPEG block boundaries; MetalFX below handles
        /// that case better, and this is what runs when MetalFX cannot.
        private lazy var lanczos = MPSImageLanczosScale(device: device)
        private var currentImage: UIImage?
        private var currentEffects = LiveImageEffects()
        private var lastDrawableSize: CGSize = .zero
        private weak var mtkView: MTKView?
        #if DEBUG
            private let captureScope: MTLCaptureScope?
        #endif

        init(fileStore: LUTFileStore) {
            // SAFETY: `FeedRenderMode.useMetal` is only true when `MTLCreateSystemDefaultDevice()`
            // succeeded, so the device exists here; `makeCommandQueue` does not fail on a valid
            // device. The feed otherwise uses the UIImageView path and this type is never built.
            self.device = MTLCreateSystemDefaultDevice()!
            self.commandQueue = device.makeCommandQueue()!
            self.baker = MetalFeedFrameBaker(device: device, fileStore: fileStore)
            #if DEBUG
                let scope = MTLCaptureManager.shared().makeCaptureScope(commandQueue: commandQueue)
                scope.label = MetalCaptureLabels.liveFeed
                MTLCaptureManager.shared().defaultCaptureScope = scope
                self.captureScope = scope
            #endif
            super.init()
        }

        @discardableResult
        func update(image: UIImage, effects: LiveImageEffects) -> Bool {
            let imageChanged = currentImage !== image
            let effectsChanged = currentEffects != effects
            currentImage = image
            currentEffects = effects
            if imageChanged || effectsChanged {
                scheduleBake()
            }
            return imageChanged || effectsChanged
        }

        func noteDrawableSize(_ size: CGSize) {
            guard size.width > 0, size.height > 0, size != lastDrawableSize else { return }
            lastDrawableSize = size
            scheduleBake()
        }

        func attach(view: MTKView) {
            mtkView = view
        }

        func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
            guard size.width > 0, size.height > 0 else { return }
            lastDrawableSize = size
            scheduleBake()
            view.setNeedsDisplay()
        }

        func draw(in view: MTKView) {
            autoreleasepool {
                guard FeedRenderMode.metalFeedEnabled else { return }
                guard view.window != nil else { return }

                let dstSize = view.drawableSize
                guard dstSize.width > 0, dstSize.height > 0 else { return }
                lastDrawableSize = dstSize

                guard
                    let baked = baker.bakedTexture(
                        for: dstSize, pixelFormat: view.colorPixelFormat),
                    let drawable = view.currentDrawable,
                    let commandBuffer = commandQueue.makeCommandBuffer()
                else { return }

                #if DEBUG
                    captureScope?.begin()
                #endif
                LiveViewSignposts.beginMetalFeedPresent()
                let target = drawable.texture
                if baked.width == target.width, baked.height == target.height {
                    if let blit = commandBuffer.makeBlitCommandEncoder() {
                        blit.copy(
                            from: baked,
                            sourceSlice: 0,
                            sourceLevel: 0,
                            sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
                            sourceSize: MTLSize(
                                width: baked.width, height: baked.height, depth: 1),
                            to: target,
                            destinationSlice: 0,
                            destinationLevel: 0,
                            destinationOrigin: MTLOrigin(x: 0, y: 0, z: 0))
                        blit.endEncoding()
                    }
                } else {
                    // The bake carries the SOURCE's aspect (fit, never crop — see `bakeSize`), so
                    // the present letterboxes: uniform scale, centered, over a cleared drawable.
                    // When the aspects match this fills the drawable exactly and the clear is
                    // invisible; when they don't, the operator gets bars instead of lost frame
                    // edges (#115).
                    let clearPass = MTLRenderPassDescriptor()
                    clearPass.colorAttachments[0].texture = target
                    clearPass.colorAttachments[0].loadAction = .clear
                    clearPass.colorAttachments[0].storeAction = .store
                    clearPass.colorAttachments[0].clearColor = MTLClearColor(
                        red: 0, green: 0, blue: 0, alpha: 1)
                    commandBuffer.makeRenderCommandEncoder(descriptor: clearPass)?
                        .endEncoding()
                    let scale = min(
                        Double(target.width) / Double(baked.width),
                        Double(target.height) / Double(baked.height))
                    let fittedWidth = Int((Double(baked.width) * scale).rounded())
                    let fittedHeight = Int((Double(baked.height) * scale).rounded())
                    // MetalFX Spatial scales a whole texture into a whole texture — it has no
                    // transform, so it can only take the case where the fit already fills the
                    // drawable. That is the matched-aspect camera feed, i.e. nearly every frame;
                    // a letterboxed signal (#115's DCI-4K over HDMI) needs the translate and
                    // falls to Lanczos, which is still a real edge-aware upscaler.
                    let fillsDrawable = fittedWidth == target.width && fittedHeight == target.height
                    if !fillsDrawable
                        || !encodeSpatialUpscale(
                            from: baked, to: target, commandBuffer: commandBuffer)
                    {
                        var transform = MPSScaleTransform(
                            scaleX: scale, scaleY: scale,
                            translateX: (Double(target.width) - Double(baked.width) * scale) / 2,
                            translateY: (Double(target.height) - Double(baked.height) * scale) / 2
                        )
                        withUnsafePointer(to: &transform) { pointer in
                            lanczos.scaleTransform = pointer
                            lanczos.encode(
                                commandBuffer: commandBuffer, sourceTexture: baked,
                                destinationTexture: target
                            )
                            lanczos.scaleTransform = nil
                        }
                    }
                }
                commandBuffer.present(drawable)
                commandBuffer.commit()
                LiveViewSignposts.endMetalFeedPresent()
                #if DEBUG
                    captureScope?.end()
                #endif
            }
        }

        #if canImport(MetalFX)
            /// Identifies the exact scale a `MTLFXSpatialScaler` was built for. MetalFX bakes the
            /// input and output dimensions into the object, so any change means a new one.
            private struct SpatialScalerKey: Equatable {
                let inputWidth: Int
                let inputHeight: Int
                let outputWidth: Int
                let outputHeight: Int
                let pixelFormat: MTLPixelFormat
            }

            /// Cached MetalFX Spatial upscaler and the input→output pair it was built for.
            private var spatialScaler: MTLFXSpatialScaler?
            private var spatialScalerKey: SpatialScalerKey?
            /// Whether to try MetalFX at all: A13+ only (iOS 17 still runs on A12), and latched off
            /// after a creation failure so a device that refuses it does not retry every frame.
            ///
            private lazy var spatialScalingSupported =
                !DemoHarness.forceLanczosFeedScaler
                && MTLFXSpatialScalerDescriptor.supportsDevice(device)

            /// Private-storage scratch the scaler writes into, blitted to the drawable after.
            ///
            /// MetalFX asserts `outputTexture must have private storage mode`, and a
            /// `CAMetalLayer` drawable is not private on this hardware — encoding straight into it
            /// aborted the process on device even though `supportsDevice` and `makeSpatialScaler`
            /// both succeeded. The scaler only ever runs when the fit fills the drawable, so this
            /// is drawable-sized and the follow-up blit is a straight full-surface copy.
            private var spatialOutput: MTLTexture?

            /// Drawable-sized private scratch for the scaler, rebuilt when the drawable changes.
            private func spatialOutputTexture(matching target: MTLTexture) -> MTLTexture? {
                if let existing = spatialOutput, existing.width == target.width,
                    existing.height == target.height, existing.pixelFormat == target.pixelFormat
                {
                    return existing
                }
                let descriptor = MTLTextureDescriptor.texture2DDescriptor(
                    pixelFormat: target.pixelFormat, width: target.width, height: target.height,
                    mipmapped: false)
                // `.renderTarget` as well as the compute usages: the scaler attaches this as
                // colorAttachment[0] of its own render pass internally, which validation rejects
                // for a shaderRead|shaderWrite-only texture. `.shaderRead` is what the blit reads.
                descriptor.usage = [.shaderRead, .shaderWrite, .renderTarget]
                descriptor.storageMode = .private
                spatialOutput = device.makeTexture(descriptor: descriptor)
                return spatialOutput
            }

            /// Encodes the bake→drawable upscale through MetalFX Spatial, or returns `false` when
            /// the device or the scale direction rules it out and Lanczos should run instead.
            ///
            /// MetalFX Spatial is the same class of edge-aware spatial upscaler as FSR1, shipped in
            /// the OS, and a much better fit for a 2.8× blow-up than any fixed kernel. It is *not*
            /// the temporal family (FSR2/DLSS/STP): those need per-pixel motion vectors and a
            /// jittered projection from a renderer, neither of which exists for a camera JPEG.
            ///
            /// Constructing a scaler allocates internal buffers, so one is built per (feed size,
            /// drawable size) — that pair changes on rotation or a stream-preset switch, not per
            /// frame.
            private func encodeSpatialUpscale(
                from source: MTLTexture, to target: MTLTexture, commandBuffer: MTLCommandBuffer
            ) -> Bool {
                // Read per frame, not latched: the debug switch is an A/B control and has to take
                // effect on the next frame while the operator is looking at the picture.
                guard FeedUpscaleSwitch.rendererReadsSpatialUpscaler, spatialScalingSupported else {
                    return false
                }
                // MetalFX only upscales. `bakeSize` clamps a source that out-resolves the panel
                // down to the drawable, which is the demo-stills case — Lanczos takes that one.
                guard target.width > source.width, target.height > source.height else {
                    return false
                }

                let key = SpatialScalerKey(
                    inputWidth: source.width, inputHeight: source.height,
                    outputWidth: target.width, outputHeight: target.height,
                    pixelFormat: target.pixelFormat)
                if key != spatialScalerKey {
                    let descriptor = MTLFXSpatialScalerDescriptor()
                    descriptor.inputWidth = source.width
                    descriptor.inputHeight = source.height
                    descriptor.outputWidth = target.width
                    descriptor.outputHeight = target.height
                    descriptor.colorTextureFormat = source.pixelFormat
                    descriptor.outputTextureFormat = target.pixelFormat
                    // The bake renders through an sRGB working space into BGRA8 — gamma-encoded
                    // content, not linear light. Saying otherwise mis-weights its edge detection.
                    descriptor.colorProcessingMode = .perceptual

                    guard let scaler = descriptor.makeSpatialScaler(device: device) else {
                        // Latch off rather than retrying every frame; the feed stays on Lanczos.
                        spatialScalingSupported = false
                        spatialScaler = nil
                        spatialScalerKey = nil
                        Logger(subsystem: "OpenZCine", category: "LiveView").error(
                            "MetalFX spatial scaler unavailable — feed upscale uses Lanczos.")
                        return false
                    }
                    spatialScaler = scaler
                    spatialScalerKey = key
                    // MetalFX is device-only, so this is the only way to confirm from a build which
                    // upscaler the feed actually selected — the simulator can never exercise it.
                    Logger(subsystem: "OpenZCine", category: "LiveView").info(
                        """
                        Feed upscale: MetalFX Spatial \
                        \(source.width, privacy: .public)×\(source.height, privacy: .public) → \
                        \(target.width, privacy: .public)×\(target.height, privacy: .public)
                        """)
                }
                guard let spatialScaler, let output = spatialOutputTexture(matching: target)
                else { return false }
                spatialScaler.colorTexture = source
                spatialScaler.outputTexture = output
                spatialScaler.encode(commandBuffer: commandBuffer)
                guard let blit = commandBuffer.makeBlitCommandEncoder() else { return false }
                blit.copy(
                    from: output,
                    sourceSlice: 0,
                    sourceLevel: 0,
                    sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
                    sourceSize: MTLSize(width: output.width, height: output.height, depth: 1),
                    to: target,
                    destinationSlice: 0,
                    destinationLevel: 0,
                    destinationOrigin: MTLOrigin(x: 0, y: 0, z: 0))
                blit.endEncoding()
                return true
            }
        #else
            /// Simulator stub — the iOS Simulator SDK has no MetalFX, so the feed upscales with
            /// Lanczos there. Device builds take the real path above.
            private func encodeSpatialUpscale(
                from _: MTLTexture, to _: MTLTexture, commandBuffer _: MTLCommandBuffer
            ) -> Bool { false }
        #endif

        private func scheduleBake() {
            guard let image = currentImage, lastDrawableSize.width > 0, lastDrawableSize.height > 0
            else { return }
            baker.scheduleBake(
                image: image,
                effects: currentEffects,
                drawableSize: lastDrawableSize,
                pixelFormat: .bgra8Unorm,
                onComplete: { [weak mtkView] in
                    Task { @MainActor in
                        mtkView?.setNeedsDisplay()
                    }
                })
        }
    }
}

/// Runtime A/B switch for the feed upscaler, flipped from the Display settings row.
///
/// MetalFX only exists on hardware, so the difference it makes can only be judged on a device with
/// a live feed — which makes a relaunch-free toggle the only honest way to compare it against the
/// Lanczos floor on the same shot. Read once per encode rather than latched at construction, so the
/// next frame carries the change.
@MainActor
@Observable
final class FeedUpscaleSwitch {
    static let shared = FeedUpscaleSwitch()

    /// `false` drops the feed to the Lanczos floor, the same path a pre-A13 device takes.
    var usesSpatialUpscaler = true {
        didSet { Self.rendererReadsSpatialUpscaler = usesSpatialUpscaler }
    }

    /// What the renderer actually reads. `encodeSpatialUpscale` is nonisolated — it runs from the
    /// draw callback, not an actor — so it cannot touch the main-actor property above. A lone `Bool`
    /// mirrored on every toggle is enough for a debug A/B: the worst a torn read could do is carry
    /// the old upscaler for one more frame, which is the very thing being compared.
    nonisolated(unsafe) static var rendererReadsSpatialUpscaler = true

    private init() {}
}
