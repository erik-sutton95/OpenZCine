import Metal
import MetalKit
import SwiftUI
import UIKit
import os

/// Opt-in selector for the live-view feed renderer. The default is the proven `UIImageView` path
/// (`LiveFrameView`); set the launch env var `ZC_METAL_FEED=1` on a Metal-capable device to use the
/// GPU-native `MetalLiveView`. Default-off so the experimental Metal path can never regress the
/// shipping feed — flip it on to validate on hardware with an Xcode GPU frame capture.
enum FeedRenderMode {
    static let useMetal: Bool = DemoHarness.metalFeed && MTLCreateSystemDefaultDevice() != nil

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
/// then blits into the `MTKView` drawable — no `createCGImage` GPU→CPU readback. Core Image cannot
/// write CAMetalLayer drawables directly (they lack `MTLTextureUsageShaderWrite`), so CI renders to
/// a private intermediate texture and a blit encoder copies to the swapchain texture for present.
///
/// Opt-in alternative to `LiveFrameView` (see `FeedRenderMode`). **Needs on-device validation** — the
/// vertical flip, aspect-fill, and colour-space handling below are correct by the documented pattern
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
        view.contentMode = .scaleAspectFill
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
    /// `draw(in:)` only blits the latest baked texture to the swapchain drawable.
    final class Coordinator: NSObject, MTKViewDelegate {
        let device: MTLDevice
        private let commandQueue: MTLCommandQueue
        private let baker: MetalFeedFrameBaker
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

                let width = max(1, Int(dstSize.width))
                let height = max(1, Int(dstSize.height))
                guard
                    let baked = baker.bakedTexture(
                        width: width, height: height, pixelFormat: view.colorPixelFormat),
                    let drawable = view.currentDrawable,
                    let commandBuffer = commandQueue.makeCommandBuffer()
                else { return }

                #if DEBUG
                    captureScope?.begin()
                #endif
                LiveViewSignposts.beginMetalFeedPresent()
                if let blit = commandBuffer.makeBlitCommandEncoder() {
                    blit.copy(
                        from: baked,
                        sourceSlice: 0,
                        sourceLevel: 0,
                        sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
                        sourceSize: MTLSize(width: width, height: height, depth: 1),
                        to: drawable.texture,
                        destinationSlice: 0,
                        destinationLevel: 0,
                        destinationOrigin: MTLOrigin(x: 0, y: 0, z: 0))
                    blit.endEncoding()
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
