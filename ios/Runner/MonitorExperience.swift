import CoreImage
import SwiftUI
import UIKit

enum LiveDesign {
    static let background = Color(red: 0.072, green: 0.064, blue: 0.053)
    static let surface = Color(red: 0.145, green: 0.128, blue: 0.102)
    static let glass = Color(red: 0.105, green: 0.092, blue: 0.073).opacity(0.64)
    /// Pre–Liquid Glass fallback: solid-looking chrome fill (no fake frost/blur).
    static let glassOpaque = Color(red: 0.105, green: 0.092, blue: 0.073).opacity(0.90)
    static let glassBright = Color(red: 0.178, green: 0.155, blue: 0.122).opacity(0.68)
    static let hairline = Color(red: 0.968, green: 0.937, blue: 0.882).opacity(0.14)
    static let hairlineStrong = Color(red: 0.968, green: 0.937, blue: 0.882).opacity(0.22)
    static let text = Color(red: 0.958, green: 0.935, blue: 0.885)
    static let muted = Color(red: 0.642, green: 0.600, blue: 0.535)
    static let faint = Color(red: 0.455, green: 0.420, blue: 0.365)
    static let accent = Color(red: 0.914, green: 0.674, blue: 0.208)
    static let accentDim = Color(red: 0.914, green: 0.674, blue: 0.208).opacity(0.16)
    static let good = Color(red: 0.18, green: 0.78, blue: 0.42)
    static let rec = Color(red: 0.82, green: 0.20, blue: 0.23)
    static let info = Color(red: 0.10, green: 0.58, blue: 0.98)

    /// Standard height for the bottom control bars (assist toolbar + value strip).
    static let controlHeight: CGFloat = 58

    /// See `DesignTokens.cornerRadius` — single source of truth for rounded chrome surfaces.
    static let cornerRadius = DesignTokens.cornerRadius

}

struct MonitorExperience: View {
    @Environment(NativeAppModel.self) private var model

    var body: some View {
        LiveViewShell()
            // Haptics: tap on panel open/close, tick on DISP cycle / assist toggle, firm thump on
            // record start/stop. (Value wheels add their own per-detent feedback.)
            .sensoryFeedback(.selection, trigger: model.activePanel)
            .sensoryFeedback(.selection, trigger: model.displayMode)
            .sensoryFeedback(.selection, trigger: model.preferences.liveViewVisibleAssistTools)
            .sensoryFeedback(.impact(weight: .heavy), trigger: model.isRecording)
            // Confirm the focus-point app-lock on release — a firm thump locking, a light tap freeing.
            .sensoryFeedback(trigger: model.focusPointLocked) { _, locked in
                locked ? .impact(weight: .heavy) : .impact(weight: .light)
            }
    }
}

private struct LiveViewShell: View {
    @Environment(NativeAppModel.self) private var model

    var body: some View {
        GeometryReader { proxy in
            let deviceOrientation = MonitorDeviceOrientationReader.current()
            let screenWidth = MonitorDeviceOrientationReader.currentViewportWidth()
            let context = LiveViewLayoutContext(
                proxy: proxy,
                deviceOrientation: deviceOrientation,
                screenWidth: screenWidth
            )

            // One view tree for both orientations, driven by the zone map: rotation is a geometry
            // change under stable view identity — the `.easeInOut(value: isPortrait)` glides every
            // module to its new frame. `MonitorFullScreenPanelOverlay` is logically part of the
            // shell but must mount here, past `.ignoresSafeArea` (see below).
            MonitorShell(context: context)
                .environment(model)
                .animation(.easeInOut(duration: 0.3), value: context.isPortrait)
                .frame(width: proxy.size.width, height: proxy.size.height)
                .ignoresSafeArea(.container, edges: .all)
                // Tally + full-screen panel overlay the already-extended (physical-screen) layer
                // so both reach the bezel on every edge — mounted inside `MonitorShell` they pin
                // to the safe-area frame (its `GeometryReader` reports its size before this
                // `.ignoresSafeArea` runs). Constructed directly as its own `View` (never read as
                // a property off a sibling `MonitorShell` instance) so `.environment` installs on
                // ITS tree position before `@Environment` resolves — the sibling-property form
                // crashed on `model` resolving to the missing default.
                .overlay(alignment: .topLeading) {
                    MonitorFullScreenPanelOverlay(context: context)
                        .environment(model)
                }
                .overlay {
                    if model.cameraState.recordState == .recording {
                        RecordingBorderModule()
                    }
                }
                .overlayPreferenceValue(LiveViewGuideAnchorKey.self) { anchors in
                    if let step = model.liveViewGuideStep,
                        model.activePanel == nil,
                        model.displayMode == .live,
                        !model.isRecording
                    {
                        LiveViewGuideOverlay(
                            step: step,
                            anchors: anchors,
                            isPortrait: context.isPortrait
                        )
                        .environment(model)
                    }
                }
        }
        // Snappy panel insert/remove so dismissing a popup feels near-instant.
        .animation(.easeOut(duration: 0.10), value: model.activePanel)
        .animation(.easeInOut(duration: 0.18), value: model.displayMode)
    }
}

