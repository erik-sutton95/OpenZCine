import CoreImage
import MonitorPresentation
import MonitorUI
import OpenCineAppKit
import OpenCineApple
import OpenCineCameraControls
import OpenCineCore
import OpenZCineCore
import SwiftUI
import UIKit

import class OpenCineCameraVocabulary.CustomLUTStore

/// Shared field-monitor chrome. Surfaces, type, and hairlines come from `MonitorTheme`, the same
/// tokens Pocket and Insta use. The accent is the OpenZCine gold assigned at launch
/// (`BrandColors.accentRGB`). Assist swatches that are not the brand accent stay on `amber`,
/// `info`, `good`, and `rec`.
enum LiveDesign {
    static let background = MonitorTheme.canvas
    static let surface = MonitorTheme.surface
    static let glass = MonitorTheme.surface
    static let glassOpaque = MonitorTheme.surface
    static let glassBright = MonitorTheme.raised
    static let hairline = MonitorTheme.border
    static let hairlineStrong = MonitorTheme.faint.opacity(0.5)
    static var text: Color { MonitorTheme.text }
    static var muted: Color { MonitorTheme.muted }
    static var faint: Color { MonitorTheme.faint }
    static var accent: Color { MonitorTheme.accent }
    static var accentDim: Color { MonitorTheme.accent.opacity(0.16) }
    static var good: Color {
        MonitorTheme.edrSRGB(red: 0.18, green: 0.78, blue: 0.42, gain: MonitorTheme.hdrGain)
    }
    static var rec: Color { MonitorTheme.recording }
    /// Cyan and blue assist previews. Not the brand accent.
    static var info: Color {
        MonitorTheme.edrSRGB(red: 0.10, green: 0.58, blue: 0.98, gain: MonitorTheme.hdrGain)
    }

    /// Standard height for the bottom control bars (assist toolbar + value strip).
    static let controlHeight: CGFloat = 58

    /// See `MonitorTheme.radius`, the single source of truth for rounded chrome surfaces.
    static let cornerRadius = MonitorTheme.radius
}

struct MonitorExperience: View {
    @Environment(NativeAppModel.self) private var model

    var body: some View {
        LiveViewShell()
            // App self-timer tally: a white border pulse each countdown second, readable
            // from in front of the camera alongside the beeper.
            .overlay {
                TimerTallyBorderOverlay()
            }
            // Instant playback covers the whole monitor — a focused look at the captured
            // frame, above every piece of chrome.
            .overlay {
                InstantReviewOverlay()
            }
            // The same explicit grant confirmation as the other watcher hosts. The captured
            // request retains its actual relay owner, source and control revision.
            .monitorRelayControlRequest(model.captureOperatorSettingsWatchers()?.request)
            // The shared controls own their feedback and the haptics preference (A1-33). The
            // focus-point app lock is Nikon's own: a firm thump locking, a light tap freeing.
            .sensoryFeedback(trigger: model.focusPointLocked) { _, locked in
                guard model.preferences.hapticsEnabled else { return nil }
                return locked ? .impact(weight: .heavy) : .impact(weight: .light)
            }
    }
}

private struct LiveViewShell: View {
    @Environment(NativeAppModel.self) private var model
    @Environment(\.monitorWindowGeometry) private var windowGeometry
    /// OBSERVED state, not a body-time read. The two landscapes are invisible to layout —
    /// same size, symmetric safe areas — so flipping between them changes nothing SwiftUI
    /// already watches, and a body-time read of the orientation stayed stale until some other
    /// invalidation (a DISP tap was the field repro) happened to rebuild the shell. Portrait
    /// transitions only ever worked because the SIZE change re-ran the body.
    @State private var orientationObserver = MonitorUI.InterfaceOrientationObserver()
    private var deviceOrientation: MonitorDeviceOrientation { orientationObserver.orientation }

