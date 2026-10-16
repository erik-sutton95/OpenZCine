import CoreMedia
import CoreVideo
import Metal
import MetalKit
import OpenCineApple
import SwiftUI
import UIKit
import VideoToolbox
import os

import class OpenCineCameraVocabulary.CustomLUTStore

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
/// `MonitorFrameBaker.bakeSize`), so the present is a scale rather than a copy: one bilinear
/// sample per drawable pixel instead of a whole Core Image graph per drawable pixel.
///
/// Opt-in alternative to `LiveFrameView` (see `FeedRenderMode`). **Needs on-device validation** — the
/// vertical flip, crop, and colour-space handling below are correct by the documented pattern
/// but only a GPU capture against the live ZR confirms orientation/aspect/colour pixel-for-pixel.
struct MetalLiveView: UIViewRepresentable {
    let image: UIImage
    let effects: LiveImageEffects
    let fileStore: CustomLUTStore
    var source: LiveFrameSampleBus.Source? = nil
    var qualification: (@MainActor () -> MonitorNativeQualificationSnapshot?)? = nil

    func makeCoordinator() -> Coordinator { Coordinator(fileStore: fileStore) }

    func makeUIView(context: Context) -> MTKView {
        let view = MTKView(frame: .zero, device: context.coordinator.device)
        view.accessibilityIdentifier = "monitor.native.picture"
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
        context.coordinator.update(image: image, effects: effects, source: source)
        context.coordinator.attach(view: view)
        if let qualification {
            context.coordinator.qualificationProbe = MonitorNativeQualificationProbe.install(
                in: view
            ) {
                [weak coordinator = context.coordinator] in
                coordinator?.qualificationSnapshot(qualification)
            }
        }
        return view
    }

    func updateUIView(_ uiView: MTKView, context: Context) {
        let needsRedraw = context.coordinator.update(image: image, effects: effects, source: source)
        if let qualification {
            context.coordinator.qualificationProbe?.snapshot = {
                [weak coordinator = context.coordinator] in
                coordinator?.qualificationSnapshot(qualification)
            }
        }
        context.coordinator.noteDrawableSize(uiView.drawableSize)
        if needsRedraw {
            uiView.setNeedsDisplay()
        }
    }

    static func dismantleUIView(_ uiView: MTKView, coordinator: Coordinator) {
        uiView.delegate = nil
        coordinator.qualificationProbe?.snapshot = { nil }
        coordinator.qualificationProbe?.removeFromSuperview()
        coordinator.close()
    }

    /// Owns the Metal objects for the feed. Core Image baking runs off-main in `MetalFeedFrameBaker`;
    /// `draw(in:)` only scales the latest baked texture into the swapchain drawable.
    final class Coordinator: NSObject {
        let device: MTLDevice
        private let baker: MetalFeedFrameBaker
        private let presenter: MonitorMetalPicturePresenter
        private var currentImage: UIImage?
        private var currentSource: LiveFrameSampleBus.Source?
        private var currentEffects = LiveImageEffects()
        private weak var mtkView: MTKView?
        var qualificationProbe: MonitorNativeQualificationProbe?

        @MainActor func qualificationSnapshot(
            _ provider: @MainActor () -> MonitorNativeQualificationSnapshot?
        ) -> MonitorNativeQualificationSnapshot? {
            guard currentImage != nil, let currentSource, currentSource.isActive,
                let value = provider(),
                value.sourceIdentity == String(describing: ObjectIdentifier(currentSource))
            else { return nil }
            return value
        }

        init(fileStore: CustomLUTStore) {
            device = MTLCreateSystemDefaultDevice()!
            baker = MetalFeedFrameBaker(device: device, fileStore: fileStore)
            presenter = MonitorMetalPicturePresenter(
                device: device, baker: baker.native,
                logSubsystem: "OpenZCine", captureLabel: MetalCaptureLabels.liveFeed,
                enabled: { FeedRenderMode.metalFeedEnabled },
                options: {
                    MonitorPresentationOptions(
                        upscaler: MonitorUpscaler(
                            rawValue: FeedUpscaleSwitch.shared.upscaler.rawValue)
                            ?? .lanczos,
                        previewSuperResolutionInput:
                            FeedUpscaleSwitch.shared.presentsSuperResolutionInput,
                        resampling: .selectedUpscaler, exactCopyAtNativeSize: true)
                },
                qualityModelReady: { SuperResolutionModel.isReady })
            super.init()
            presenter.onDrawableSizeChanged = { [weak self] _ in self?.scheduleBake() }
            presenter.onPresentStart = { LiveViewSignposts.beginMetalFeedPresent() }
            presenter.onPresentEnd = { LiveViewSignposts.endMetalFeedPresent() }
        }

        @discardableResult
        func update(
            image: UIImage, effects: LiveImageEffects,
            source: LiveFrameSampleBus.Source? = nil
        ) -> Bool {
            let imageChanged = currentImage !== image
            let sourceChanged = currentSource !== source
            if sourceChanged { baker.reset() }
            currentSource = source
            let effectsChanged = currentEffects != effects
            currentImage = image
            currentEffects = effects
            if imageChanged || effectsChanged || sourceChanged { scheduleBake() }
            return imageChanged || effectsChanged || sourceChanged
        }

        func noteDrawableSize(_ size: CGSize) { presenter.noteDrawableSize(size) }
        @MainActor func attach(view: MTKView) {
            mtkView = view
            presenter.attach(view)
        }
        @MainActor func close() {
            mtkView = nil
            presenter.close()
        }
        private func scheduleBake() {
            let size = presenter.drawableSize
            guard let image = currentImage, size.width > 0, size.height > 0 else { return }
            baker.scheduleBake(
                image: image, effects: currentEffects, drawableSize: size,
                pixelFormat: .bgra8Unorm, source: currentSource,
                onComplete: { [weak mtkView] in
                    Task { @MainActor in mtkView?.setNeedsDisplay() }
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

/// Which upscaler the feed is using, set from the Link settings row.
///
/// Neither MetalFX nor VideoToolbox super resolution exists in the simulator, so what they buy can
/// only be judged on a device against a live feed, which makes a relaunch-free picker the only
/// honest way to compare them with the Lanczos floor on the same shot. The renderer reads
/// `shared.upscaler` once per encode rather than latching it at construction, so the next frame
/// carries the change. The store, its legacy-title migration and its lock-guarded renderer read
/// are the shared OpenCine preference (A2-78).
enum FeedUpscaleSwitch {
    static let shared = MonitorUpscalerPreference(
        storageKey: "OpenZCine.feedUpscaler",
        onChange: { ReliabilityDiagnostics.reporting.noteFeedUpscaler($0.rawValue) })
}