struct LiveViewLayoutContext {
    let feedSafeArea: MonitorEdgeInsets
    let chromeInsets: MonitorEdgeInsets
    let horizontalDirection: MonitorHorizontalLayoutDirection
    let viewportWidth: Double
    let canvasOffsetX: Double
    /// True when the viewport is taller than it is wide — drives the portrait monitor shell.
    let isPortrait: Bool
    /// Full PHYSICAL viewport height for the portrait zone layout. The GeometryReader reports the
    /// safe-area frame, but the shell renders edge-to-edge and `MonitorPortraitLayout.zones`
    /// subtracts the insets itself — restore them here (as `MonitorLiveViewViewport.fullWidth` does
    /// horizontally). Passing the safe-area height double-counts the insets: ~96pt dead band.
    let viewportHeight: Double

    @MainActor
    init(proxy: GeometryProxy, deviceOrientation: MonitorDeviceOrientation, screenWidth: Double?) {
        feedSafeArea = proxy.monitorEdgeInsets
        isPortrait = proxy.size.height > proxy.size.width
        viewportHeight =
            Double(proxy.size.height) + max(0, feedSafeArea.top) + max(0, feedSafeArea.bottom)
        chromeInsets =
            MonitorChromeLayout.insets(feedSafeArea: feedSafeArea)
            .clearingWindowControls
        horizontalDirection = MonitorHorizontalLayoutDirection.resolve(
            deviceOrientation: deviceOrientation,
            safeArea: feedSafeArea
        )
        viewportWidth = MonitorLiveViewViewport.fullWidth(
            layoutWidth: Double(proxy.size.width),
            safeArea: feedSafeArea,
            screenWidth: screenWidth,
            geometrySpace: .safeArea
        )
        canvasOffsetX = MonitorLiveViewViewport.canvasOffsetX(
            layoutWidth: Double(proxy.size.width),
            safeArea: feedSafeArea,
            screenWidth: screenWidth
        )
    }
}

@MainActor
private enum MonitorDeviceOrientationReader {
    static func current() -> MonitorDeviceOrientation {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let scene =
            scenes.first { $0.activationState == .foregroundActive }
            ?? scenes.first { $0.activationState == .foregroundInactive }
            ?? scenes.first

        return scene?.interfaceOrientation.monitorDeviceOrientation ?? .unknown
    }

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

extension UIInterfaceOrientation {
    fileprivate var monitorDeviceOrientation: MonitorDeviceOrientation {
        switch self {
        case .portrait:
            .portrait
        case .portraitUpsideDown:
            .portraitUpsideDown
        case .landscapeLeft:
            // UIKit interface landscape values are opposite the physical device orientation.
            .landscapeRight
        case .landscapeRight:
            // UIKit interface landscape values are opposite the physical device orientation.
            .landscapeLeft
        case .unknown:
            .unknown
        @unknown default:
            .unknown
        }
    }
}

struct RecordingBorderModule: View {
    var body: some View {
        // Fills the physical screen (it overlays the extended layer); `strokeBorder` keeps the whole
        // line inside the bezel, and the device's own corner radius makes it track the rounded edge.
        RoundedRectangle(cornerRadius: Self.displayCornerRadius, style: .continuous)
            .strokeBorder(LiveDesign.rec, lineWidth: 4)
            .shadow(color: LiveDesign.rec.opacity(0.55), radius: 14)
            .ignoresSafeArea()
            .allowsHitTesting(false)
    }

    /// Approximate display corner radius. No public API exists, and the private
    /// `_displayCornerRadius` KVC key risks App Store rejection — the corner is decorative, so a
    /// fixed value tuned to modern iPhones is a few points off at most.
    @MainActor static var displayCornerRadius: CGFloat { 52 }
}

struct LiveFeedModule: View {
    @Environment(NativeAppModel.self) private var model
    let safeArea: MonitorEdgeInsets
    let viewportWidth: Double
    let canvasOffsetX: Double
    var horizontalDirection: MonitorHorizontalLayoutDirection = .standard
    /// Portrait mounts hand the module an exact zone-frame height. The measured height is only
    /// trustworthy in the landscape full-bleed canvas: inside a safe-area-inset context the
    /// module's own `.ignoresSafeArea()` re-expands the proposal, the reader reports the grown
    /// height, and the derived 16:9 box renders oversized and shifted up — the fill-mode "cropped
    /// on top and right" bug. Nil (landscape) keeps the measured path unchanged.
    var fixedContentHeight: Double? = nil

    /// True while a finger is held (roughly still) on the feed — drives the AF-box lock "draw-in".
    @GestureState private var feedHold = false
    /// 0→1: how much of the AF box outline has traced in during a lock long-press.
    @State private var lockProgress: CGFloat = 0

    var body: some View {
        ZStack(alignment: .leading) {
            LiveDesign.background

            GeometryReader { proxy in
                // Photography frames the feed at the still image area's shape (FX/DX 3:2,
                // 1:1, 16:9) so the whole photo frame shows; cinema keeps the native 16:9.
                let isPhotography = StillCapturePolicy.prefersPhotographyChrome(
                    selector: model.cameraPropertySnapshot.captureSelector)
                let feedFrame = MonitorFeedLayout.fullBleedFrame(
                    viewportWidth: viewportWidth,
                    viewportHeight: fixedContentHeight ?? Double(proxy.size.height),
                    safeArea: safeArea,
                    horizontalDirection: horizontalDirection,
                    aspect: isPhotography
                        ? model.cameraPropertySnapshot.photographyFeedAspect
                        : MonitorFeedLayout.aspectRatio,
                    anchorToRailSide: isPhotography
                )
                let imageWidth = CGFloat(feedFrame.width)
                let imageHeight = CGFloat(feedFrame.height)
                ZStack(alignment: .leading) {
                    Color.black
                    feedImage(width: imageWidth, height: imageHeight)
                    FeedVignette()
                    FeedGrain()
                }
                .frame(width: imageWidth, height: imageHeight, alignment: .leading)
                .position(
                    x: CGFloat(feedFrame.x + feedFrame.width / 2),
                    y: CGFloat(feedFrame.y + feedFrame.height / 2)
                )
                .frame(
                    width: CGFloat(viewportWidth),
                    height: CGFloat(fixedContentHeight ?? Double(proxy.size.height)),
                    alignment: .topLeading
                )
                .offset(x: CGFloat(canvasOffsetX))
            }
        }
        // The safe-area escape belongs to the landscape full-bleed mount only; with a fixed
        // content height (portrait), it would re-expand the proposal and shift the box up.
        .modifier(FullBleedWhenMeasured(active: fixedContentHeight == nil))
    }