    var body: some View {
        GeometryReader { proxy in
            let screenWidth = MonitorDeviceOrientationReader.currentViewportWidth()
            let context = LiveViewLayoutContext(
                proxy: proxy,
                deviceOrientation: deviceOrientation,
                screenWidth: screenWidth, windowGeometry: windowGeometry
            )

            // One view tree for both orientations, driven by the zone map: rotation is a geometry
            // change under stable view identity — the `.easeInOut(value: isPortrait)` glides every
            // module to its new frame. The shared root retains this native picture beneath covers.
            NikonMonitorShell(context: context)
                .environment(model)
                .animation(.easeInOut(duration: 0.3), value: context.isPortrait)
                // The landscape-to-landscape flip animates for the same reason the portrait one
                // does — the modules glide to their mirrored frames under stable identity.
                .animation(.easeInOut(duration: 0.3), value: context.horizontalDirection)
        }
        .ignoresSafeArea(.container, edges: .all)
        // Snappy panel insert/remove so dismissing a popup feels near-instant.
        .animation(.easeOut(duration: 0.10), value: model.activePanel)
        .animation(.easeInOut(duration: 0.18), value: model.displayMode)
        .onAppear { orientationObserver.start() }
        .onDisappear { orientationObserver.stop() }
    }
}

struct LiveViewLayoutContext {
    let feedSafeArea: MonitorEdgeInsets
    let chromeInsets: MonitorEdgeInsets
    let horizontalDirection: MonitorHorizontalLayoutDirection
    let viewportWidth: Double
    let topControlInset: Double
    /// True when the viewport is taller than it is wide — drives the portrait monitor shell.
    let isPortrait: Bool
    /// Full PHYSICAL viewport height for the portrait zone layout. The GeometryReader reports the
    /// safe-area frame, but the shell renders edge-to-edge and the shared `FieldMonitorLayout`
    /// subtracts the insets itself — restore them here (as `MonitorLiveViewViewport.fullWidth` does
    /// horizontally). Passing the safe-area height double-counts the insets: ~96pt dead band.
    let viewportHeight: Double

    @MainActor
    init(
        proxy: GeometryProxy, deviceOrientation: MonitorDeviceOrientation, screenWidth: Double?,
        windowGeometry: MonitorWindowGeometry = MonitorWindowGeometry()
    ) {
        let physical = windowGeometry.size.width > 0 && windowGeometry.size.height > 0
        // The root already observes the physical UIWindow. An edge-to-edge SwiftUI child may
        // report zero safe insets; pass the actual window insets without adding them to its size.
        feedSafeArea =
            physical
            ? MonitorEdgeInsets(
                top: windowGeometry.safeArea.top, leading: windowGeometry.safeArea.leading,
                bottom: windowGeometry.safeArea.bottom, trailing: windowGeometry.safeArea.trailing
            ) : proxy.monitorEdgeInsets
        isPortrait =
            physical
            ? windowGeometry.size.height > windowGeometry.size.width
            : proxy.size.height > proxy.size.width
        viewportHeight =
            physical
            ? windowGeometry.size.height
            : Double(proxy.size.height) + max(0, feedSafeArea.top) + max(0, feedSafeArea.bottom)
        chromeInsets = MonitorEdgeInsets.chrome(for: .zero).clearingWindowControls
        horizontalDirection = MonitorHorizontalLayoutDirection.resolve(
            deviceOrientation: deviceOrientation,
            safeArea: feedSafeArea
        )
        viewportWidth =
            physical
            ? windowGeometry.size.width
            : MonitorLiveViewViewport.fullWidth(
                layoutWidth: Double(proxy.size.width),
                safeArea: feedSafeArea,
                screenWidth: screenWidth,
                geometrySpace: .safeArea
            )
        topControlInset = Double(windowGeometry.topControlInset)
    }
}
@MainActor
private enum MonitorDeviceOrientationReader {
    static func currentViewportWidth() -> Double? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let scene =
            scenes.first { $0.activationState == .foregroundActive }
            ?? scenes.first { $0.activationState == .foregroundInactive }
            ?? scenes.first
        let width = scene?.coordinateSpace.bounds.width ?? 0

        return width > 0 ? Double(width) : nil
    }
}

