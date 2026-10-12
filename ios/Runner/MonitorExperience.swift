import CoreImage
import MonitorPresentation
import MonitorUI
import OpenCineApple
import OpenCineAppKit
import OpenCineCameraControls
import OpenCineCore
import OpenZCineCore
import SwiftUI
import UIKit

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
            // A watcher asking to drive the camera prompts HERE, on the live view — the Share
            // This Feed panel answers requests too, but a panel is closed almost always, and a
            // request only visible there is one nobody sees until the viewer gives up.
            .overlay(alignment: .top) {
                RelayControlRequestOverlay()
                    .animation(
                        .easeOut(duration: 0.2), value: model.relayPendingControlRequest)
            }
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
                    FeedVignette()
                    FeedGrain()
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
    @ViewBuilder private func rotatedFeedImage(
        width: CGFloat, height: CGFloat, rotation: PTPLiveViewRotation
    ) -> some View {
        if rotation == .landscape {
            feedImage(width: width, height: height)
        } else {
            let swap = rotation.isVertical
            feedImage(width: swap ? height : width, height: swap ? width : height)
                .rotationEffect(.degrees(rotation.displayDegreesClockwise))
                .frame(width: width, height: height)
        }
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
        .overlay { FeedAlignedAssists(clean: model.displayMode == .clean) }
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
    let fileStore: LUTFileStore
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
    let fileStore: LUTFileStore

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

        init(fileStore: LUTFileStore) {
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

/// AF / subject-detection boxes — isolated from per-frame feed publishes.
private struct LiveFeedFocusOverlay: View {
    @Environment(NativeAppModel.self) private var model
    let lockProgress: CGFloat

    var body: some View {
        // The AF box is an element like any other: on by default in DISP 1 and DISP 2 (focus
        // feedback the operator relies on even in the stripped-back view), and hideable in both.
        // (Command never mounts the feed, so no mode guard is needed.)
        if model.chromeSectionMounts(.focusBox), let focus = model.liveViewFocus,
            !focus.boxes.isEmpty
        {
            // Focus metadata repeats identically on most frames — the Equatable guard skips the
            // Canvas redraw unless a box, lock, or progress changed.
            LiveFocusBoxOverlay(
                focus: focus, locked: model.focusPointLocked, lockProgress: lockProgress,
                mirrored: model.liveFeedMirrored,
                mirroredVertically: model.liveFeedMirroredVertically,
                // The raster's own value: the box has to register with the picture as
                // `LiveFrameRaster.feedScale` actually presents it.
                desqueeze: model.liveDesqueeze
            )
            .equatable()
            // `chromeEditable` cannot carry the dim here: it goes on a proxy sized to the box (see
            // below), and this Canvas draws the boxes itself.
            .opacity(focusBoxEditDimmed ? 0.3 : 1)
            // The badge goes on the primary AF box, not the whole feed — a dashed outline round
            // the entire image would name nothing.
            .overlay { focusBoxEditTarget(focus) }
        }
    }

    /// The AF box is force-mounted while editing a mode that has it switched off — dim it so the
    /// operator sees it is off and can switch it back on from its badge.
    private var focusBoxEditDimmed: Bool {
        guard let mode = model.chromeEditorMode,
            MonitorDisplayChrome.isConfigurable(.focusBox, in: mode)
        else { return false }
        return !model.operatorSession.chrome(for: mode).focusBox
    }

    /// A zero-content proxy sized to the primary AF box, so the Edit view's outline and badge land
    /// on the box the operator sees. Mounted only while editing.
    @ViewBuilder private func focusBoxEditTarget(_ focus: PTPLiveViewFocusInfo) -> some View {
        if model.chromeEditorMode != nil, let box = focus.boxes.first {
            GeometryReader { proxy in
                // Through the drawing mapping, so the badge lands on the box the operator sees
                // rather than on where an unmirrored, un-de-squeezed one would have been.
                if let rect = liveFocusBoxRect(
                    box, focus: focus, in: proxy.size,
                    desqueeze: model.liveDesqueeze,
                    mirrored: model.liveFeedMirrored,
                    mirroredVertically: model.liveFeedMirroredVertically)
                {
                    Color.clear
                        .frame(width: rect.width, height: rect.height)
                        .chromeEditable(.focusBox, editing: model.chromeEditorMode)
                        .position(x: rect.midX, y: rect.midY)
                }
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
                        ForEach(Array(focus.boxes.enumerated()), id: \.offset) { _, box in
                            let scaleX = fitted.width / CGFloat(focus.coordinateWidth)
                            let scaleY = fitted.height / CGFloat(focus.coordinateHeight)
                            Rectangle()
                                .strokeBorder(
                                    focus.focusResult == .focused
                                        ? Color.green : Color.white.opacity(0.9),
                                    lineWidth: 2
                                )
                                .frame(
                                    width: max(10, CGFloat(box.width) * scaleX),
                                    height: max(10, CGFloat(box.height) * scaleY)
                                )
                                .position(
                                    x: fitted.minX + CGFloat(box.centerX) * scaleX,
                                    y: fitted.minY + CGFloat(box.centerY) * scaleY
                                )
                        }
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

/// The broadcaster's control-request prompt, floated over the live view.
///
/// Kept to one line plus two answers: the operator is mid-shot, so the prompt must be
/// answerable without reading a paragraph — and it must never cover the middle of the frame.
private struct RelayControlRequestOverlay: View {
    @Environment(NativeAppModel.self) private var model

    var body: some View {
        if model.isRelayBroadcasting, let requester = model.relayPendingControlRequest {
            HStack(spacing: 12) {
                Image(systemName: "dot.radiowaves.left.and.right")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(LiveDesign.accent)
                Text("\(requester) asks to control the camera")
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .foregroundStyle(LiveDesign.text)
                    .lineLimit(1)
                Button {
                    model.declineRelayControl()
                } label: {
                    Text("Decline")
                        .font(.system(size: 12, weight: .semibold, design: .rounded))
                        .foregroundStyle(LiveDesign.muted)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(Capsule().stroke(LiveDesign.hairlineStrong, lineWidth: 1))
                }
                .buttonStyle(.plain)
                Button {
                    model.grantRelayControl()
                } label: {
                    Text("Grant")
                        .font(.system(size: 12, weight: .bold, design: .rounded))
                        .foregroundStyle(LiveDesign.background)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 6)
                        .background(Capsule().fill(LiveDesign.accent))
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(LiveDesign.glassOpaque)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(LiveDesign.hairline, lineWidth: 1)
            )
            // Below the top-bar chip row in both orientations; never near frame centre.
            .padding(.top, 64)
            .transition(.move(edge: .top).combined(with: .opacity))
        }
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
        Button {
            if model.relayHoldsControl {
                model.releaseRelayControl()
            } else {
                model.requestRelayControl()
            }
        } label: {
            Text(model.relayHoldsControl ? "GIVE BACK CONTROL" : "ASK FOR CONTROL")
                .font(.system(size: 12, weight: .bold, design: .rounded))
                .kerning(0.8)
                .foregroundStyle(model.relayHoldsControl ? LiveDesign.accent : LiveDesign.text)
                .padding(.horizontal, 16)
                .padding(.vertical, 9)
                .background(.black.opacity(0.55), in: Capsule())
                .overlay(
                    Capsule().strokeBorder(
                        model.relayHoldsControl ? LiveDesign.accent : LiveDesign.hairline,
                        lineWidth: 1))
        }
        .buttonStyle(.monitorTapTarget)
        .transition(.scale(scale: 0.9).combined(with: .opacity))
    }
}

/// The broadcaster's side of the token, where the watcher's pill sits on their glass: while a
/// watcher holds control this device's camera keys stand down, and this is the way back. The
/// reclaim needs no cooperation from the holder — this device owns the session.
struct BroadcasterControlKey: View {
    @Environment(NativeAppModel.self) private var model

    var body: some View {
        Button {
            model.reclaimRelayControl()
        } label: {
            HStack(spacing: 8) {
                Text("REVOKE CONTROL")
                    .font(.system(size: 12, weight: .bold, design: .rounded))
                    .kerning(0.8)
                    .foregroundStyle(LiveDesign.accent)
                if let holder = model.relayControlHeldBy {
                    Text(holder)
                        .font(.system(size: 12, weight: .semibold, design: .rounded))
                        .foregroundStyle(LiveDesign.text.opacity(0.7))
                        .lineLimit(1)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 9)
            .background(.black.opacity(0.55), in: Capsule())
            .overlay(Capsule().strokeBorder(LiveDesign.accent, lineWidth: 1))
        }
        .buttonStyle(.monitorTapTarget)
        .transition(.scale(scale: 0.9).combined(with: .opacity))
    }
}

/// The broadcast asked for a passcode: four digits, joined on completion. Lives on the empty
/// feed where the refusal reason is already showing.
private struct RelayJoinPasscodeEntry: View {
    @Environment(NativeAppModel.self) private var model
    @State private var draft = ""
    @FocusState private var focused: Bool

    var body: some View {
        TextField("0000", text: $draft)
            .keyboardType(.numberPad)
            .textContentType(.oneTimeCode)
            .multilineTextAlignment(.center)
            .font(.system(size: 22, weight: .semibold, design: .monospaced))
            .foregroundStyle(LiveDesign.text.opacity(0.9))
            .frame(width: 132)
            .padding(.vertical, 8)
            .background(RoundedRectangle(cornerRadius: 10).fill(LiveDesign.text.opacity(0.12)))
            .focused($focused)
            .onAppear { focused = true }
            .onChange(of: draft) { _, next in
                let digits = String(next.filter(\.isNumber).prefix(4))
                if digits != next { draft = digits }
                if digits.count == 4 {
                    model.submitRelayPasscode(digits)
                    draft = ""
                }
            }
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

/// One AF / subject box mapped from the live-view header's coordinate space onto the PRESENTED
/// picture inside `size`.
///
/// Presented, not the whole frame: the raster carries the de-squeeze as a centred `scaleEffect`
/// (`LiveFrameRaster.feedScale`), so an anamorphic setup paints the image into a narrower — or
/// shorter — sub-rect of the same frame. Mapping into the frame left the box drifting sideways off
/// the subject it is tracking, while the framing aids, which already map through `desqueezedRect`,
/// stayed put. Android applies its presentation scales before the identical mapping
/// (`liveOverlayFeedRect`).
///
/// Mirroring flips about the presented rect rather than the frame, so a mirrored AND de-squeezed
/// picture still lands the box on its face.
func liveFocusBoxRect(
    _ box: PTPLiveViewAFBox,
    focus: PTPLiveViewFocusInfo,
    in size: CGSize,
    desqueeze: NikonDesqueeze,
    mirrored: Bool,
    mirroredVertically: Bool = false
) -> CGRect? {
    guard focus.coordinateWidth > 0, focus.coordinateHeight > 0 else { return nil }
    let feed = desqueezedRect(CGRect(origin: .zero, size: size), desqueeze)
    let scaleX = feed.width / CGFloat(focus.coordinateWidth)
    let scaleY = feed.height / CGFloat(focus.coordinateHeight)
    let width = CGFloat(box.width) * scaleX
    let height = CGFloat(box.height) * scaleY
    let inset = CGFloat(box.centerX) * scaleX
    let centerX = mirrored ? feed.maxX - inset : feed.minX + inset
    let insetY = CGFloat(box.centerY) * scaleY
    let centerY = mirroredVertically ? feed.maxY - insetY : feed.minY + insetY
    return CGRect(
        x: centerX - width / 2,
        y: centerY - height / 2,
        width: width,
        height: height
    )
}

/// Draws the camera's AF / subject-detection boxes (from the live-view header) over the feed:
/// rounded rectangles with a uniform stroke — the AF / focus box (box 0) styled by AF state
/// (see `primaryBoxColor`), detected face/eye boxes (box 1+) in green.
struct LiveFocusBoxOverlay: View, Equatable {
    let focus: PTPLiveViewFocusInfo
    /// App-only focus-point lock — tints the AF box accent and badges it with a small lock.
    var locked: Bool = false
    /// 0→1 while long-pressing the AF box to lock it: how much of box 0's outline has drawn in.
    var lockProgress: CGFloat = 0
    /// Whether the picture underneath is flipped left-to-right. The camera's box coordinates never
    /// are, so the boxes have to be flipped here to keep landing on the face they are tracking.
    var mirrored: Bool = false
    /// Top-to-bottom presentation flip; AF metadata stays in source coordinates.
    var mirroredVertically: Bool = false
    /// The de-squeeze the raster below is presenting with — see ``liveFocusBoxRect``.
    var desqueeze = NikonDesqueeze.off

    nonisolated static func == (lhs: LiveFocusBoxOverlay, rhs: LiveFocusBoxOverlay) -> Bool {
        // `focusResult` / `trackingAFActive` (drawing state via `primaryBoxColor`) are stored
        // properties of `focus`, so its memberwise == already covers them.
        lhs.focus == rhs.focus && lhs.locked == rhs.locked
            && lhs.lockProgress == rhs.lockProgress && lhs.mirrored == rhs.mirrored
            && lhs.mirroredVertically == rhs.mirroredVertically
            && lhs.desqueeze == rhs.desqueeze
    }

    /// Idle AF-box white opacity — slightly transparent so acquired/tracking green reads as a
    /// state change. Value is tuned in the central visual pass.
    private static let idleWhiteOpacity = 0.72

    /// Box 0 (AF area) state → style, Nikon-body-like, in precedence order:
    /// 1. `locked` (app-side focus-point lock) — accent at full opacity, plus the lock badge.
    /// 2. AF acquired (`focusResult == .focused`) or subject tracking engaged
    ///    (`trackingAFActive`, the header's tracking-AF status byte) — green at full opacity.
    /// 3. Idle / hunting (`.unknown` / `.notFocused`) — dim white; no distinct red state.
    /// Face/eye boxes (index > 0) are always green.
    private var primaryBoxColor: Color {
        if locked { return LiveDesign.accent }
        if focus.focusResult == .focused || focus.trackingAFActive { return .green }
        return .white.opacity(Self.idleWhiteOpacity)
    }

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                Canvas { context, size in
                    for (index, box) in focus.boxes.enumerated() {
                        guard
                            let rect = liveFocusBoxRect(
                                box, focus: focus, in: size, desqueeze: desqueeze,
                                mirrored: mirrored, mirroredVertically: mirroredVertically)
                        else { continue }
                        let color: Color = index == 0 ? primaryBoxColor : .green
                        let radius = min(min(rect.width, rect.height) * 0.12, 7)
                        context.stroke(
                            Path(roundedRect: rect, cornerRadius: radius),
                            with: .color(color),
                            lineWidth: 1.5
                        )
                        if locked, index == 0, let lock = context.resolveSymbol(id: "lock") {
                            context.draw(
                                lock, at: CGPoint(x: rect.midX, y: rect.minY - 9), anchor: .center)
                        }
                    }
                } symbols: {
                    Image(systemName: "lock.fill")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(LiveDesign.accent)
                        .tag("lock")
                }

                // The lock draw-in: box 0's outline traced in accent as you hold to lock it,
                // completing as the lock engages — then it gives way to the solid accent box above.
                if lockProgress > 0.001, !locked, let rect = primaryBoxRect(in: proxy.size) {
                    let radius = min(min(rect.width, rect.height) * 0.12, 7)
                    RoundedRectangle(cornerRadius: radius)
                        .trim(from: 0, to: lockProgress)
                        .stroke(
                            LiveDesign.accent,
                            style: StrokeStyle(lineWidth: 2.5, lineCap: .round, lineJoin: .round)
                        )
                        .frame(width: rect.width, height: rect.height)
                        .position(x: rect.midX, y: rect.midY)
                        .shadow(color: LiveDesign.accent.opacity(0.55), radius: 3)
                }
            }
        }
        .allowsHitTesting(false)
    }

    /// Box 0 (the AF / focus area), through the same mapping the Canvas uses so the lock draw-in
    /// registers exactly over its white outline.
    private func primaryBoxRect(in size: CGSize) -> CGRect? {
        guard let box = focus.boxes.first else { return nil }
        return liveFocusBoxRect(
            box, focus: focus, in: size, desqueeze: desqueeze, mirrored: mirrored,
            mirroredVertically: mirroredVertically)
    }
}

struct FeedVignette: View {
    var body: some View {
        RadialGradient(
            colors: [.clear, .black.opacity(0.46)],
            center: .center,
            startRadius: 70,
            endRadius: 620
        )
        .blendMode(.multiply)
        .allowsHitTesting(false)
    }
}

struct FeedGrain: View {
    var body: some View {
        Canvas { context, size in
            // Deterministic pseudo-random speckle positions relative to the canvas size.
            for index in 0..<180 {
                let x = CGFloat((index * 73) % 791) / 791 * size.width
                let y = CGFloat((index * 47) % 367) / 367 * size.height
                let opacity = 0.016 + Double(index % 5) * 0.004
                context.fill(
                    Path(ellipseIn: CGRect(x: x, y: y, width: 1, height: 1)),
                    with: .color(.white.opacity(opacity))
                )
            }
        }
        // Rasterize once per layout pass — the grain is static relative to the feed rect.
        .drawingGroup()
        .allowsHitTesting(false)
    }
}