    @ViewBuilder private func feedImage(width: CGFloat, height: CGFloat) -> some View {
        ZStack {
            LiveFrameRaster(width: width, height: height)
            LiveFeedFocusOverlay(lockProgress: lockProgress)
            LiveFeedWaitingOverlay()
            if model.demoUIMode {
                // Demo UI mode (⌘D) owns the pointer: this stage sits over the feed and absorbs
                // input, so the normal tap-to-focus / swipe gestures below are intentionally
                // inert until the mode is toggled off.
                DemoFocusPointerSurface(model: model, size: CGSize(width: width, height: height))
            }
        }
        .frame(width: width, height: height)
        .clipped()
        .contentShape(Rectangle())
        // Vertical swipe switches output mode (down → clean, up → live); long-press app-locks the
        // focus point; a tap moves it. Disambiguated by motion/hold/count, in that priority.
        .gesture(feedGesture(width: width, height: height))
        // A near-infinite long-press runs purely as a "finger held on the feed" probe (GestureState:
        // true on press, false on release / a >10pt move / interruption). It takes no action and never
        // completes, so it composes alongside feedGesture without disturbing the swipe/tap/lock — it
        // only drives the lock draw-in below.
        .simultaneousGesture(
            LongPressGesture(minimumDuration: 10)
                .updating($feedHold) { pressing, state, _ in state = pressing }
        )
        // The lock itself: a bare *simultaneous* long-press so it fires the instant the 0.3s hold
        // is met — independent of the swipe's `.exclusively`, which would hold it back until the
        // swipe fails on release (the "hold forever, nothing until I lift" bug). Motion cancels it
        // (a swipe never locks) and taps are too brief. Locks the current AF point; haptic + box
        // visuals react to model.focusPointLocked.
        .simultaneousGesture(
            LongPressGesture(minimumDuration: 0.3)
                .onEnded { _ in model.toggleFocusPointLock() }
        )
        .onChange(of: feedHold) { _, holding in
            if holding {
                // Trace the AF box outline in over the 0.3s hold; the 0.1s lead-in keeps a quick tap
                // from flashing a partial ring, and 0.1 + 0.2 lands the full outline as the lock fires.
                withAnimation(.linear(duration: 0.2).delay(0.1)) { lockProgress = 1 }
            } else {
                withAnimation(.easeOut(duration: 0.16)) { lockProgress = 0 }
            }
        }
        .onChange(of: model.focusPointLocked) { _, _ in
            // The lock just toggled — clear the draw-in so it neither lingers nor flashes on unlock.
            lockProgress = 0
        }
        // Framing aids (guides, grid, crosshair, level) overlaid directly on the feed image so they
        // register pixel-exact with it — the same rect the AF boxes use — instead of a separately
        // computed frame. Clean mode keeps the framing guides (and the de-squeeze they bound) but
        // drops the busier grid / crosshair / level.
        .overlay {
            FeedAlignedAssists(clean: model.displayMode == .clean)
        }
    }

    /// Composed feed gesture: a vertical swipe switches output mode, else a tap moves the focus
    /// point; `exclusively` keeps one alive per touch. (The app-lock long-press is a *separate*
    /// simultaneous gesture — see the feed-image modifiers — so it fires mid-hold instead of being
    /// held back behind this swipe's exclusivity.)
    private func feedGesture(width: CGFloat, height: CGFloat) -> some Gesture {
        let size = CGSize(width: width, height: height)
        return
            DragGesture(minimumDistance: 28)
            .onEnded { value in
                let dy = value.translation.height
                guard abs(dy) > abs(value.translation.width) + 8, abs(dy) > 44 else { return }
                // Down → clean (DISP 2); up → live (DISP 1).
                model.setDisplayMode(dy > 0 ? .clean : .live)
            }
            .exclusively(before: focusTapGestures(size: size))
    }

    private func focusTapGestures(size: CGSize) -> some Gesture {
        // A single tap moves the focus point and must fire immediately. A same-target double-tap
        // in front via `.exclusively` forces SwiftUI to wait the ~300ms double-tap window before
        // EVERY single tap — so tap-to-move (the frequent action) wins and reset-to-centre stays
        // out of the feed gesture.
        SpatialTapGesture()
            .onEnded { value in
                model.setFocusPoint(at: value.location, feedSize: size)
            }
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
            isDemoSession: model.isDemoSession,
            fileStore: model.lutFileStore,
            width: width,
            height: height
        )
        .scaleEffect(
            desqueezeScale(model.assistConfiguration.desqueeze), anchor: .center)
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
    let isDemoSession: Bool
    let fileStore: LUTFileStore
    let width: CGFloat
    let height: CGFloat
    @State private var metalFeedEnabled = FeedRenderMode.metalFeedEnabled