struct LiveFeedModule: View {
    @Environment(NativeAppModel.self) private var model
    let viewportWidth: Double
    /// Portrait mounts hand the module an exact zone-frame height. The measured height is only
    /// trustworthy in the landscape full-bleed canvas: inside a safe-area-inset context the
    /// module's own `.ignoresSafeArea()` re-expands the proposal, the reader reports the grown
    /// height, and the derived 16:9 box renders oversized and shifted up — the fill-mode "cropped
    /// on top and right" bug. Nil (landscape) keeps the measured path unchanged.
    var fixedContentHeight: Double? = nil

    private struct PictureSource: Hashable {
        let monitor: UUID?
        let pictureKind: String
        let controlSession: CameraSessionID?
        let controlEpoch: ControlEpoch?
    }
    private var pictureSource: PictureSource {
        .init(
            monitor: model.shell.monitor?.id, pictureKind: model.videoSource.rawValue,
            controlSession: model.shell.control.snapshot?.session,
            controlEpoch: model.shell.control.snapshot?.epoch)
    }
    private var presentationScale: CGSize {
        MirrorAssist.feedScale(
            mirrored: model.liveFeedMirrored,
            flippedVertically: model.liveFeedMirroredVertically,
            squeeze: desqueezeScale(model.liveDesqueeze))
    }
    /// The shared surface's admission, applied to the picture's own focus, zoom and swipe.
    private var pictureInteractive: Bool {
        !model.interfaceLocked && model.chromeEditorMode == nil && model.operatorSession.interactive
            && model.activePanel?.coversFullScreen != true && model.displayMode != .command
    }

    var body: some View {
        ZStack(alignment: .leading) {
            LiveDesign.background

            GeometryReader { proxy in
                // Vertical mode: the body is on its side (header byte 839), so the DISPLAYED
                // frame is the source frame's inverse aspect and the picture rotates upright
                // inside it. The rotation wraps the whole feed stack — raster, AF boxes, zoom,
                // gestures — so every existing coordinate mapping keeps operating in the
                // camera's own (pre-rotation) space.
                // The shared canvas already fitted the picture (source aspect, rotation, HDMI
                // shape); the native raster only fills it.
                let feedRotation = model.displayedFeedRotation
                let imageWidth = CGFloat(viewportWidth)
                let imageHeight = CGFloat(fixedContentHeight ?? Double(proxy.size.height))
                ZStack(alignment: .leading) {
                    Color.black
                    rotatedFeedImage(
                        width: imageWidth, height: imageHeight, rotation: feedRotation)
                }
                .frame(width: imageWidth, height: imageHeight, alignment: .leading)
                .position(x: imageWidth / 2, y: imageHeight / 2)
                .frame(
                    width: CGFloat(viewportWidth),
                    height: CGFloat(fixedContentHeight ?? Double(proxy.size.height)),
                    alignment: .topLeading
                )
                // Portrait's fixed band clips the small-overflow vertical fill (core layout's
                // width-bound frame) instead of letting it paint over the chrome above/below.
                // Landscape full-bleed must stay unclipped — its safe-area escape depends on it.
                .modifier(ClipToBandWhenFixed(active: fixedContentHeight != nil))
            }
        }
        // The safe-area escape belongs to the landscape full-bleed mount only; with a fixed
        // content height (portrait), it would re-expand the proposal and shift the box up.
        .modifier(FullBleedWhenMeasured(active: fixedContentHeight == nil))
    }

    /// Clips the feed container to its band only when portrait hands it a fixed height; the
    /// landscape full-bleed mount keeps its unbounded overflow (safe-area escape).
    private struct ClipToBandWhenFixed: ViewModifier {
        let active: Bool
        @ViewBuilder func body(content: Content) -> some View {
            if active {
                content.clipped()
            } else {
                content
            }
        }
    }

