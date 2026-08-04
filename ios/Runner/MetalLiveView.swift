import Metal
import MetalKit
import MetalPerformanceShaders
import SwiftUI
import UIKit
import os

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
        // keep the layer writable so future paths (or debugging) can sample the drawable if needed.
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
        /// Upscales the source-resolution bake to the drawable — see `MetalFeedFrameBaker.bakeSize`.
        /// A blit encoder cannot scale, and a fullscreen quad would need a new `.metal` file in the
        /// target; MPS needs neither and is already linked (`ScopeTraceMetalView`). Bilinear because
        /// that is what Core Image's own affine upscale did, so the image reads the same.
        private lazy var scaler = MPSImageBilinearScale(device: device)
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
                    // The bake carries the SOURCE's aspect (fit, never crop — see `bakeSize`),
                    // so the present letterboxes: uniform scale, centered, over a cleared
                    // drawable. When the aspects match this fills the drawable exactly and the
                    // clear is invisible; when they don't, the operator gets bars instead of
                    // lost frame edges (#115).
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
                    var transform = MPSScaleTransform(
                        scaleX: scale, scaleY: scale,
                        translateX: (Double(target.width) - Double(baked.width) * scale) / 2,
                        translateY: (Double(target.height) - Double(baked.height) * scale) / 2
                    )
                    withUnsafePointer(to: &transform) { pointer in
                        scaler.scaleTransform = pointer
                        scaler.encode(
                            commandBuffer: commandBuffer, sourceTexture: baked,
                            destinationTexture: target
                        )
                        scaler.scaleTransform = nil
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
