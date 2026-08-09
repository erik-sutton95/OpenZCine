import CoreMedia
import CoreVideo
import Metal
import MetalKit
import MetalPerformanceShaders
import SwiftUI
import UIKit
import VideoToolbox
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
        /// What `Off` presents: the plain bilinear sample this path started as, and the reference
        /// every other option is judged against. Something has to scale the bake to the panel — the
        /// alternative to an upscaler is not "no scale", it is the cheapest one there is.
        private lazy var bilinear = MPSImageBilinearScale(device: device)
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

                // Taking the bake RETAINS it against reuse, so every exit from here has to hand
                // it back — including this one, which gives up before presenting anything.
                guard
                    let baked = baker.bakedTexture(
                        for: dstSize, pixelFormat: view.colorPixelFormat)
                else { return }
                guard
                    let drawable = view.currentDrawable,
                    let commandBuffer = commandQueue.makeCommandBuffer()
                else {
                    baker.releaseBakedTexture(baked)
                    return
                }

                #if DEBUG
                    captureScope?.begin()
                #endif
                LiveViewSignposts.beginMetalFeedPresent()
                let target = drawable.texture
                // Super Res, when it is the selected upscaler, takes the whole blow-up here and
                // hands the fit below a bigger source; the fit then only ever shrinks. Everything
                // downstream reads `source`, which is the bake unless that stage ran.
                let superResolved = encodeSuperResolution(
                    from: baked, to: target, commandBuffer: commandBuffer)
                // Supersample: when the model has run, carry its output UP past the panel with
                // MetalFX and let the fit come back DOWN. Averaging several synthesised pixels
                // into each panel pixel beats stretching one — and the model's own ceiling (960
                // in, so 1920×1080 out) lands below an iPad panel, which would otherwise leave
                // the last leg an enlargement.
                let source =
                    superResolved.map {
                        encodeSupersample($0, to: target, commandBuffer: commandBuffer)
                    }
                    ?? baked
                if source.width == target.width, source.height == target.height {
                    if let blit = commandBuffer.makeBlitCommandEncoder() {
                        blit.copy(
                            from: source,
                            sourceSlice: 0,
                            sourceLevel: 0,
                            sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
                            sourceSize: MTLSize(
                                width: source.width, height: source.height, depth: 1),
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
                        Double(target.width) / Double(source.width),
                        Double(target.height) / Double(source.height))
                    let fittedWidth = Int((Double(source.width) * scale).rounded())
                    let fittedHeight = Int((Double(source.height) * scale).rounded())
                    // MetalFX Spatial scales a whole texture into a whole texture — it has no
                    // transform, so it can only take the case where the fit already fills the
                    // drawable. That is the matched-aspect camera feed, i.e. nearly every frame;
                    // a letterboxed signal (#115's DCI-4K over HDMI) needs the translate and
                    // falls to Lanczos, which is still a real edge-aware upscaler.
                    let fillsDrawable = fittedWidth == target.width && fittedHeight == target.height
                    if fillsDrawable,
                        encodeSpatialUpscale(
                            from: source, to: target, commandBuffer: commandBuffer)
                    {
                    } else {
                        // Lanczos does the last leg. After a supersample that leg is a DOWNSCALE,
                        // which is where this kernel is at its best — no invention, just a clean
                        // average of the pixels above it.
                        var transform = MPSScaleTransform(
                            scaleX: scale, scaleY: scale,
                            translateX: (Double(target.width) - Double(source.width) * scale) / 2,
                            translateY: (Double(target.height) - Double(source.height) * scale) / 2
                        )
                        // `Off` is the bilinear reference; everything else lands on Lanczos, either
                        // as its own choice or because the option above it declined this frame.
                        let scaler: MPSImageScale =
                            FeedUpscaleSwitch.rendererReadsUpscaler == .off ? bilinear : lanczos
                        withUnsafePointer(to: &transform) { pointer in
                            scaler.scaleTransform = pointer
                            scaler.encode(
                                commandBuffer: commandBuffer, sourceTexture: source,
                                destinationTexture: target
                            )
                            scaler.scaleTransform = nil
                        }
                    }
                }
                // Released on COMPLETION, not here: the GPU is still sampling the bake after
                // `draw(in:)` returns, and freeing it early is the flash all over again.
                nonisolated(unsafe) let heldBake = baked
                commandBuffer.addCompletedHandler { [baker] _ in
                    baker.releaseBakedTexture(heldBake)
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
                MTLFXSpatialScalerDescriptor.supportsDevice(device)

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
                from source: MTLTexture, to target: MTLTexture, commandBuffer: MTLCommandBuffer,
                ignoringSelection: Bool = false
            ) -> Bool {
                // Read per frame, not latched: the picker has to take effect on the next frame
                // while the operator is looking at the picture.
                //
                // `spatialScalingSupported` is not the same question as the picker's — that one is
                // asked of the default device before anything is offered, this one latches off if
                // a scaler this renderer's device accepted in principle then refuses to be built.
                // `ignoringSelection` is the supersample stage borrowing this kernel while Super
                // Res is the selection — it is the finishing pass of that chain, not a competing
                // choice, so the picker's answer does not apply to it.
                guard ignoringSelection || FeedUpscaleSwitch.rendererReadsUpscaler == .spatial,
                    spatialScalingSupported
                else {
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
                from _: MTLTexture, to _: MTLTexture, commandBuffer _: MTLCommandBuffer,
                ignoringSelection _: Bool = false
            ) -> Bool { false }
        #endif

        /// Scratch the supersample lands in, rebuilt when its size changes.
        private var supersampleTexture: MTLTexture?

        /// Carries the model's output above the panel so the fit becomes a DOWNSCALE.
        ///
        /// The low-latency model caps at 960 in, so 1920×1080 out — below an iPad panel, which
        /// would leave the final leg an enlargement of already-synthesised pixels. MetalFX takes
        /// it to roughly twice the panel instead and Lanczos averages back down, which is the
        /// arrangement that actually uses the detail the model invented rather than stretching it.
        ///
        /// Returns the input untouched whenever the step cannot help: MetalFX only ever upscales,
        /// and a source already at or above the target has nothing to gain.
        private func encodeSupersample(
            _ source: MTLTexture, to target: MTLTexture, commandBuffer: MTLCommandBuffer
        ) -> MTLTexture {
            #if canImport(MetalFX)
                guard spatialScalingSupported else { return source }
                // Twice the panel on the long edge, capped at 4K — past that the cost climbs and
                // the extra pixels are averaged away in the same breath.
                let wanted = min(max(target.width * 2, target.width), 3_840)
                let scale = Double(wanted) / Double(source.width)
                guard scale > 1.05 else { return source }
                let width = wanted
                let height = Int((Double(source.height) * scale).rounded())
                guard width > source.width, height > source.height else { return source }

                if supersampleTexture?.width != width || supersampleTexture?.height != height
                    || supersampleTexture?.pixelFormat != target.pixelFormat
                {
                    let descriptor = MTLTextureDescriptor.texture2DDescriptor(
                        pixelFormat: target.pixelFormat, width: width, height: height,
                        mipmapped: false)
                    descriptor.usage = [.shaderRead, .shaderWrite, .renderTarget]
                    descriptor.storageMode = .private
                    supersampleTexture = device.makeTexture(descriptor: descriptor)
                }
                guard let supersampleTexture else { return source }
                guard
                    encodeSpatialUpscale(
                        from: source, to: supersampleTexture, commandBuffer: commandBuffer,
                        ignoringSelection: true)
                else { return source }
                return supersampleTexture
            #else
                return source
            #endif
        }

        #if !targetEnvironment(simulator)
            /// The VideoToolbox super-resolution stage, built on first use.
            ///
            /// `AnyObject` because a stored property cannot carry `@available` — the one cast below
            /// is what that costs.
            private var superResolver: AnyObject?

            /// Runs the bake through one of the two VideoToolbox super-resolution processors when
            /// one of them is the selected upscaler, returning the enlarged texture for the present
            /// to fit — or `nil` to leave the bake as the source.
            ///
            /// Switching between them builds a new stage rather than reconfiguring the old one:
            /// they are different processors with different session state, and swapping is an
            /// operator action, not something that happens per frame.
            private func encodeSuperResolution(
                from source: MTLTexture, to target: MTLTexture, commandBuffer: MTLCommandBuffer
            ) -> MTLTexture? {
                // Live again, and AFTER the effects bake by operator decision: the assists
                // (peaking, false colour, zebra, scopes) keep measuring the true source frame at
                // its own resolution, and the model enlarges the finished picture. The cost is the
                // stage's one-frame slot latency, accepted in exchange.
                guard FeedUpscaleSwitch.rendererReadsUpscaler == .superResolution,
                    #available(iOS 26.0, *)
                else { return nil }
                let existing = superResolver as? FeedSuperResolutionScaler
                let scaler: FeedSuperResolutionScaler
                if let existing, existing.quality == .lowLatency {
                    scaler = existing
                } else {
                    scaler = FeedSuperResolutionScaler(device: device, quality: .lowLatency)
                    superResolver = scaler
                }
                return scaler.encode(
                    source: source, target: target, commandBuffer: commandBuffer)
            }
        #else
            /// Simulator stub — `VTLowLatencySuperResolutionScaler` is excluded from the simulator
            /// SDK the same way MetalFX is, so this option only exists on hardware.
            private func encodeSuperResolution(
                from _: MTLTexture, to _: MTLTexture, commandBuffer _: MTLCommandBuffer
            ) -> MTLTexture? { nil }
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

/// The downloadable ML model the quality-prioritized super-resolution processor needs, and the
/// only thing that decides whether that upscaler is offered at all.
///
/// Unlike every other option in the picker, this one is not a fixed property of the hardware: the
/// processor ships without its model and reports `downloadRequired` until someone fetches it over
/// the network. Apple asks that the download be driven "with user awareness and interaction", and
/// this app spends much of its life on a camera's access point with no route to the internet — so
/// nothing here starts on its own. The operator taps, or the option stays absent.
@MainActor
@Observable
final class SuperResolutionModel {
    static let shared = SuperResolutionModel()

    enum State: Equatable {
        /// The processor does not exist on this device or OS — there is nothing to download.
        case unavailable
        /// Supported, model absent. This is the only state that offers a download.
        case needsDownload
        case downloading(fraction: Double)
        case ready
        case failed(String)
    }

    private(set) var state: State = .unavailable

    /// Whether the quality-prioritized upscaler can run right now.
    ///
    /// `nonisolated` and asked of VideoToolbox rather than of this object, because the renderer's
    /// own default resolves off the main actor before any view exists — and because the answer
    /// changes when a download finishes, so it cannot be cached in a `let` like the others.
    nonisolated static var isReady: Bool {
        #if targetEnvironment(simulator)
            return false
        #else
            guard #available(iOS 26.0, *) else { return false }
            return probe?.configurationModelStatus == .ready
        #endif
    }

    #if !targetEnvironment(simulator)
        /// A configuration built only to be asked questions — model status, download progress — at
        /// a representative feed size inside the processor's iOS input cap (1440×1080 for video).
        /// The model asset is per-processor, not per-size, so any valid configuration answers for
        /// all of them.
        @available(iOS 26.0, *)
        fileprivate nonisolated static let probe: VTSuperResolutionScalerConfiguration? = {
            guard VTSuperResolutionScalerConfiguration.isSupported,
                let scale = VTSuperResolutionScalerConfiguration.supportedScaleFactors.min()
            else { return nil }
            return VTSuperResolutionScalerConfiguration(
                frameWidth: 1_024, frameHeight: 576, scaleFactor: scale, inputType: .video,
                usePrecomputedFlow: false, qualityPrioritization: .normal,
                revision: VTSuperResolutionScalerConfiguration.defaultRevision)
        }()
    #endif

    private init() {
        refresh()
    }

    /// Re-reads the model status. Cheap, and the settings row asks on appearance because a
    /// download can also have been completed by another app on the same device.
    func refresh() {
        #if !targetEnvironment(simulator)
            if #available(iOS 26.0, *), let probe = Self.probe {
                switch probe.configurationModelStatus {
                case .ready: state = .ready
                case .downloading:
                    state = .downloading(
                        fraction: Double(probe.configurationModelPercentageAvailable))
                default: state = .needsDownload
                }
                return
            }
        #endif
        state = .unavailable
    }

    /// Starts the download. Only ever called from the operator's tap on the settings row.
    func download() {
        #if !targetEnvironment(simulator)
            guard #available(iOS 26.0, *), let probe = Self.probe else { return }
            guard state == .needsDownload || isFailed else { return }
            state = .downloading(fraction: Double(probe.configurationModelPercentageAvailable))
            probe.downloadConfigurationModel { [weak self] error in
                Task { @MainActor in
                    guard let self else { return }
                    if let error {
                        self.state = .failed(error.localizedDescription)
                    } else {
                        self.refresh()
                    }
                }
            }
            pollProgress()
        #endif
    }

    private var isFailed: Bool {
        if case .failed = state { return true }
        return false
    }

    /// The download reports completion but not progress, so progress is polled while it runs.
    ///
    /// Two seconds, not the half-second this started at. Reading `configurationModelStatus` makes
    /// MobileAsset try to lock the asset, and while the download is still in flight that lock fails
    /// and logs `LockNoWaitNoDownloadedAsset` every time — a device log filled with those was this
    /// poll asking four times as often as a progress bar needs, not the download going wrong.
    private func pollProgress() {
        Task { @MainActor [weak self] in
            while let self, case .downloading = self.state {
                try? await Task.sleep(for: .seconds(2))
                guard case .downloading = self.state else { return }
                self.refresh()
            }
        }
    }
}

/// Runtime control for VideoToolbox's temporal noise filter over the live feed.
///
/// Mounted by `FeedDenoiseDebugKey` on the live feed; `ZC_DEMO_DENOISE` seeds it at launch. The
/// key came out once while the filter appeared dead — that was the end-before-start bug
/// (`LiveFeedSuperResolution.prepare`), and it returned with the fix.
@MainActor
@Observable
final class LiveDenoiseSwitch {
    static let shared = LiveDenoiseSwitch()

    private nonisolated static let storageKey = "OpenZCine.feedNoiseReduction"

    /// Whether this device can run the filter at all — the same rule the upscaler options follow.
    /// An operator switch that quietly does nothing is worse than no switch.
    static var isSupportedOnThisDevice: Bool {
        #if targetEnvironment(simulator)
            return false
        #else
            guard #available(iOS 26.0, *) else { return false }
            return VTTemporalNoiseFilterConfiguration.isSupported
        #endif
    }

    var enabled: Bool = UserDefaults.standard.bool(forKey: storageKey) {
        didSet {
            Self.decoderReadsEnabled = enabled
            UserDefaults.standard.set(enabled, forKey: Self.storageKey)
        }
    }

    /// 0…1, the processor's own scale.
    ///
    /// The operator control is Off/On at full strength, not a dial: on hardware the intermediate
    /// values were indistinguishable from off, so a slider offered precision the processor does
    /// not actually deliver. The debug key still exposes the range for sweeping it.
    var strength: Float = 1 {
        didSet { Self.decoderReadsStrength = max(0, min(1, strength)) }
    }

    /// What the decode actor reads. It runs off any actor, so a plain mirrored value is what
    /// crosses — the worst a torn read can do is carry the old setting for one frame.
    nonisolated(unsafe) static var decoderReadsEnabled = UserDefaults.standard.bool(
        forKey: storageKey)
    nonisolated(unsafe) static var decoderReadsStrength: Float = 1

    /// Why the filter turned itself off, when it has. Written by the decode side, read by the
    /// settings row — the switch must never sit there looking armed over a filter that has given
    /// up, which is exactly how "it stopped working" arrives with nothing to act on.
    nonisolated(unsafe) static var decoderReportsUnavailable: String?
    private init() {}
}

/// Which upscaler carries the bake→drawable blow-up. Raw values are the segment titles.
enum FeedUpscaler: String, CaseIterable, Sendable {
    /// No upscaler: the plain bilinear sample, and the reference the rest are judged against.
    /// Something must scale the bake to the panel, so "off" is the cheapest kernel, not no scale.
    case off = "Off"
    /// The floor every device can run: one MPS Lanczos pass over the drawable.
    case lanczos = "Fast"
    /// MetalFX Spatial, the FSR1-class edge-aware upscaler in the OS. A13+.
    case spatial = "Quality"
    /// VideoToolbox's low-latency super-resolution model, running in the renderer AFTER the
    /// effects bake — assists measure the true source; the model enlarges the finished picture.
    /// iOS 26+, hardware only. The end-before-start bug that kept this dead is documented on
    /// `LiveFeedSuperResolution.prepare`.
    ///
    /// Named "AI" rather than by its mechanism because that is the property an operator has to
    /// weigh: it INFERS detail that was never captured. See the settings help.
    case superResolution = "AI"
    /// Whether this device can actually run this upscaler.
    ///
    /// The picker offers nothing else. An option that quietly falls back to Lanczos is
    /// indistinguishable from a setting that does not work, and both MetalFX and the
    /// super-resolution models are absent on whole classes of device (and from the simulator
    /// entirely) — so the answer belongs in what is shown, not in what happens after the tap.
    var isSupportedOnThisDevice: Bool {
        switch self {
        case .off, .lanczos: true
        case .spatial: Self.spatialSupported
        case .superResolution: Self.superResolutionSupported
        }
    }

    /// The upscalers worth offering on this device — always at least Off and the Lanczos floor,
    /// which are plain MPS kernels every device has.
    static var supportedOnThisDevice: [FeedUpscaler] { allCases.filter(\.isSupportedOnThisDevice) }

    /// `candidate` when this device can run it, otherwise the floor. A stored choice outlives the
    /// device it was made on: a restore onto older hardware, or a build run in the simulator, can
    /// name an upscaler that is not there any more.
    ///
    /// The floor, not the best available, and that is the default an untouched install gets. Every
    /// step above Lanczos costs GPU on a path that already shares the die with the decode and the
    /// effects bake, and the operator who wants that spent has a picker to say so. Starting at the
    /// cheapest real kernel also means the first thing anyone sees is the honest one — nothing on
    /// screen is inferred until they ask for it.
    static func supported(or candidate: FeedUpscaler?) -> FeedUpscaler {
        if let candidate, candidate.isSupportedOnThisDevice { return candidate }
        return .lanczos
    }

    /// A13+ and a device build. Asking the descriptor costs a `MTLDevice`, so it is asked once.
    private static let spatialSupported: Bool = {
        #if canImport(MetalFX)
            guard let device = MTLCreateSystemDefaultDevice() else { return false }
            return MTLFXSpatialScalerDescriptor.supportsDevice(device)
        #else
            return false
        #endif
    }()

    /// iOS 26 and a device build — `VTLowLatencySuperResolutionScaler` is excluded from the
    /// simulator SDK the same way MetalFX is.
    private static let superResolutionSupported: Bool = {
        #if targetEnvironment(simulator)
            return false
        #else
            guard #available(iOS 26.0, *) else { return false }
            return VTLowLatencySuperResolutionScalerConfiguration.isSupported
        #endif
    }()

    /// Which of the factors the super-resolution processor `offered` for a source size to run at,
    /// to blow that source up by `ratio`.
    ///
    /// The smallest offered factor that *clears* the ratio, so the fit after the model only ever
    /// shrinks — enlarging a model's output with Lanczos would throw away the thing being paid
    /// for. When nothing clears it, the largest offered gets as close as the processor allows.
    /// `nil` when nothing is offered at all: that source size is not served, which is a rotation
    /// away from being served and so never a reason to latch the option off.
    ///
    /// `held` — the factor already running for this same source size — wins whenever it still
    /// clears the ratio, even though a smaller one would now do. The drawable walks through a dozen
    /// intermediate sizes during a layout animation (a device log shows the MetalFX scaler rebuilt
    /// five times across one), and changing factor restarts the processor, which loads an ML model
    /// on the draw thread. An oversized factor costs some extra output pixels; a restart per
    /// animation frame costs the operator the picture.
    /// The size to hand the super-resolution model when the bake is larger than it will take.
    ///
    /// The low-latency processor tops out at 960×960 on device, and a Quality-preset ZR feed is
    /// 1024×576 — over the ceiling, so it offers no scale factor at all and the option silently
    /// did nothing. Shrinking the input by 6% to clear that ceiling buys a ×2 ML upscale of the
    /// result, which is a far better trade than the 6% of source width it costs.
    ///
    /// Uniform, so the aspect the present letterboxes against is unchanged, and never an upscale:
    /// a source already inside the limit is handed over untouched.
    static func superResolutionInputSize(
        source: (width: Int, height: Int),
        target: (width: Int, height: Int),
        scale: Float,
        maximum: (width: Int, height: Int)
    ) -> (width: Int, height: Int) {
        guard source.width > 0, source.height > 0, maximum.width > 0, maximum.height > 0
        else { return source }
        // The ceiling first: some processors simply will not take a frame this big.
        var shrink = min(
            Double(maximum.width) / Double(source.width),
            Double(maximum.height) / Double(source.height),
            1)
        // Then the panel. The model multiplies by a FIXED factor, so handing it the whole source
        // when that factor overshoots produces pixels the fit immediately discards — measured on
        // device as 1024×576 ×4 = 4096×2304 for a 2347×1320 panel: 75 MB a surface, three deep,
        // and the drawable queue starved until `nextDrawable` timed out every frame. Shrink until
        // the model's OUTPUT just clears the panel instead.
        if scale > 0 {
            let clears = max(
                Double(target.width) / (Double(source.width) * Double(scale)),
                Double(target.height) / (Double(source.height) * Double(scale)))
            // Only ever shrink: when the factor cannot reach the panel even from the whole source,
            // the fit enlarges the rest and there is nothing to give back here.
            if clears < 1 { shrink = min(shrink, clears) }
        }
        guard shrink < 1 else { return source }
        return (
            max(1, Int((Double(source.width) * shrink).rounded(.down))),
            max(1, Int((Double(source.height) * shrink).rounded(.down)))
        )
    }

    static func superResolutionScale(offered: [Float], ratio: Double, held: Float? = nil) -> Float?
    {
        if let held, Double(held) >= ratio { return held }
        let ordered = offered.sorted()
        return ordered.first { Double($0) >= ratio } ?? ordered.last
    }
}

/// Which upscaler the feed is using, set from the Link settings row.
///
/// Neither MetalFX nor VideoToolbox super resolution exists in the simulator, so what they buy can
/// only be judged on a device against a live feed — which makes a relaunch-free picker the only
/// honest way to compare them with the Lanczos floor on the same shot. Read once per encode rather
/// than latched at construction, so the next frame carries the change.
@MainActor
@Observable
final class FeedUpscaleSwitch {
    static let shared = FeedUpscaleSwitch()

    private nonisolated static let storageKey = "OpenZCine.feedUpscaler"

    /// `.lanczos` drops the feed to the floor, the same path a pre-A13 device takes.
    var upscaler: FeedUpscaler = FeedUpscaleSwitch.rendererReadsUpscaler {
        didSet {
            Self.rendererReadsUpscaler = upscaler
            UserDefaults.standard.set(upscaler.rawValue, forKey: Self.storageKey)
        }
    }

    /// What the renderer actually reads. The encode paths are nonisolated — they run from the draw
    /// callback, not an actor — so they cannot touch the main-actor property above. A single value
    /// mirrored on every change is enough: the worst a torn read could do is carry the old upscaler
    /// for one more frame, which is the very thing being compared.
    ///
    /// It seeds itself rather than being seeded by ``shared``, because the renderer runs whether or
    /// not the settings panel was ever opened — reading the stored choice here is what keeps a
    /// default of "the best this device has" from collapsing to the floor on an untouched launch.
    nonisolated(unsafe) static var rendererReadsUpscaler: FeedUpscaler = .supported(
        or: storedChoice)

    /// Debug: present the model's input rather than its output (`ZC_DEMO_SR_STAGE=input`).
    nonisolated(unsafe) static var presentsSuperResolutionInput = false
    /// The persisted choice, if there is one this build still understands. `nonisolated` because
    /// the static above it is: the renderer's seed cannot wait for the main actor.
    ///
    /// The raw values ARE the stored keys and they were renamed to operator-facing words, so the
    /// old ones are mapped rather than dropped — an operator who chose MetalFX keeps Quality
    /// instead of being silently reset to the default.
    private nonisolated static var storedChoice: FeedUpscaler? {
        guard let stored = UserDefaults.standard.string(forKey: storageKey) else { return nil }
        if let known = FeedUpscaler(rawValue: stored) { return known }
        switch stored {
        case "Lanczos": return .lanczos
        case "MetalFX": return .spatial
        case "Super Res": return .superResolution
        default: return nil
        }
    }

    private init() {}

    /// Debug A/B: drop to `Off` and back to whatever was selected.
    ///
    /// Two states, not a cycle through all five. The question on a live feed is "is this doing
    /// anything", and that is answered by flipping between the plain bilinear reference and the
    /// pick — a cycle makes the operator track where in the list they are while looking at the
    /// picture, which is the opposite of the job.
    func toggleAgainstOff() {
        if upscaler == .off {
            upscaler = .supported(or: restoreAfterOff)
            restoreAfterOff = nil
        } else {
            restoreAfterOff = upscaler
            upscaler = .off
        }
    }

    /// What `Off` came from, so the second tap goes back to it rather than to a default.
    @ObservationIgnored private var restoreAfterOff: FeedUpscaler?
}

#if !targetEnvironment(simulator)
    /// VideoToolbox's low-latency super-resolution scaler as a feed upscaler, sitting between the
    /// bake and the present's fit.
    ///
    /// The model works on `CVPixelBuffer`s, not textures, so the bake is blitted into an
    /// IOSurface-backed input surface and the model writes an output surface that is read back as a
    /// texture — both allocated once per (bake size, scale factor). `processWithCommandBuffer`
    /// keeps all of that inside the present's own command buffer: no CPU round-trip, no completion
    /// handler, and the blit already queued ahead of it is ordered before the model by contract.
    ///
    /// Unlike MetalFX this cannot take an arbitrary ratio — only the discrete factors the processor
    /// reports for the source size — so it takes the smallest factor that *clears* the drawable and
    /// lets the fit after it shrink. Enlarging a model's output with Lanczos would throw away the
    /// thing being paid for.
    @available(iOS 26.0, *)
    private final class FeedSuperResolutionScaler {
        /// Which of the two super-resolution processors this instance drives.
        ///
        /// They differ in more than quality. The low-latency one is stateless per frame and always
        /// present; the quality one is recurrent — it wants the previous source frame and its own
        /// previous output back — needs a downloaded model, computes optical flow per frame unless
        /// given it, and caps input at 1440×1080 on iOS.
        enum Quality {
            case lowLatency
            case high
        }

        /// Identifies the session a processor was started for; either half changing means a new one.
        private struct Key: Equatable {
            let width: Int
            let height: Int
            let scale: Float
        }

        /// A pixel buffer and the texture view of the same memory, kept together because the
        /// `CVMetalTexture` is what holds `texture` alive.
        private struct Surface {
            let buffer: CVPixelBuffer
            /// Held because a pool outlives the buffers it vends.
            let pool: CVPixelBufferPool
            /// Nil for planar formats: `420v` is two planes, so there is no one texture that is
            /// the image. Those surfaces are read and written through Core Image instead.
            let bridge: CVMetalTexture?
            let texture: MTLTexture?
        }

        let quality: Quality
        private let device: MTLDevice
        private let log = Logger(subsystem: "OpenZCine", category: "LiveView")
        private var textureCache: CVMetalTextureCache?
        private var processor: VTFrameProcessor?
        private var key: Key?
        /// The previous submission's frames, which the quality processor takes as references. Held
        /// as whole frames rather than indices so the round-robin can move underneath them.
        private var previousSource: VTFrameProcessorFrame?
        private var previousOutput: VTFrameProcessorFrame?
        /// One input/output pair per frame that can be in flight — see `encode`.
        private var surfaces: [(input: Surface, output: Surface)] = []
        private var nextSurface = 0
        /// Latched after a refusal so a device that cannot run the model stops paying for the
        /// attempt on every frame. Dimensions it merely does not serve are not a refusal — those
        /// return early without latching, since the next rotation may well be servable.
        private var unavailable = false
        private var frameCount: Int64 = 0
        /// Last decline logged, so a per-frame condition says its reason once rather than 30 times
        /// a second — and says it again if the reason changes.
        private var lastDecline: String?
        /// Shrinks a bake that out-sizes the processor into its input surface. Only ever a
        /// downscale, and only when the ceiling demands one — see `superResolutionInputSize`.
        private lazy var shrink = MPSImageLanczosScale(device: device)
        /// The format this session's surfaces are in. Not always BGRA: the quality processor takes
        /// only `RGhA` (64-bit RGBA half-float), and refusing to speak it is what latched that
        /// upscaler off before it ever ran a frame.
        private var surfaceFormat: (cv: OSType, metal: MTLPixelFormat?) = (
            kCVPixelFormatType_32BGRA, .bgra8Unorm
        )
        /// Carries the two colour conversions when the processor speaks a planar format. Core
        /// Image rather than a compute kernel because it converts `420v` in both directions
        /// natively, and because `render(_:to:commandBuffer:)` keeps the output leg on the
        /// present's own command buffer — the property that made this path cheap to begin with.
        private lazy var ciContext = CIContext(
            mtlDevice: device, options: [.cacheIntermediates: false])
        /// The model's own command buffers, so its work can be COMPLETED before Core Image reads
        /// the result — see `encode`. Separate from the present's queue on purpose: committing the
        /// model into the present's buffer is what produced a frame of flat green.
        private lazy var modelQueue = device.makeCommandQueue()

        /// The asynchronous model's state, shared with its completion handler.
        /// Which SLOT holds the finished result, not the buffer itself: `CVBuffer` carries no
        /// Sendable conformance, and an index crosses the lock without arguing about it.
        private struct AsyncModel {
            var inFlight = false
            /// The most recent output the model has actually FINISHED writing. Reading anything
            /// else is what produced flat green: Core Image resolves a `CVPixelBuffer` when the
            /// render is encoded, so it must only ever be handed a completed buffer.
            var readyIndex: Int?
            var failure: String?
        }

        private let asyncModel = OSAllocatedUnfairLock(initialState: AsyncModel())
        /// Where the model's planar output is converted back to, for the fit to present.
        private var rgbOutput: MTLTexture?
        private let workingColorSpace =
            CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()

        init(device: MTLDevice, quality: Quality) {
            self.device = device
            self.quality = quality
        }

        deinit { processor?.endSession() }

        /// Encodes the super-resolution pass into `commandBuffer` and returns the enlarged texture,
        /// or `nil` when the model cannot take this frame and the caller should present the bake.
        func encode(source: MTLTexture, target: MTLTexture, commandBuffer: MTLCommandBuffer)
            -> MTLTexture?
        {
            guard !unavailable else { return nil }
            switch quality {
            case .lowLatency:
                guard VTLowLatencySuperResolutionScalerConfiguration.isSupported else {
                    return decline("this device does not support it")
                }
            case .high:
                guard SuperResolutionModel.isReady else {
                    return decline("its model has not been downloaded")
                }
                // The iOS cap for video input. A source past it is a configuration this processor
                // refuses to build, so it is a decline rather than a failure.
                guard source.width <= 1_440, source.height <= 1_080 else {
                    return decline(
                        "\(source.width)×\(source.height) is past the 1440×1080 input limit")
                }
            }
            let ratio = min(
                Double(target.width) / Double(source.width),
                Double(target.height) / Double(source.height))
            guard ratio > 1 else {
                // `bakeSize` clamps a source that out-resolves the panel, so the present is a copy
                // and there is nothing to upscale — the demo-stills case. Worth saying out loud:
                // from the operator's side this looks exactly like the option doing nothing.
                return decline(
                    "the \(source.width)×\(source.height) bake already fills the "
                        + "\(target.width)×\(target.height) panel — nothing to upscale")
            }

            // The bake can be bigger than the processor takes (1024×576 against a 960×960
            // ceiling). Shrinking to fit is what makes the model reachable at all; the fit after
            // it absorbs the difference either way.
            let ceiling: (width: Int, height: Int)
            switch quality {
            case .lowLatency:
                if let maximum = VTLowLatencySuperResolutionScalerConfiguration.maximumDimensions {
                    ceiling = (Int(maximum.width), Int(maximum.height))
                } else {
                    ceiling = (source.width, source.height)
                }
            case .high:
                ceiling = (1_440, 1_080)
            }
            // Sized against the ceiling first so the factor query asks about a frame the
            // processor will actually take; the panel-fit shrink lands once the factor is known.
            let ceilingInput = FeedUpscaler.superResolutionInputSize(
                source: (source.width, source.height), target: (target.width, target.height),
                scale: 0, maximum: ceiling)

            // No factors means the processor does not serve this source size — not a failure of the
            // model, so no latch: the next rotation may well be servable.
            let running = key.flatMap { $0.scale }
            // The quality processor's factors are whole numbers and do not depend on the source
            // size; the low-latency one's are fractional and asked per size.
            let offered: [Float] =
                switch quality {
                case .lowLatency:
                    VTLowLatencySuperResolutionScalerConfiguration.supportedScaleFactors(
                        frameWidth: ceilingInput.width, frameHeight: ceilingInput.height)
                case .high:
                    VTSuperResolutionScalerConfiguration.supportedScaleFactors.map(Float.init)
                }
            guard
                let scale = FeedUpscaler.superResolutionScale(
                    offered: offered, ratio: ratio, held: running)
            else {
                // Say what the processor WILL take. An empty factor list is how it reports "not
                // this size", and without its own bounds beside them the number is unactionable —
                // a PTP live view is capped near 1024 wide, so if the floor is higher than that,
                // this upscaler can never serve the wireless feed and only HDMI capture qualifies.
                let bounds: String
                switch quality {
                case .lowLatency:
                    let low = VTLowLatencySuperResolutionScalerConfiguration.minimumDimensions
                    let high = VTLowLatencySuperResolutionScalerConfiguration.maximumDimensions
                    if let low, let high {
                        bounds = "\(low.width)×\(low.height) to \(high.width)×\(high.height)"
                    } else {
                        bounds = "sizes it does not report"
                    }
                case .high:
                    bounds = "up to 1440×1080"
                }
                return decline(
                    "no scale factor is offered for \(source.width)×\(source.height) "
                        + "— it takes \(bounds)")
            }

            let modelInput = FeedUpscaler.superResolutionInputSize(
                source: (source.width, source.height), target: (target.width, target.height),
                scale: scale, maximum: ceiling)
            let wanted = Key(width: modelInput.width, height: modelInput.height, scale: scale)
            // Session startup happens OFF this thread and the frame is presented without it.
            //
            // The header is explicit: "ML model loading may take longer than a frame time. Avoid
            // blocking the UI thread or stalling frame rendering pipelines during this call." It
            // was being called from `draw(in:)`, with a frame submitted on the very next line —
            // which fits every symptom seen so far. `startSession` returns true because the
            // configuration is valid, while the pipeline behind it is still being built: submitting
            // then made the asynchronous entry point dereference an internal queue that did not
            // exist yet (EXC_BAD_ACCESS in VideoToolbox's own dispatch_async), and made the
            // command-buffer entry point encode nothing at all and report no error.
            if wanted != key {
                _ = startSession(for: wanted)
                // Present THIS frame on Lanczos and submit nothing. The session was previously
                // started and handed a frame in the same draw call, which is the one ordering the
                // header warns about — the load "may take longer than a frame time", and every
                // failure so far is consistent with a pipeline that had not finished coming up:
                // the async entry point crashed inside VideoToolbox's own dispatch_async, and the
                // command-buffer one encoded nothing and reported no error.
                return nil
            }
            guard let processor, !surfaces.isEmpty else { return nil }

            // Round-robin the surfaces rather than reusing one pair. Apple's contract is that
            // neither buffer may be touched until the work on it finishes — here that is command
            // buffer completion, and the drawable queue keeps two or three frames in flight, so
            // writing the next frame into last frame's input would corrupt work still running.
            let (input, output) = surfaces[nextSurface % surfaces.count]
            nextSurface += 1

            if let inputTexture = input.texture {
                // A blit copies bytes, so it can only take the case where nothing needs changing.
                // Any difference in size OR format goes through the resampler, which does both.
                if inputTexture.width == source.width, inputTexture.height == source.height,
                    inputTexture.pixelFormat == source.pixelFormat
                {
                    guard let blit = commandBuffer.makeBlitCommandEncoder() else { return nil }
                    blit.copy(
                        from: source,
                        sourceSlice: 0,
                        sourceLevel: 0,
                        sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
                        sourceSize: MTLSize(width: source.width, height: source.height, depth: 1),
                        to: inputTexture,
                        destinationSlice: 0,
                        destinationLevel: 0,
                        destinationOrigin: MTLOrigin(x: 0, y: 0, z: 0))
                    blit.endEncoding()
                } else {
                    // The one place this path shrinks the picture, and what makes the model legal
                    // at all. Lanczos rather than the cheapest kernel: whatever detail survives
                    // here is what the model has to work from.
                    shrink.encode(
                        commandBuffer: commandBuffer, sourceTexture: source,
                        destinationTexture: inputTexture)
                }
            } else if !writePlanarInput(from: source, to: input, size: modelInput) {
                return decline("the frame could not be converted to the model's format")
            }

            // The feed carries no timestamps of its own, and a low-latency model is entitled to
            // read the previous frame — so the stamps at least have to advance monotonically.
            frameCount += 1
            let time = CMTime(value: frameCount, timescale: 600)
            guard
                let sourceFrame = VTFrameProcessorFrame(
                    buffer: input.buffer, presentationTimeStamp: time),
                let destinationFrame = VTFrameProcessorFrame(
                    buffer: output.buffer, presentationTimeStamp: time)
            else { return nil }
            let parameters: any VTFrameProcessorParameters
            switch quality {
            case .lowLatency:
                parameters = VTLowLatencySuperResolutionScalerParameters(
                    sourceFrame: sourceFrame, destinationFrame: destinationFrame)
            case .high:
                // Recurrent: it refines against the previous source and its own previous output,
                // which is where the extra quality comes from. Both are nil on the first frame
                // after a session start, which the API allows. `sequential` tells it the stream has
                // not jumped — the mode that lets it keep its caches.
                guard
                    let recurrent = VTSuperResolutionScalerParameters(
                        sourceFrame: sourceFrame,
                        previousFrame: previousSource,
                        previousOutputFrame: previousOutput,
                        opticalFlow: nil,
                        submissionMode: .sequential,
                        destinationFrame: destinationFrame)
                else { return decline("the frame pair was rejected") }
                parameters = recurrent
                previousSource = sourceFrame
                previousOutput = destinationFrame
            }
            // The model runs in ITS OWN command buffer, committed and awaited, whenever the
            // result has to be read back through Core Image.
            //
            // `processWithCommandBuffer` orders the model against other GPU work in the same
            // buffer, and that is enough when the output is a texture the fit samples directly.
            // It is NOT enough for the planar path: Core Image resolves a `CVPixelBuffer` source
            // when the render is ENCODED, not when it executes, so reading the output inside the
            // present's buffer captured the frame before the model had run — every pixel zero,
            // which in `420v` is the flat green this showed on device.
            //
            // Synchronous, which costs the draw thread the model's own latency. The input leg is
            // already synchronous, so this makes the whole stage so; if a device says that is too
            // expensive the answer is to present the PREVIOUS frame's output and drop the wait,
            // at the cost of one frame of lag.
            // A texture output can ride the present's own command buffer: the fit samples it
            // directly, and `processWithCommandBuffer` orders the model against the work around it.
            guard output.texture == nil else {
                processor.process(with: commandBuffer, parameters: parameters)
                lastDecline = nil
                return output.texture
            }

            // The planar path submits asynchronously and presents the previous completed result.
            //
            // Never the PRESENT's command buffer: Core Image resolves a `CVPixelBuffer` source
            // when the render is ENCODED, not when it executes, so reading the output there
            // captured the frame before the model ran — every pixel zero, which in `420v` is flat
            // green. Presenting only a buffer the model has FINISHED costs a frame of lag and buys
            // that guarantee outright.
            if FeedUpscaleSwitch.presentsSuperResolutionInput {
                // Diagnostic: read back the input, which needs no model at all.
                lastDecline = nil
                return readPlanarOutput(input, commandBuffer: commandBuffer)
            }

            let pending = asyncModel.withLock {
                state -> (start: Bool, readyIndex: Int?, failure: String?) in
                let start = !state.inFlight
                if start { state.inFlight = true }
                let failure = state.failure
                state.failure = nil
                return (start, state.readyIndex, failure)
            }
            if let failure = pending.failure {
                return decline("the model refused the frame — \(failure)")
            }
            if pending.start {
                let slot = (nextSurface - 1) % surfaces.count
                // The command-buffer entry point, which has never crashed. The asynchronous one
                // segfaults inside VideoToolbox for this configuration whether the buffers come
                // from `CVPixelBufferCreate` or from a pool, so it is not the buffers.
                //
                // Its own command buffer, not the present's: Core Image resolves a
                // `CVPixelBuffer` when the render is ENCODED, so only a buffer the model has
                // FINISHED is safe to read, and the completion handler is what proves that.
                if let modelQueue, let modelBuffer = modelQueue.makeCommandBuffer() {
                    processor.process(with: modelBuffer, parameters: parameters)
                    modelBuffer.addCompletedHandler { [weak self] buffer in
                        self?.asyncModel.withLock { state in
                            state.inFlight = false
                            if let error = buffer.error {
                                state.failure = error.localizedDescription
                            } else {
                                state.readyIndex = slot
                            }
                        }
                    }
                    modelBuffer.commit()
                } else {
                    asyncModel.withLock { $0.inFlight = false }
                }
            }
            // Nothing finished yet — the first frame or two after a session starts. Present the
            // bake rather than an empty buffer, and say nothing: this is not a fault.
            guard let readyIndex = pending.readyIndex, readyIndex < surfaces.count else {
                return nil
            }
            lastDecline = nil  // A later decline is news again.
            return readPlanarOutput(
                surfaces[readyIndex].output.buffer, commandBuffer: commandBuffer)
            // Planar output: convert back to RGB for the fit. This render takes the present's own
            // command buffer, and `processWithCommandBuffer` documents that work inserted after it
            // runs after the effect — so this reads the model's result, not the frame before it.
            return readPlanarOutput(output, commandBuffer: commandBuffer)
        }

        /// Builds the processor and its surfaces for `wanted`, replacing whatever was there.
        ///
        /// This loads an ML model, which Apple documents as possibly taking longer than a frame —
        /// on the draw thread that is a visible hitch. It happens once per (bake size, scale), i.e.
        /// on selecting this upscaler and on a panel size the running factor no longer covers, not
        /// per frame.
        private func startSession(for wanted: Key) -> Bool {
            // `supportedPixelFormats` is refined onto each concrete configuration, not onto the
            // protocol, so the BGRA check has to happen before the type is erased.
            let configuration: any VTFrameProcessorConfiguration
            let takesBGRA: Bool
            var offeredFormats: [OSType] = []
            switch quality {
            case .lowLatency:
                let lowLatency = VTLowLatencySuperResolutionScalerConfiguration(
                    frameWidth: wanted.width, frameHeight: wanted.height, scaleFactor: wanted.scale)
                offeredFormats = lowLatency.supportedPixelFormats
                takesBGRA = offeredFormats.contains(kCVPixelFormatType_32BGRA)
                configuration = lowLatency
            case .high:
                // `usePrecomputedFlow: false` — we have no optical flow to give it, so it computes
                // its own per frame. That is the bulk of what makes this one expensive, and the
                // reason it may not hold a live frame rate at all.
                guard
                    let highQuality = VTSuperResolutionScalerConfiguration(
                        frameWidth: wanted.width, frameHeight: wanted.height,
                        scaleFactor: Int(wanted.scale), inputType: .video,
                        usePrecomputedFlow: false, qualityPrioritization: .normal,
                        revision: VTSuperResolutionScalerConfiguration.defaultRevision)
                else {
                    return latchOff("the quality super-resolution configuration was refused")
                }
                offeredFormats = highQuality.supportedPixelFormats
                takesBGRA = offeredFormats.contains(kCVPixelFormatType_32BGRA)
                configuration = highQuality
            }
            // The first format on our preference list the processor actually offers. BGRA when it
            // is there costs nothing; `420v` costs two colour conversions but is the only format
            // the low-latency processor accepts, so refusing it is refusing the feature.
            _ = takesBGRA
            guard let chosen = Self.usableFormats.first(where: offeredFormats.contains) else {
                let offered = offeredFormats.map(Self.fourCC).joined(separator: ", ")
                return latchOff(
                    "super resolution takes no format this pipeline can produce — it takes "
                        + "\(offered)")
            }
            surfaceFormat = (chosen, Self.metalFormat(for: chosen))
            if surfaceFormat.metal == nil {
                let name = Self.fourCC(chosen)
                log.info(
                    "Feed upscale: super resolution runs in \(name, privacy: .public), colour converted on both sides."
                )
            }
            if textureCache == nil {
                var cache: CVMetalTextureCache?
                CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, device, nil, &cache)
                textureCache = cache
            }
            let outputWidth = Int((Double(wanted.width) * Double(wanted.scale)).rounded())
            let outputHeight = Int((Double(wanted.height) * Double(wanted.scale)).rounded())
            // One pair per frame that can be in flight at once — see `encode`. Three is the
            // drawable queue's own depth, which is what bounds how many frames are outstanding.
            let built = (0..<3).compactMap { _ -> (input: Surface, output: Surface)? in
                guard
                    let input = makeSurface(
                        width: wanted.width, height: wanted.height,
                        attributes: configuration.sourcePixelBufferAttributes),
                    let output = makeSurface(
                        width: outputWidth, height: outputHeight,
                        attributes: configuration.destinationPixelBufferAttributes)
                else { return nil }
                return (input, output)
            }
            guard built.count == 3 else {
                return latchOff("super resolution surfaces could not be allocated")
            }

            // End the OLD session only, and start on a FRESH processor — never endSession() on a
            // just-created one. That pattern was the root of the whole failure arc; the full
            // account lives in `FrameDecoder.LiveFeedSuperResolution.prepare`.
            self.processor?.endSession()
            self.processor = nil
            let processor = VTFrameProcessor()
            do {
                try processor.startSession(configuration: configuration)
            } catch {
                return latchOff("super resolution session refused: \(error.localizedDescription)")
            }
            self.processor = processor
            surfaces = built
            nextSurface = 0
            key = wanted
            // The references belong to the session that produced them; a restart invalidates both.
            previousSource = nil
            previousOutput = nil
            asyncModel.withLock { $0 = AsyncModel() }
            // Same reason MetalFX logs its selection: neither path exists in the simulator, so a
            // device log line is the only confirmation of which upscaler the feed actually chose.
            let name = quality == .high ? "VT Super Res+ (quality)" : "VT Super Res (low latency)"
            log.info(
                """
                Feed upscale: \(name, privacy: .public) \
                \(wanted.width, privacy: .public)×\(wanted.height, privacy: .public) → \
                \(outputWidth, privacy: .public)×\(outputHeight, privacy: .public) \
                (×\(wanted.scale, privacy: .public))
                """)
            return true
        }

        /// Writes the bake into a planar input surface, converting colour and size in one pass.
        ///
        /// Synchronous, and deliberately so: it runs at the MODEL's input size (a few hundred
        /// pixels a side), not the panel's, and the alternative — teaching the baker to produce
        /// this buffer on its own thread — couples the bake to the model's geometry. That trade is
        /// worth making only if a device says this costs real frame time.
        private func writePlanarInput(
            from source: MTLTexture, to surface: Surface, size: (width: Int, height: Int)
        ) -> Bool {
            guard
                let image = CIImage(
                    mtlTexture: source, options: [.colorSpace: workingColorSpace])
            else { return false }
            let scaled = image.transformed(
                by: CGAffineTransform(
                    scaleX: CGFloat(size.width) / image.extent.width,
                    y: CGFloat(size.height) / image.extent.height))
            // No flip either way. Core Image's origin convention applies identically to the read
            // leg below, so the two cancel and the model simply sees the picture the same way
            // round on both sides — which a spatial upscaler is indifferent to.
            //
            // AWAITED, and that is the whole point of using a render task here rather than
            // `render(_:to:)`. That call is asynchronous: it returns before the GPU has written a
            // pixel. The model then read an input that was not there yet and dutifully upscaled
            // nothing, which in `420v` presents as flat green with no error anywhere — the buffer
            // was valid, the call succeeded, and the contents simply had not arrived.
            let destination = CIRenderDestination(pixelBuffer: surface.buffer)
            destination.colorSpace = workingColorSpace
            do {
                let task = try ciContext.startTask(
                    toRender: scaled,
                    from: CGRect(x: 0, y: 0, width: size.width, height: size.height),
                    to: destination,
                    at: .zero)
                try task.waitUntilCompleted()
            } catch {
                log.error(
                    "Feed upscale: input conversion failed — \(error.localizedDescription, privacy: .public)"
                )
                return false
            }
            return true
        }

        /// Converts the model's planar output back to an RGB texture the fit can present.
        private func readPlanarOutput(_ surface: Surface, commandBuffer: MTLCommandBuffer)
            -> MTLTexture?
        {
            readPlanarOutput(surface.buffer, commandBuffer: commandBuffer)
        }

        private func readPlanarOutput(_ buffer: CVPixelBuffer, commandBuffer: MTLCommandBuffer)
            -> MTLTexture?
        {
            let width = CVPixelBufferGetWidth(buffer)
            let height = CVPixelBufferGetHeight(buffer)
            if rgbOutput?.width != width || rgbOutput?.height != height {
                let descriptor = MTLTextureDescriptor.texture2DDescriptor(
                    pixelFormat: .bgra8Unorm, width: width, height: height, mipmapped: false)
                descriptor.usage = [.shaderRead, .shaderWrite, .renderTarget]
                descriptor.storageMode = .private
                rgbOutput = device.makeTexture(descriptor: descriptor)
            }
            guard let rgbOutput else { return nil }
            ciContext.render(
                CIImage(cvPixelBuffer: buffer),
                to: rgbOutput,
                commandBuffer: commandBuffer,
                bounds: CGRect(x: 0, y: 0, width: width, height: height),
                colorSpace: workingColorSpace)
            return rgbOutput
        }

        /// An IOSurface-backed BGRA buffer plus its texture view, meeting the processor's own
        /// attribute requirements for the side it is for.
        private func makeSurface(width: Int, height: Int, attributes: [String: Any]) -> Surface? {
            guard let textureCache else { return nil }
            // From a POOL built out of the processor's OWN attributes, which is what Apple's
            // guidance specifies — and the previous `CVPixelBufferCreate` did not do.
            //
            // That call took an explicit format argument, which OVERRIDES whatever the
            // configuration asked for, and a hand-merged dictionary that satisfied only the
            // requirements I happened to know about. The result was IOSurface-backed enough for
            // `VTFrameProcessorFrame` to accept it, so nothing ever errored — while apparently
            // missing something the processor needs, which is a silent no-op rather than a fault.
            //
            // Dimensions are ours; every other attribute, the pixel format included, is the
            // configuration's. The format is read back off the buffer rather than assumed.
            var resolved = attributes
            resolved[kCVPixelBufferWidthKey as String] = width
            resolved[kCVPixelBufferHeightKey as String] = height
            resolved[kCVPixelBufferMetalCompatibilityKey as String] = true
            if resolved[kCVPixelBufferIOSurfacePropertiesKey as String] == nil {
                resolved[kCVPixelBufferIOSurfacePropertiesKey as String] = [String: Any]()
            }
            var pool: CVPixelBufferPool?
            guard
                CVPixelBufferPoolCreate(
                    kCFAllocatorDefault, nil, resolved as CFDictionary, &pool) == kCVReturnSuccess,
                let pool
            else { return nil }
            var buffer: CVPixelBuffer?
            guard
                CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &buffer)
                    == kCVReturnSuccess,
                let buffer
            else { return nil }
            // Pools outlive the buffers they vend, so the surface holds one alive.
            let format = CVPixelBufferGetPixelFormatType(buffer)
            // A planar format has no single texture to bridge to; those surfaces are driven
            // through Core Image and carry no Metal view at all.
            guard let metal = Self.metalFormat(for: format) else {
                return Surface(buffer: buffer, pool: pool, bridge: nil, texture: nil)
            }
            var bridge: CVMetalTexture?
            guard
                CVMetalTextureCacheCreateTextureFromImage(
                    kCFAllocatorDefault, textureCache, buffer, nil, metal,
                    width, height, 0,
                    &bridge) == kCVReturnSuccess,
                let bridge, let texture = CVMetalTextureGetTexture(bridge)
            else { return nil }
            return Surface(buffer: buffer, pool: pool, bridge: bridge, texture: texture)
        }

        /// The Metal format for a `CVPixelBuffer` format we can hand the model, or nil for one we
        /// cannot bridge.
        ///
        /// Both entries are plain RGBA orderings, so moving between them is a format change and
        /// nothing more — Metal samples a `bgra8Unorm` texture as `(r,g,b,a)` floats already, so
        /// an MPS pass into a half-float destination writes the right channels with no swizzle and
        /// no colour maths. A YUV-only processor would have been a different piece of work.
        private static func metalFormat(for format: OSType) -> MTLPixelFormat? {
            switch format {
            case kCVPixelFormatType_32BGRA: return .bgra8Unorm
            case kCVPixelFormatType_64RGBAHalf: return .rgba16Float
            default: return nil
            }
        }

        /// Formats this pipeline can hand the model, best first.
        ///
        /// The RGB pair need no conversion at all — Metal writes them directly. `420v` does, and
        /// it is last for that reason, but it is on the list because it is the ONLY format the
        /// low-latency processor accepts: refusing it is refusing the feature.
        private static let usableFormats: [OSType] = [
            kCVPixelFormatType_32BGRA,
            kCVPixelFormatType_64RGBAHalf,
            kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
        ]

        /// A `CVPixelBufferPixelFormatType` as the four characters it actually is, because
        /// `875704422` in a log is unreadable and `420v` is the answer.
        private static func fourCC(_ format: OSType) -> String {
            let bytes = [24, 16, 8, 0].map { UInt8((format >> $0) & 0xFF) }
            let text = String(decoding: bytes, as: UTF8.self)
            return text.allSatisfy(\.isASCII) ? text : String(format)
        }

        private func latchOff(_ reason: String) -> Bool {
            unavailable = true
            log.error("\(reason, privacy: .public) — feed upscale falls back.")
            return false
        }

        /// Says why the selected upscaler is not the one on screen, once per reason.
        ///
        /// Every path out of `encode` is a silent fall back to Lanczos, which is indistinguishable
        /// from the setting not working — and neither this nor MetalFX can be exercised anywhere
        /// but a device, so a log line is the only way to tell those two apart.
        private func decline(_ reason: String) -> MTLTexture? {
            if reason != lastDecline {
                lastDecline = reason
                log.info(
                    "Feed upscale: Super Res declined — \(reason, privacy: .public). Using Lanczos."
                )
            }
            return nil
        }
    }
#endif