    /// Lays the feed stack out in the camera's own frame (width/height swapped when the body is
    /// vertical), then rotates it upright into the displayed footprint. Gesture locations report
    /// in the pre-rotation space, so tap-to-focus and the AF overlay need no coordinate changes.
    /// One structure for every rotation (landscape rotates by zero), so turning the body keeps
    /// the picture's zoom, pinch and focus hold (A1-34).
    private func rotatedFeedImage(
        width: CGFloat, height: CGFloat, rotation: PTPLiveViewRotation
    ) -> some View {
        let swap = rotation.isVertical
        return feedImage(width: swap ? height : width, height: swap ? width : height)
            .rotationEffect(.degrees(rotation.displayDegreesClockwise))
            .frame(width: width, height: height)
    }

    @ViewBuilder private func feedImage(width: CGFloat, height: CGFloat) -> some View {
        let size = CGSize(width: width, height: height)
        let captured = pictureSource
        let capturedScale = presentationScale
        MonitorInteractivePicture(
            source: captured, size: size, maximumZoom: 8,
            enabled: pictureInteractive,
            focus: MonitorPictureFocusInteraction(
                locked: model.focusPointLocked,
                current: {
                    pictureSource == captured && presentationScale == capturedScale
                        && pictureInteractive
                },
                tap: { model.setFocusPoint(at: $0, feedSize: size) },
                toggleLock: model.toggleFocusPointLock),
            swipe: { direction in
                if pictureSource == captured && presentationScale == capturedScale
                    && pictureInteractive
                {
                    switch direction {
                    case .hide: model.setDisplayMode(.clean)
                    case .show: model.setDisplayMode(.live)
                    case .none: break
                    }
                }
            }, presentationScale: capturedScale
        ) { progress in
            ZStack {
                LiveFrameRaster(width: width, height: height)
                LiveFeedFocusOverlay(lockProgress: progress)
                if model.demoUIMode {
                    DemoFocusPointerSurface(model: model, size: size)
                }
            }
        }
        .overlay { FeedAlignedAssists() }
    }

}

/// Feed raster only — observes the frame plus display effects; sibling overlays remain isolated.
private struct LiveFrameRaster: View {
    @Environment(NativeAppModel.self) private var model
    let width: CGFloat
    let height: CGFloat

    var body: some View {
        LiveFrameFeedLayer(
            // The MockFeed still is a demo-only stand-in; a real session pre-first-frame shows the
            // feed layer's own blank state rather than a marketing image.
            image: model.liveFrameImage
                ?? (model.isDemoSession ? UIImage(named: "MockFeed") : nil),
            effects: model.liveImageEffects,
            source: model.liveFrameSource,
            isDemoSession: model.isDemoSession,
            fileStore: model.lutFileStore,
            width: width,
            height: height,
            qualification: { [weak model] in model?.nativeQualificationSnapshot }
        )
        .scaleEffect(feedScale, anchor: .center)
        .clipped()
    }

    /// De-squeeze and mirror are the same kind of thing — a transform of the raster alone — so they
    /// ride one `scaleEffect`. The selected axes are negative X and Y scales, which is
    /// why it lands here and not in the effects graph: this node is above BOTH feed renderers, so
    /// the Metal path and the `UIImageView` fallback flip identically and neither had to learn it.
    ///
    /// Sibling overlays are deliberately outside this: guides, grid and crosshair are symmetric so
    /// a flip would not show, and the horizon reads the phone's own gyro rather than the picture —
    /// mirroring it would be wrong. The AF boxes DO describe positions in the picture and are
    /// handled where they are drawn.
    private var feedScale: CGSize {
        let squeeze = desqueezeScale(model.liveDesqueeze)
        return MirrorAssist.feedScale(
            mirrored: model.liveFeedMirrored,
            flippedVertically: model.liveFeedMirroredVertically, squeeze: squeeze)
    }
}

/// Applies the landscape full-bleed safe-area escape only when the feed module measures its own
/// height (`active`); fixed-height (portrait) mounts skip it so the proposal cannot re-expand.
private struct FullBleedWhenMeasured: ViewModifier {
    let active: Bool

    func body(content: Content) -> some View {
        if active {
            content.ignoresSafeArea()
        } else {
            content
        }
    }
}