    var body: some View {
        Group {
            if let image {
                if metalFeedEnabled {
                    MetalLiveView(
                        image: image, effects: effects, fileStore: fileStore
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
        view.contentMode = .scaleAspectFill
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
        // The AF box shows in live AND clean (DISP 1 & 2) — focus feedback the operator relies on
        // even in the stripped-back view. (Command never mounts the feed, so no guard needed.)
        if let focus = model.liveViewFocus, !focus.boxes.isEmpty {
            // Focus metadata repeats identically on most frames — the Equatable guard skips the
            // Canvas redraw unless a box, lock, or progress changed.
            LiveFocusBoxOverlay(
                focus: focus, locked: model.focusPointLocked, lockProgress: lockProgress
            )
            .equatable()
        }
    }
}

/// Shown until the first decoded frame arrives.
private struct LiveFeedWaitingOverlay: View {
    @Environment(NativeAppModel.self) private var model

    var body: some View {
        if model.liveFrameImage == nil && !model.isDemoSession {
            VStack(spacing: 10) {
                Image(systemName: "viewfinder")
                    .font(.system(size: 28, weight: .light))
                Text("WAITING FOR LIVE VIEW")
                    .font(.system(size: 17, weight: .semibold, design: .monospaced))
            }
            .foregroundStyle(LiveDesign.text.opacity(0.28))
        }
    }
}

/// Renders the live-view feed through a single long-lived `UIImageView`: the streaming loop swaps
/// `model.liveFrameImage` ~30×/sec with a display-ready bitmap, and reusing one view keeps
/// live-view memory flat over long sessions. `.scaleAspectFill` + clipping mirrors `.scaledToFill()`.
private struct LiveFrameView: UIViewRepresentable {
    let image: UIImage

    func makeUIView(context: Context) -> UIImageView {
        let view = UIImageView()
        view.contentMode = .scaleAspectFill
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

/// Draws the camera's AF / subject-detection boxes (from the live-view header) over the feed:
/// rounded rectangles with a uniform stroke — the AF / focus box (box 0) styled by AF state
/// (see `primaryBoxColor`), detected face/eye boxes (box 1+) in green.
struct LiveFocusBoxOverlay: View, Equatable {
    let focus: PTPLiveViewFocusInfo
    /// App-only focus-point lock — tints the AF box accent and badges it with a small lock.
    var locked: Bool = false
    /// 0→1 while long-pressing the AF box to lock it: how much of box 0's outline has drawn in.
    var lockProgress: CGFloat = 0

    nonisolated static func == (lhs: LiveFocusBoxOverlay, rhs: LiveFocusBoxOverlay) -> Bool {
        // `focusResult` / `trackingAFActive` (drawing state via `primaryBoxColor`) are stored
        // properties of `focus`, so its memberwise == already covers them.
        lhs.focus == rhs.focus && lhs.locked == rhs.locked
            && lhs.lockProgress == rhs.lockProgress
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
                    guard focus.coordinateWidth > 0, focus.coordinateHeight > 0 else { return }
                    let scaleX = size.width / CGFloat(focus.coordinateWidth)
                    let scaleY = size.height / CGFloat(focus.coordinateHeight)
                    for (index, box) in focus.boxes.enumerated() {
                        let boxWidth = CGFloat(box.width) * scaleX
                        let boxHeight = CGFloat(box.height) * scaleY
                        let rect = CGRect(
                            x: CGFloat(box.centerX) * scaleX - boxWidth / 2,
                            y: CGFloat(box.centerY) * scaleY - boxHeight / 2,
                            width: boxWidth,
                            height: boxHeight
                        )
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

    /// Box 0 (the AF / focus area) mapped from the live-view header coordinate space into the feed
    /// rect — the same math the Canvas uses, so the draw-in registers exactly over its white outline.
    private func primaryBoxRect(in size: CGSize) -> CGRect? {
        guard focus.coordinateWidth > 0, focus.coordinateHeight > 0, let box = focus.boxes.first
        else { return nil }
        let scaleX = size.width / CGFloat(focus.coordinateWidth)
        let scaleY = size.height / CGFloat(focus.coordinateHeight)
        let width = CGFloat(box.width) * scaleX
        let height = CGFloat(box.height) * scaleY
        return CGRect(
            x: CGFloat(box.centerX) * scaleX - width / 2,
            y: CGFloat(box.centerY) * scaleY - height / 2,
            width: width,
            height: height
        )
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

extension View {
    /// Positions a view at an absolute `MonitorModuleFrame` (viewport coordinates). Internal:
    /// `MonitorSystemCluster` / `MonitorShell` (MonitorUnified.swift) place rail slots with it.
    func monitorModuleFrame(_ frame: MonitorModuleFrame, alignment: Alignment = .center)
        -> some View
    {
        self
            .frame(width: CGFloat(frame.width), height: CGFloat(frame.height), alignment: alignment)
            .position(x: CGFloat(frame.midX), y: CGFloat(frame.midY))
    }
}

struct BatteryRailModule: View {
    @Environment(NativeAppModel.self) private var model
    let safeArea: MonitorEdgeInsets
    let phoneTopClearance: Double

    var body: some View {
        GeometryReader { proxy in
            let layout = MonitorBatteryRailLayout.fit(
                railHeight: Double(proxy.size.height),
                safeArea: safeArea,
                phoneTopClearance: phoneTopClearance
            )

            ZStack {
                phoneBatteryIndicator(compact: layout.phoneIndicatorHeight < 40)
                    .position(x: CGFloat(layout.phoneCenterX), y: CGFloat(layout.phoneCenterY))
                cameraBatteryIndicator
                    .position(x: CGFloat(layout.cameraCenterX), y: CGFloat(layout.cameraCenterY))
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
        }
    }

    private func phoneBatteryIndicator(compact: Bool) -> some View {
        BatteryIndicator(
            percent: model.cameraState.phoneBatteryPercent,
            deviceSystemName: "iphone",
            isCamera: false,
            isCharging: model.phoneBatteryCharging,
            layout: compact ? .compactRail : .rail
        )
    }

    private var cameraBatteryIndicator: some View {
        BatteryIndicator(
            percent: model.cameraState.cameraBatteryPercent,
            deviceSystemName: "camera",
            isCamera: true,
            isCharging: model.cameraBatteryCharging
        )
    }
}

/// Inline phone + camera battery row for width-constrained (4:3-ish iPad) landscape layouts,
/// mounted beside the lock button at the zone map's `.batteryInline` cluster frame. Reuses the
/// portrait top bar's single-row `BatteryIndicator` presentation.
struct BatteryInlineCluster: View {
    @Environment(NativeAppModel.self) private var model

    var body: some View {
        HStack(spacing: 14) {
            BatteryIndicator(
                percent: model.cameraState.phoneBatteryPercent,
                deviceSystemName: "iphone",
                isCamera: false,
                isCharging: model.phoneBatteryCharging,
                layout: .inline
            )
            BatteryIndicator(
                percent: model.cameraState.cameraBatteryPercent,
                deviceSystemName: "camera",
                isCamera: true,
                isCharging: model.cameraBatteryCharging,
                layout: .inline
            )
        }
    }
}

/// A single tappable exposure readout (label + value) that opens its picker above the capture bar.
/// While that picker is open it lights up gold so the operator can see which setting is being edited.
struct CaptureSettingButton: View {
    @Environment(NativeAppModel.self) private var model
    let value: CameraValue
    /// Uniform readout scale (R9): portrait-fill passes 0.8 so all 5 settings fit the strip
    /// width with no horizontal scroll. Landscape's default of 1 is unaffected.
    var scale: CGFloat = 1
    /// Replaces the `CameraPicker` tap routing — the photography strip reuses this tile with
    /// its own (stub) control handlers until stills pickers exist.
    var overrideAction: (() -> Void)? = nil

    /// True while this setting's picker is the active panel.
    private var isActive: Bool {
        guard case .picker(let picker)? = model.activePanel else { return false }
        return picker.valueLabel == value.label
    }

    /// The widest value this setting can show, used to fix the readout width so the bar stays put.
    private var widestValue: String {
        switch value.label {
        case "ISO": "25600"  // XXXXX
        case "SHUTTER": "1/16000"  // X/XXXXX
        case "IRIS": "f/2.8"  // f/X.X
        case "FOCUS": "Wide-L"
        case "WB": "5560K"  // Kelvin dial step; presets render as icons (narrower)
        // Photography strip pins, so the bar doesn't shift as stills values change.
        case "MODE": "Auto"
        case "DRIVE": "Single"
        case "FLASH": "Red+S"
        case "METER": "Matrix"
        default: value.value
        }
    }

    /// The value as shown in the bar — abbreviated where the full form (kept in the drum) is too
    /// long for the readout.
    private var displayValue: String {
        switch value.value {
        case "Auto Subject": "Auto-S"
        default: value.value
        }
    }

    /// SF Symbol for a WB preset shown in the bar (nil for Kelvin readouts, which stay numeric).
    private var valueIcon: String? {
        guard value.label == "WB" else { return nil }
        switch value.value {
        case "Auto": return "a.circle.fill"
        case "Natural auto": return "sun.haze.fill"
        case "Sunny": return "sun.max.fill"
        case "Cloudy": return "cloud.fill"
        case "Shade": return "cloud.sun.fill"
        case "Incandescent": return "lightbulb.fill"
        case "Fluorescent": return "light.panel.fill"
        case "Flash": return "bolt.fill"
        case "Preset": return "p.circle.fill"
        default: return nil
        }
    }

    /// Whether the camera's Control lock is holding this setting (it rejected a write to it).
    private var isControlLocked: Bool {
        guard let picker = CameraPicker.forValueLabel(value.label)
        else { return false }
        return model.lockedControls.contains(picker)
    }

    /// Shutter readout locked via `MovieTVLockSetting` or a rejected shutter write.
    private var isShutterLocked: Bool {
        value.label == "SHUTTER" && model.lockedControls.contains(.shutter)
    }

    /// ISO readout locked while recording in R3D NE.
    private var isISORecordingLocked: Bool {
        value.label == "ISO" && model.isISORecordingLocked
    }

    private func openPicker() {
        guard let picker = CameraPicker.forValueLabel(value.label)
        else { return }
        if model.activePanel == nil {
            model.showPicker(picker)
        } else if model.activePanel == .picker(picker) {
            model.dismissActivePanel()
        } else {
            model.switchPicker(to: picker)
        }
    }

    @ViewBuilder
    private var readoutLabel: some View {
        VStack(spacing: 3) {
            HStack(spacing: 3) {
                Text(value.label)
                    .font(.system(size: 9 * scale, weight: .semibold, design: .default))
                    .foregroundStyle(
                        isActive ? LiveDesign.accent.opacity(0.85) : LiveDesign.faint)
                if isControlLocked {
                    Image(systemName: "lock.fill")
                        .font(.system(size: 7.5, weight: .semibold))
                        .foregroundStyle(LiveDesign.accent.opacity(0.9))
                }
            }
            Text(widestValue)
                .font(.system(size: 19 * scale, weight: .medium, design: .monospaced))
                .hidden()
                .overlay {
                    if let icon = valueIcon {
                        Image(systemName: icon)
                            .font(.system(size: 20 * scale, weight: .regular))
                            .foregroundStyle(isActive ? LiveDesign.accent : LiveDesign.text)
                    } else {
                        Text(displayValue)
                            .font(.system(size: 19 * scale, weight: .medium, design: .monospaced))
                            .foregroundStyle(isActive ? LiveDesign.accent : LiveDesign.text)
                            .lineLimit(1)
                            .minimumScaleFactor(0.6)
                    }
                }
        }
        .padding(.vertical, 5 * scale)
        .padding(.horizontal, 8 * scale)
        .background {
            RoundedRectangle(cornerRadius: LiveDesign.cornerRadius, style: .continuous)
                .fill(isActive ? LiveDesign.accentDim : Color.clear)
        }
        .overlay {
            RoundedRectangle(cornerRadius: LiveDesign.cornerRadius, style: .continuous)
                .strokeBorder(isActive ? LiveDesign.accentDim : Color.clear, lineWidth: 1)
        }
    }

    var body: some View {
        Group {
            if let overrideAction {
                Button(action: overrideAction) {
                    readoutLabel
                }
                .buttonStyle(.zcTapTarget)
            } else if value.label == "SHUTTER" {
                readoutLabel
                    .opacity(isShutterLocked ? 0.55 : 1.0)
                    .minTapTarget()
                    .onTapGesture { openPicker() }
                    .onLongPressGesture(minimumDuration: 0.45) {
                        if model.preferences.hapticsEnabled {
                            if isShutterLocked {
                                OperatorSettingsHaptics.unlockConfirm()
                            } else {
                                OperatorSettingsHaptics.lockConfirm()
                            }
                        }
                        if isShutterLocked {
                            model.unlockShutterControlOnCamera()
                        } else {
                            model.lockShutterControlOnCamera()
                        }
                    } onPressingChanged: { pressing in
                        guard pressing else { return }
                        model.connectionMessage =
                            isShutterLocked
                            ? "Hold to unlock shutter control on camera"
                            : "Hold to lock shutter control on camera"
                    }
            } else {
                Button(action: openPicker) {
                    readoutLabel
                        .opacity(isISORecordingLocked ? 0.55 : 1.0)
                }
                .buttonStyle(.zcTapTarget)
            }
        }
        // Publish this readout's global frame so a tap on it (through the picker backdrop) can
        // blend an open picker straight to this setting.
        .background(
            GeometryReader { proxy in
                Color.clear
                    .onAppear { model.captureSettingFrames[value.label] = proxy.frame(in: .global) }
                    .onChange(of: proxy.frame(in: .global)) { _, frame in
                        model.captureSettingFrames[value.label] = frame
                    }
                    // Same landscape-unmount staleness as captureBarFrame/assistToolbarFrame above:
                    // drop this entry so handleBackdropTap can't hit-test a stale landscape frame
                    // after rotating to portrait.
                    .onDisappear { model.captureSettingFrames[value.label] = nil }
            }
        )
    }
}

/// An assist-bar tool: a single tap toggles it, a long-press opens its options. The press builds
/// escalating haptics so the operator feels the action arming, then a firm tap when it fires. Each
/// button keeps its own press state, so it lives in its own view.
struct AssistToolButtonRow: View {
    @Environment(NativeAppModel.self) private var model
    let tool: MonitorAssistTool
    var context: ViewAssistContext = .liveView
    var compact = false
    /// When set, long-press routes here instead of the live-monitor assist popup (e.g. media playback).
    var onConfigure: ((MonitorAssistTool) -> Void)? = nil
    @State private var buildup: Task<Void, Never>?

    var body: some View {
        AssistToolButton(
            tool: tool,
            isOn: model.preferences.visibleAssistTools(for: context).contains(tool),
            compact: compact
        )
        // Fit-mode scope cap (R7): a scope that can't activate renders grayed but stays tappable —
        // the tap routes to `toggleAssist`, which refuses and fires the toast. Inert in landscape
        // (`monitorIsPortrait == false` ⇒ never blocked) and for non-scope tools.
        .opacity(context == .liveView && model.isScopeCapBlocked(tool) ? 0.35 : 1)
        .animation(.easeInOut(duration: 0.18), value: model.isScopeCapBlocked(tool))
        .minTapTarget()
        .onTapGesture { model.toggleAssist(tool, context: context) }
        .onLongPressGesture(minimumDuration: 0.25) {
            cancelBuildup()
            guard tool.hasConfiguration else { return }
            if model.preferences.hapticsEnabled {
                AssistHaptics.confirm()
            }
            if let onConfigure {
                onConfigure(tool)
            } else {
                model.presentAssistOptions(tool)
            }
        } onPressingChanged: { pressing in
            guard tool.hasConfiguration, model.preferences.hapticsEnabled else { return }
            if pressing {
                buildup = AssistHaptics.buildup()
            } else {
                cancelBuildup()
            }
        }
    }

    private func cancelBuildup() {
        buildup?.cancel()
        buildup = nil
    }
}

/// Escalating haptics that signal a long-press is building toward its action.
private enum AssistHaptics {
    /// Three soft taps of rising intensity over ~0.16s, leading into the press's completion.
    @MainActor static func buildup() -> Task<Void, Never> {
        Task { @MainActor in
            let generator = UIImpactFeedbackGenerator(style: .soft)
            for intensity in [0.4, 0.65, 0.9] as [CGFloat] {
                generator.prepare()
                generator.impactOccurred(intensity: intensity)
                try? await Task.sleep(for: .seconds(0.08))
                if Task.isCancelled { return }
            }
        }
    }

    /// A firm tap confirming the long-press has fired.
    @MainActor static func confirm() {
        let generator = UIImpactFeedbackGenerator(style: .rigid)
        generator.prepare()
        generator.impactOccurred(intensity: 1.0)
    }
}

/// Tracks which edges of the assist toolbar fade out to hint at off-screen tools.
struct ScrollEdgeFades: Equatable {
    var leading: Bool
    var trailing: Bool

    /// A horizontal mask gradient that fades only the active edges (≈6% inset each).
    var gradient: LinearGradient {
        LinearGradient(
            stops: [
                .init(color: leading ? .clear : .black, location: 0),
                .init(color: .black, location: leading ? 0.06 : 0),
                .init(color: .black, location: trailing ? 0.94 : 1),
                .init(color: trailing ? .clear : .black, location: 1),
            ],
            startPoint: .leading,
            endPoint: .trailing
        )
    }
}

struct AssistToolButton: View {
    let tool: MonitorAssistTool
    let isOn: Bool
    var compact = false

    var body: some View {
        // Mirrors the mockup's `.tool` box model; the 52pt floor keeps comfortable touch targets
        // while wide labels (PARADE) still grow.
        VStack(spacing: 3) {
            AssistToolIcon(tool: tool, size: 19)
                .frame(height: 23)
            Text(tool.rawValue)
                .font(.system(size: 9, weight: .medium, design: .monospaced))
                .tracking(0.9)
                .lineLimit(1)
        }
        .foregroundStyle(isOn ? LiveDesign.accent : LiveDesign.muted)
        .padding(.vertical, 5)
        .padding(.horizontal, compact ? 5 : 8)
        .frame(minWidth: compact ? 48 : 52)
        // `.tool.on`: a dim-accent fill and a same-tone dim border (no bright outline) —
        // only the icon and label read as full gold. No drop shadow: a glow would extend
        // past the frame and get clipped hard by the scroll container at the leading edge.
        .background {
            RoundedRectangle(cornerRadius: LiveDesign.cornerRadius, style: .continuous)
                .fill(isOn ? LiveDesign.accentDim : Color.clear)
        }
        .overlay {
            RoundedRectangle(cornerRadius: LiveDesign.cornerRadius, style: .continuous)
                .strokeBorder(isOn ? LiveDesign.accentDim : Color.clear, lineWidth: 1)
        }
    }
}

/// Three parallel diagonal stripes — the classic video "zebra" exposure mark. As a `Shape`, its
/// stroked form fills with the surrounding `foregroundStyle`, so it tints exactly like the SF
/// Symbols beside it (gold when on, muted when off).
struct ZebraStripesShape: Shape {
    var count = 3

    func path(in rect: CGRect) -> Path {
        var path = Path()
        let side = min(rect.width, rect.height)
        let originX = rect.midX
        let originY = rect.midY
        let diag = CGFloat(0.5).squareRoot()  // 1/√2 — projects each 45° stripe onto the axes
        let halfLen = side * 0.40 / 2  // half a stripe's length
        let step = side * 0.27  // perpendicular gap between stripes
        for index in 0..<count {
            let offset = CGFloat(index) - CGFloat(count - 1) / 2
            let centerX = originX + offset * step * diag
            let centerY = originY + offset * step * diag
            path.move(to: CGPoint(x: centerX - halfLen * diag, y: centerY + halfLen * diag))
            path.addLine(to: CGPoint(x: centerX + halfLen * diag, y: centerY - halfLen * diag))
        }
        return path
    }
}

/// The glyph for an assist tool. Every tool uses its SF Symbol except ZEBRA, which gets the custom
/// diagonal-stripe mark — no SF Symbol reads as exposure "zebras" (the nearest are a single
/// `line.diagonal` or a phone-shaped hatch). Sized explicitly so it matches the symbol it replaces.
struct AssistToolIcon: View {
    let tool: MonitorAssistTool
    var size: CGFloat = 19

    var body: some View {
        if tool == .zebra {
            ZebraStripesShape()
                .stroke(
                    style: StrokeStyle(
                        lineWidth: max(1.6, size * 0.13), lineCap: .round, lineJoin: .round)
                )
                .frame(width: size, height: size)
        } else {
            Image(systemName: tool.icon)
                .font(.system(size: size, weight: .regular))
        }
    }
}

struct AssetCircleButton: View {
    let assetName: String
    let systemName: String
    let size: CGFloat

    var body: some View {
        Image(assetName)
            .renderingMode(.template)
            .resizable()
            .scaledToFit()
            .frame(width: size * 0.44, height: size * 0.44)
            .foregroundStyle(LiveDesign.text.opacity(0.86))
            .frame(width: size, height: size)
            .liquidGlass(in: Circle())
    }
}

struct RecordButton: View {
    let isRecording: Bool

    // Drawn at the rail's record-button diameter; inner shapes keep their original proportions.
    private var diameter: CGFloat { CGFloat(MonitorSideRailControlLayout.recordButtonSize) }

    var body: some View {
        ZStack {
            Circle()
                .fill(
                    RadialGradient(
                        colors: [
                            Color(red: 0.88, green: 0.28, blue: 0.30),
                            LiveDesign.rec,
                        ],
                        center: .top,
                        startRadius: 4,
                        endRadius: diameter * (48.0 / 72.0)
                    )
                )
                .overlay(Circle().stroke(.white.opacity(0.17), lineWidth: 3))
                .shadow(color: .black.opacity(0.50), radius: 20, x: 0, y: 12)
                .shadow(color: isRecording ? LiveDesign.rec.opacity(0.50) : .clear, radius: 16)
            if isRecording {
                // Stop icon — rounded square, not panel chrome (see `DesignTokens` exceptions).
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(LiveDesign.rec)
                    .frame(width: diameter * (25.0 / 72.0), height: diameter * (25.0 / 72.0))
            } else {
                Circle()
                    .fill(LiveDesign.rec)
                    .frame(width: diameter * (58.0 / 72.0), height: diameter * (58.0 / 72.0))
            }
        }
        .frame(width: diameter, height: diameter)
    }
}

struct BatteryIndicator: View {
    /// `.rail`: 3-row landscape rail. `.compactRail`: battery + percentage between a classic
    /// notch and lock button. `.inline`: single-row portrait/iPad presentation.
    enum Layout {
        case rail, compactRail, inline
    }

    let percent: Int
    let deviceSystemName: String
    let isCamera: Bool
    var isCharging: Bool = false
    var layout: Layout = .rail

    /// Standard SF battery glyph whose fill reflects the charge percent. The Nikon ZR reports
    /// battery as discrete steps (1/20/40/60/80/100 %), so the camera readout naturally lands on
    /// 20/40/60/80/100 % (and 1 % when critical) rather than a misleadingly precise figure.
    private var batterySymbol: String {
        let bucket = percent
        switch bucket {
        case ..<13: return "battery.0percent"
        case ..<38: return "battery.25percent"
        case ..<63: return "battery.50percent"
        case ..<88: return "battery.75percent"
        default: return "battery.100percent"
        }
    }

    /// The readout under the glyph: charge percent for both the camera and the phone.
    private var readout: String {
        "\(percent)%"
    }

    private var isLow: Bool {
        isCamera ? percent < 10 : percent <= 15
    }

    private var batteryTint: Color {
        if isLow { return .red }
        return isCamera ? LiveDesign.accent : LiveDesign.text.opacity(0.85)
    }

    var body: some View {
        switch layout {
        case .rail: railBody
        case .compactRail: compactRailBody
        case .inline: inlineBody
        }
    }

    /// A charging bolt sits over the battery body when plugged in, legible against the fill via
    /// a dark glyph with a thin light outline. Shared by both presentations.
    private var chargingOverlay: some View {
        Group {
            if isCharging {
                Image(systemName: "bolt.fill")
                    .font(.system(size: 9, weight: .black))
                    .foregroundStyle(LiveDesign.background)
                    .shadow(color: LiveDesign.text.opacity(0.9), radius: 0.5)
                    .offset(x: -1)
            }
        }
    }

    private var railBody: some View {
        VStack(spacing: 4) {
            Image(systemName: batterySymbol)
                .font(.system(size: 18, weight: .regular))
                .foregroundStyle(batteryTint)
                .overlay { chargingOverlay }
            Text(readout)
                .font(.system(size: 10.5, weight: .medium, design: .monospaced))
                .foregroundStyle(LiveDesign.text.opacity(0.72))
            Image(systemName: deviceSystemName)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(LiveDesign.muted)
        }
        .frame(
            width: CGFloat(MonitorBatteryRailLayout.indicatorWidth),
            height: CGFloat(MonitorBatteryRailLayout.indicatorHeight)
        )
    }

    private var compactRailBody: some View {
        VStack(spacing: 1) {
            Image(systemName: batterySymbol)
                .font(.system(size: 15, weight: .regular))
                .foregroundStyle(batteryTint)
                .overlay { chargingOverlay }
            Text(readout)
                .font(.system(size: 9, weight: .medium, design: .monospaced))
                .foregroundStyle(LiveDesign.text.opacity(0.72))
        }
        .frame(
            width: CGFloat(MonitorBatteryRailLayout.indicatorWidth),
            height: CGFloat(MonitorBatteryRailLayout.compactPhoneIndicatorHeight)
        )
        .accessibilityLabel("iPhone battery")
        .accessibilityValue(readout)
    }

    /// Portrait top-bar presentation (R2): one row, battery glyph / percent / device glyph,
    /// reusing the rail's exact symbol/readout/color/charging logic.
    private var inlineBody: some View {
        HStack(spacing: 5) {
            Image(systemName: batterySymbol)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(batteryTint)
                .overlay { chargingOverlay }
            Text(readout)
                .font(.system(size: 13, weight: .medium, design: .monospaced))
                .foregroundStyle(LiveDesign.text.opacity(0.72))
            Image(systemName: deviceSystemName)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(LiveDesign.muted)
        }
    }
}