/// Metal / UIImageView feed. Real CPU-fallback live frames arrive pre-baked from the stream loop;
/// static demo frames need their effects baked here because they never pass through that loop.
private struct LiveFrameFeedLayer: View {
    let image: UIImage?
    let effects: LiveImageEffects
    let source: LiveFrameSampleBus.Source?
    let isDemoSession: Bool
    let fileStore: CustomLUTStore
    let width: CGFloat
    let height: CGFloat
    let qualification: (@MainActor () -> MonitorNativeQualificationSnapshot?)?
    @State private var metalFeedEnabled = FeedRenderMode.metalFeedEnabled

    var body: some View {
        Group {
            if let image {
                if metalFeedEnabled {
                    MetalLiveView(
                        image: image, effects: effects, fileStore: fileStore, source: source,
                        qualification: qualification
                    )
                } else if isDemoSession {
                    DemoProcessedLiveFrameView(
                        image: image, effects: effects, fileStore: fileStore)
                } else {
                    LiveFrameView(image: image)
                }
            } else {
                Color.black
            }
        }
        .frame(width: width, height: height)
        .onReceive(NotificationCenter.default.publisher(for: .metalFeedDisabled)) { _ in
            metalFeedEnabled = FeedRenderMode.metalFeedEnabled
        }
    }
}

/// CPU fallback for static demo stills. Camera frames are baked by the streaming loop, but demo
/// images have no loop, so without this view a Metal fallback displayed the raw image while the
/// toolbar and false-colour legend misleadingly remained active.
private struct DemoProcessedLiveFrameView: UIViewRepresentable {
    let image: UIImage
    let effects: LiveImageEffects
    let fileStore: CustomLUTStore

    func makeCoordinator() -> Coordinator { Coordinator(fileStore: fileStore) }

    func makeUIView(context: Context) -> UIImageView {
        let view = UIImageView()
        view.accessibilityIdentifier = "monitor.native.picture"
        // Fit, never fill: an aspect mismatch letterboxes instead of cropping (#115).
        view.contentMode = .scaleAspectFit
        view.clipsToBounds = true
        // Match `LiveFrameView`: the 4K still's intrinsic size must not expand this representable
        // beyond SwiftUI's feed frame and turn the outer clip into an accidental digital zoom.
        view.setContentHuggingPriority(.defaultLow, for: .horizontal)
        view.setContentHuggingPriority(.defaultLow, for: .vertical)
        view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        view.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
        context.coordinator.update(view: view, image: image, effects: effects)
        return view
    }

    func updateUIView(_ uiView: UIImageView, context: Context) {
        context.coordinator.update(view: uiView, image: image, effects: effects)
    }

    @MainActor
    final class Coordinator {
        private let renderer: LiveFrameRenderer
        private var renderTask: Task<Void, Never>?
        private var currentImage: UIImage?
        private var currentEffects: LiveImageEffects?

        init(fileStore: CustomLUTStore) {
            renderer = LiveFrameRenderer(fileStore: fileStore)
        }

        func update(view: UIImageView, image: UIImage, effects: LiveImageEffects) {
            guard currentImage !== image || currentEffects != effects else { return }
            currentImage = image
            currentEffects = effects
            renderTask?.cancel()
            guard !effects.isIdentity else {
                view.image = image
                return
            }
            renderTask = Task { @MainActor [weak view] in
                let rendered = await renderer.renderStaticFrame(image, effects: effects)
                guard !Task.isCancelled else { return }
                view?.image = rendered
            }
        }

        deinit {
            renderTask?.cancel()
        }
    }
}

/// Demo-UI-mode pointer stage over the feed (⌘D in a demo session): dragging the eye marker moves it
/// inside the main AF box; dragging anywhere else moves the main box and carries a visible eye with
/// it. The keyboard's 8 key toggles the eye marker, avoiding Simulator button-routing ambiguity.
private struct DemoFocusPointerSurface: UIViewRepresentable {
    let model: NativeAppModel
    let size: CGSize

    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.backgroundColor = .clear
        let pan = UIPanGestureRecognizer(
            target: context.coordinator, action: #selector(Coordinator.primaryPan(_:)))
        pan.maximumNumberOfTouches = 1
        view.addGestureRecognizer(pan)
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        context.coordinator.model = model
        context.coordinator.size = size
    }

    func makeCoordinator() -> Coordinator { Coordinator(model: model, size: size) }

    @MainActor final class Coordinator: NSObject {
        var model: NativeAppModel
        var size: CGSize
        private var dragTarget = DemoFocusDragTarget.focus

        init(model: NativeAppModel, size: CGSize) {
            self.model = model
            self.size = size
        }

        @objc func primaryPan(_ gesture: UIPanGestureRecognizer) {
            guard let view = gesture.view else { return }
            let location = gesture.location(in: view)
            if gesture.state == .began {
                dragTarget = model.demoFocusDragTarget(at: location, feedSize: size)
            }
            switch dragTarget {
            case .focus:
                model.demoMoveFocusBox(to: location, feedSize: size)
            case .eye:
                model.demoMoveEyeBox(to: location, feedSize: size)
            }
        }
    }
}

/// Post-capture instant playback: the just-captured still, full-screen over the entire monitor
/// chrome for the configured review duration (until tapped when ∞) — a focused look at the
/// frame, not another chrome state. Optional overlays: the AF box the shot focused with, and a
/// capture-settings line. A tap anywhere — or the close control — dismisses.
/// Pulses a white screen border once per app-timer countdown second (and once on arm), so
/// the phone reads as a tally light from in front of the lens. Purely decorative — never
/// intercepts touches.
struct TimerTallyBorderOverlay: View {
    @Environment(NativeAppModel.self) private var model
    @State private var flashOpacity: Double = 0

    /// Approximate physical display corner radius by device class (safe-area heuristic — no
    /// private display APIs): Dynamic-Island bodies ≈55pt, notch bodies ≈41.5pt, flat screens
    /// square. Close enough that the pulse reads as the screen's own edge lighting up.
    private var displayCornerRadius: CGFloat {
        let insets =
            UIApplication.shared.connectedScenes
            .compactMap { ($0 as? UIWindowScene)?.keyWindow?.safeAreaInsets }
            .first ?? .zero
        let maxInset = max(max(insets.top, insets.bottom), max(insets.left, insets.right))
        if maxInset >= 59 { return 55 }
        if maxInset >= 44 { return 41.5 }
        return 0
    }

    var body: some View {
        RoundedRectangle(cornerRadius: displayCornerRadius, style: .continuous)
            .strokeBorder(Color.white.opacity(flashOpacity), lineWidth: 5)
            .ignoresSafeArea()
            .allowsHitTesting(false)
            .onChange(of: model.stillTimerRemaining) { _, remaining in
                guard remaining != nil else {
                    flashOpacity = 0
                    return
                }
                var transaction = Transaction()
                transaction.disablesAnimations = true
                withTransaction(transaction) { flashOpacity = 0.95 }
                withAnimation(.easeOut(duration: 0.55)) { flashOpacity = 0 }
            }
    }
}

struct InstantReviewOverlay: View {
    @Environment(NativeAppModel.self) private var model
    /// Freshly captured shots start unfavourited; resets per review.
    @State private var reviewFavorited = false

    var body: some View {
        if let review = model.instantReview {
            ZStack(alignment: .topTrailing) {
                Color.black
                GeometryReader { proxy in
                    // Fit the de-squeezed size rather than scaling after the fit: the AF boxes
                    // below derive their scale from `fitted`, so de-squeezing here carries them
                    // with the image instead of leaving them on the squeezed geometry.
                    let fitted = Self.fittedRect(
                        image: desqueezedSize(
                            review.image.size, model.liveDesqueeze),
                        container: proxy.size)
                    // The stand-in thumb shows blurred; the upgrade animates the blur away
                    // as the full image swaps underneath, reading as one continuous sharpen.
                    Image(uiImage: review.image)
                        .resizable()
                        .frame(width: fitted.width, height: fitted.height)
                        .position(x: fitted.midX, y: fitted.midY)
                        .blur(radius: review.isFullResolution ? 0 : 14, opaque: true)
                        .clipped()
                    if model.assistConfiguration.instantReviewShowsFocusPoint,
                        let focus = review.focus, focus.coordinateWidth > 0,
                        focus.coordinateHeight > 0
                    {
                        // The same marks as the live AF box: the picture here is already fitted.
                        LiveFocusBoxOverlay(focus: focus)
                            .frame(width: fitted.width, height: fitted.height)
                            .position(x: fitted.midX, y: fitted.midY)
                    }
                }
                if !review.isFullResolution {
                    ZStack {
                        ProgressView()
                            .progressViewStyle(.circular)
                            .tint(LiveDesign.text.opacity(0.9))
                            .scaleEffect(1.4)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .transition(.opacity)
                }
                VStack(spacing: 10) {
                    Spacer()
                    if review.handle != nil {
                        // Single-tap favourite (a one-star flag on the card) — the between-
                        // shots keep/toss call. The full 1-5 rating lives in playback.
                        Button {
                            let previous = reviewFavorited
                            reviewFavorited.toggle()
                            let target = reviewFavorited ? 1 : 0
                            Task {
                                if await !model.rateInstantReview(stars: target) {
                                    reviewFavorited = previous
                                }
                            }
                        } label: {
                            Image(systemName: reviewFavorited ? "star.fill" : "star")
                                .font(.system(size: 19, weight: .semibold))
                                .foregroundStyle(
                                    reviewFavorited
                                        ? LiveDesign.accent : LiveDesign.text.opacity(0.85)
                                )
                                .frame(width: 42, height: 42)
                                .liquidGlass(in: Circle(), interactive: true)
                        }
                        .buttonStyle(.monitorTapTarget)
                    }
                    if model.assistConfiguration.instantReviewShowsCaptureInfo,
                        let info = review.infoLine
                    {
                        Text(info)
                            .font(.system(size: 13, weight: .semibold, design: .monospaced))
                            .foregroundStyle(LiveDesign.text.opacity(0.85))
                            .padding(.horizontal, 14)
                            .padding(.vertical, 7)
                            .liquidGlass(in: Capsule())
                    }
                }
                .padding(.bottom, 14)
                .frame(maxWidth: .infinity)
                CloseButton { model.dismissInstantReview() }
                    .padding(14)
            }
            .animation(.easeInOut(duration: 0.4), value: review.isFullResolution)
            .onChange(of: review.handle) { _, _ in reviewFavorited = false }
            .onAppear { reviewFavorited = false }
            .contentShape(Rectangle())
            .onTapGesture { model.dismissInstantReview() }
            .transition(.opacity)
            .ignoresSafeArea()
        }
    }

    /// Aspect-fit rect for the image inside the container.
    private static func fittedRect(image: CGSize, container: CGSize) -> CGRect {
        guard image.width > 0, image.height > 0, container.width > 0, container.height > 0
        else { return .zero }
        let scale = min(container.width / image.width, container.height / image.height)
        let size = CGSize(width: image.width * scale, height: image.height * scale)
        return CGRect(
            x: (container.width - size.width) / 2,
            y: (container.height - size.height) / 2,
            width: size.width,
            height: size.height
        )
    }
}

/// Why a relay picture is missing and how to get it back, under the shared waiting plate. The
/// watchdog is already retrying; the button is for the human who wants it now.
struct RelayJoinRecovery: View {
    @Environment(NativeAppModel.self) private var model

    var body: some View {
        if let reason = model.relayFailureReason {
            VStack(spacing: 10) {
                Text(reason)
                    .font(.system(size: 12, weight: .regular, design: .rounded))
                    .multilineTextAlignment(.center)
                    .foregroundStyle(LiveDesign.text.opacity(0.55))
                    .fixedSize(horizontal: false, vertical: true)
                if model.relayJoinNeedsPasscode {
                    RelayJoinPasscodeEntry()
                } else {
                    Button {
                        model.retryRelayJoin()
                    } label: {
                        Text("Try again")
                            .font(.system(size: 13, weight: .semibold, design: .rounded))
                            .foregroundStyle(LiveDesign.text.opacity(0.8))
                            .padding(.horizontal, 18)
                            .padding(.vertical, 8)
                            .background(Capsule().fill(LiveDesign.text.opacity(0.12)))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }
}

/// The watcher's ask/give-back, on the glass where the watching happens — control is exercised
/// mid-take, not inside a settings sheet. One pill reflecting the token, so the control and its
/// state cannot disagree. Mounted from the zone-aware chrome overlay (MonitorUnified), which
/// knows the assist toolbar's band — a feed-anchored bottom-center mount sat INSIDE that band
/// in landscape, half-under the toolbar.
struct WatcherControlKey: View {
    @Environment(NativeAppModel.self) private var model

    var body: some View {
        MonitorWatcherControlKey(
            title: model.relayHoldsControl ? "GIVE BACK CONTROL" : "ASK FOR CONTROL",
            accented: model.relayHoldsControl, palette: LiveDesign.self
        ) {
            if model.relayHoldsControl {
                model.releaseRelayControl()
            } else {
                model.requestRelayControl()
            }
        }
    }
}

/// The broadcaster's side of the token, where the watcher's pill sits on their glass: while a
/// watcher holds control this device's camera keys stand down, and this is the way back. The
/// reclaim needs no cooperation from the holder — this device owns the session.
struct BroadcasterControlKey: View {
    @Environment(NativeAppModel.self) private var model

    var body: some View {
        MonitorWatcherControlKey(
            title: "REVOKE CONTROL", accented: true, holderName: model.relayControlHeldBy,
            palette: LiveDesign.self
        ) {
            model.reclaimRelayControl()
        }
    }
}

/// The broadcast asked for a passcode: the shared watcher rule, the same secure field and Join as
/// the other apps' watchers. Any non-empty answer is sent, trimmed; the host decides. Lives on the
/// empty feed where the refusal reason is already showing.
private struct RelayJoinPasscodeEntry: View {
    @Environment(NativeAppModel.self) private var model
    @State private var draft = ""
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 8) {
            SecureField("Passcode", text: $draft)
                .submitLabel(.join)
                .onSubmit(join)
                .multilineTextAlignment(.center)
                .font(.system(size: 17, weight: .semibold, design: .rounded))
                .foregroundStyle(LiveDesign.text.opacity(0.9))
                .frame(width: 150)
                .padding(.vertical, 8)
                .background(RoundedRectangle(cornerRadius: 10).fill(LiveDesign.text.opacity(0.12)))
                .focused($focused)
                .onAppear { focused = true }
            Button("Join", action: join)
                .font(.system(size: 13, weight: .semibold, design: .rounded))
                .foregroundStyle(LiveDesign.text.opacity(0.8))
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .background(Capsule().fill(LiveDesign.text.opacity(0.12)))
                .buttonStyle(.plain)
                .disabled(MonitorWatcherPasscodeRule.answer(draft) == nil)
        }
    }

    private func join() {
        guard let code = MonitorWatcherPasscodeRule.answer(draft) else { return }
        model.submitRelayPasscode(code)
        draft = ""
    }
}

/// Renders the live-view feed through a single long-lived `UIImageView`: the streaming loop swaps
/// `model.liveFrameImage` ~30×/sec with a display-ready bitmap, and reusing one view keeps
/// live-view memory flat over long sessions. `.scaleAspectFit` + clipping keeps a mismatched picture whole (#115).
private struct LiveFrameView: UIViewRepresentable {
    let image: UIImage

    func makeUIView(context: Context) -> UIImageView {
        let view = UIImageView()
        view.accessibilityIdentifier = "monitor.native.picture"
        // Fit, never fill: an aspect mismatch letterboxes instead of cropping (#115).
        view.contentMode = .scaleAspectFit
        view.clipsToBounds = true
        // Let SwiftUI's frame drive the size rather than the image's intrinsic size.
        view.setContentHuggingPriority(.defaultLow, for: .horizontal)
        view.setContentHuggingPriority(.defaultLow, for: .vertical)
        view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        view.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
        view.image = image
        return view
    }

    func updateUIView(_ uiView: UIImageView, context: Context) {
        if uiView.image !== image { uiView.image = image }
    }
}
