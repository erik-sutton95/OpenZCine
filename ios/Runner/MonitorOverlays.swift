import CoreMotion
import MonitorPresentation
import MonitorUI
import OpenCineMedia
import OpenZCineCore
import SwiftUI

struct FeedAssistOverlayModule: View {
    @Environment(NativeAppModel.self) private var model
    let safeArea: MonitorEdgeInsets
    let viewportWidth: Double
    let canvasOffsetX: Double
    var horizontalDirection: MonitorHorizontalLayoutDirection = .standard
    /// Suppresses the floating scope/false-colour `MovablePanel`s. Set by `MonitorShell`'s
    /// portrait branch: those panels bleed over the narrow portrait feed strip and are redundant
    /// there — `PortraitScopesStack` already shows scopes. Landscape never passes this.
    var suppressFloatingScopes: Bool = false

    var body: some View {
        // Photography filters the cinema-only panels (a flipped-over video scope must not
        // ride into the photo chrome); the persisted set itself is untouched.
        let visible = model.renderedLiveAssistTools
        GeometryReader { proxy in
            let feedFrame = MonitorFeedLayout.fullBleedFrame(
                viewportWidth: viewportWidth,
                viewportHeight: Double(proxy.size.height),
                safeArea: safeArea,
                horizontalDirection: horizontalDirection
            )
            let feedRect = CGRect(
                x: CGFloat(feedFrame.x),
                y: CGFloat(feedFrame.y),
                width: CGFloat(feedFrame.width),
                height: CGFloat(feedFrame.height)
            )
            let screenBounds = CGRect(
                x: 0, y: 0, width: CGFloat(viewportWidth), height: proxy.size.height)
            // Bands the inside-fallback anchors must clear: the status pill on top, the floating
            // assist/capture strips on the bottom (reserved in every mode — see
            // `landscapeBottomBarHeight` in MonitorUnified.swift).
            let chromeClearance = EdgeInsets(
                top: CGFloat(
                    MonitorChromeLayout.insets(feedSafeArea: safeArea).clearingWindowControls.top
                        + MonitorLiveViewModuleLayout.topInfoDeckHeight),
                leading: 0,
                bottom: CGFloat(MonitorLiveViewModuleLayout.bottomBarBottomInset)
                    + LiveDesign.controlHeight,
                trailing: 0)
            ZStack(alignment: .topLeading) {
                // Guides/grid/crosshair/level draw on the feed image itself (`FeedAlignedAssists`);
                // the shared scope panels, audio meters and false-colour reference float here,
                // skipped in portrait (see `suppressFloatingScopes`).
                if !suppressFloatingScopes {
                    NikonScopeOverlay(
                        tools: visible, bundle: model.scopeAssist,
                        mapping: model.exposureSignalMapping, canvas: screenBounds,
                        clearance: chromeClearance, onOptions: { model.presentAssistOptions($0) })
                    if visible.contains(.audioMeters) {
                        let size = MonitorAudioMetrics.panelSize
                        MovablePanel(
                            id: "audio", size: size,
                            defaultCenter: feedOutsideCenter(
                                feedRect, size, .bottomTrailing,
                                bounds: screenBounds, chromeClearance: chromeClearance),
                            bounds: screenBounds
                        ) {
                            NikonAudioMeter(
                                levels: model.liveAudioLevels,
                                sensitivity: model.commandMicrophoneSensLabel)
                        }
                    }
                    if visible.contains(.falseColor)
                        && model.assist.falseColorReference
                    {
                        let size = MonitorFalseColorReference.panelSize
                        MovablePanel(
                            id: "fcref", size: size,
                            // An unplaced key starts at the canvas centre, as on Pocket.
                            defaultCenter: CGPoint(x: screenBounds.midX, y: screenBounds.midY),
                            bounds: screenBounds
                        ) {
                            MonitorFalseColorReference(
                                values: FalseColorReference.values(
                                    scale: model.assist.falseColorScale.nikonScale,
                                    mapping: model.exposureSignalMapping))
                        }
                    }
                }
            }
            .frame(
                width: CGFloat(viewportWidth),
                height: proxy.size.height,
                alignment: .topLeading
            )
            .offset(x: CGFloat(canvasOffsetX))
        }
    }
}

/// Default centre for the floating audio meter, anchored just outside the video feed edge. When the
/// outside position doesn't fit `bounds` — landscape's full-bleed feed spans the whole screen, so
/// "outside" is off-screen and `MovablePanel`'s clamp would park the panel behind the floating
/// chrome — the anchor mirrors to just inside the feed edge instead, pushed past `chromeClearance`
/// (top status pill band, bottom assist/capture strip band).
private func feedOutsideCenter(
    _ feedRect: CGRect, _ size: CGSize, _ anchor: Alignment,
    bounds: CGRect, chromeClearance: EdgeInsets = EdgeInsets(), gap: CGFloat = 10
) -> CGPoint {
    let halfWidth = size.width / 2
    let halfHeight = size.height / 2
    let x: CGFloat =
        anchor.horizontal == .leading
        ? feedRect.minX + halfWidth
        : (anchor.horizontal == .trailing ? feedRect.maxX - halfWidth : feedRect.midX)
    let y: CGFloat
    switch anchor.vertical {
    case .top:
        let outside = feedRect.minY - gap - halfHeight
        y =
            outside - halfHeight >= bounds.minY
            ? outside
            : max(feedRect.minY, bounds.minY + chromeClearance.top) + gap + halfHeight
    case .bottom:
        let outside = feedRect.maxY + gap + halfHeight
        y =
            outside + halfHeight <= bounds.maxY
            ? outside
            : min(feedRect.maxY, bounds.maxY - chromeClearance.bottom) - gap - halfHeight
    default:
        y = feedRect.midY
    }
    return CGPoint(x: x, y: y)
}

/// Floating scope panels for media playback — same layout as the live monitor but fed from sampled
/// `AVPlayer` frames instead of the live-view loop.
struct PlaybackAssistOverlayModule: View {
    @Environment(NativeAppModel.self) private var model
    let scopeAssist: ScopeAssistBundle
    /// Aspect-fit video rectangle in the overlay coordinate space.
    let videoRect: CGRect
    /// Metered playback audio; absent before a real sample or when the tool is off.
    var audioLevels: AudioMeterLevels?
    let onOptions: (MonitorAssistTool) -> Void

    var body: some View {
        let visible = model.assist.playbackTools
        GeometryReader { proxy in
            let screenBounds = CGRect(origin: .zero, size: proxy.size)
            let feedRect = videoRect
            ZStack(alignment: .topLeading) {
                NikonScopeOverlay(
                    tools: visible, bundle: scopeAssist,
                    mapping: model.playbackExposureSignalMapping, canvas: screenBounds,
                    onOptions: onOptions)
                if visible.contains(.audioMeters) {
                    let size = MonitorAudioMetrics.panelSize
                    MovablePanel(
                        id: "playback-audio", size: size,
                        defaultCenter: feedOutsideCenter(
                            feedRect, size, .bottomTrailing, bounds: screenBounds),
                        bounds: screenBounds
                    ) {
                        NikonAudioMeter(levels: audioLevels, sensitivity: nil)
                    }
                }
                if visible.contains(.falseColor)
                    && model.assist.falseColorReference
                {
                    let size = MonitorFalseColorReference.panelSize
                    MovablePanel(
                        id: "playback-fcref", size: size,
                        defaultCenter: CGPoint(x: screenBounds.midX, y: screenBounds.midY),
                        bounds: screenBounds
                    ) {
                        MonitorFalseColorReference(
                            values: FalseColorReference.values(
                                scale: model.assist.falseColorScale.nikonScale,
                                mapping: model.playbackExposureSignalMapping))
                    }
                }
            }
        }
        .allowsHitTesting(true)
    }
}

/// Two-stroke L-corner resize affordance for a bottom-trailing exterior grip. The vertex sits at the
/// rect's bottom-trailing corner (exterior); legs extend left and up back toward the panel corner.
struct CornerResizeGrip: Shape {
    func path(in rect: CGRect) -> Path {
        let leg = min(rect.width, rect.height)
        let vertex = CGPoint(x: rect.maxX, y: rect.maxY)
        var path = Path()
        path.move(to: vertex)
        path.addLine(to: CGPoint(x: vertex.x - leg, y: vertex.y))
        path.move(to: vertex)
        path.addLine(to: CGPoint(x: vertex.x, y: vertex.y - leg))
        return path
    }
}

/// Long-press-and-drag wrapper for a floating panel (a scope or the false-colour reference). After a
/// brief hold the panel lifts and follows the finger, clamped inside `bounds` and snapped to a coarse
/// grid; a rigid tap fires on pick-up and a light tick on each snap, in keeping with the assist
/// haptics. Positions persist across launches via `model.movablePanelPositions`.
struct MovablePanel<Content: View>: View {
    /// Optional uniform-resize support: a corner handle whose long-press-drag scales the panel. The
    /// panel reads its current `size` from the caller (base × scale); the handle reports a new scale
    /// back through `onChange`, and `baseSize`/`range` drive the drag-to-scale maths and clamp.
    struct Resize {
        var scale: Double
        var range: ClosedRange<Double>
        var baseSize: CGSize
        var onChange: (Double) -> Void
    }

    @Environment(NativeAppModel.self) private var model
    let id: String
    let size: CGSize
    let defaultCenter: CGPoint
    let bounds: CGRect
    var resize: Resize? = nil
    @ViewBuilder var content: () -> Content

    @State private var dragOrigin: CGPoint?
    @State private var isDragging = false
    @State private var snapCell = 0
    @State private var isResizing = false
    @State private var resizeStartScale = 1.0

    // A fine position snap keeps the drag feeling smooth; the haptic ticks on a coarser interval so
    // it doesn't buzz continuously while moving.
    private let positionGrid: CGFloat = 4
    private let hapticGrid: CGFloat = 22
    /// Minimum touch target for the exterior resize grip (HIG + operator margin).
    private let gripHitSize: CGFloat = 56
    /// Visible L-bracket leg length.
    private let gripVisualSize: CGFloat = 14
    /// Invisible padding around the panel body for long-press drag pickup.
    private let dragHitPadding: CGFloat = 10
    /// Clearance from the panel's bottom-trailing corner to the grip vertex.
    private let gripExteriorGap: CGFloat = 2
    /// Pulls the grip toward the panel corner while keeping the vertex outside.
    private var gripCornerInset: CGFloat { gripVisualSize - gripExteriorGap }

    var body: some View {
        let center = clamp(resolvedCenter())
        let gripPad = resize != nil ? gripHitSize - gripCornerInset : 0
        // Expand layout bounds so the exterior grip stays hit-testable; shift `.position` to keep the
        // scope panel itself anchored at `center`.
        ZStack(alignment: .topLeading) {
            content()
                // Anchor the grip to the panel chrome's bottom-trailing corner (intrinsic bounds),
                // not the outer layout frame — fixed-size scope innards otherwise drift from `size`.
                .overlay(alignment: .bottomTrailing) {
                    if let resize {
                        resizeHandle(resize)
                            .offset(x: gripExteriorGap, y: gripExteriorGap)
                    }
                }
                .frame(width: size.width, height: size.height, alignment: .topLeading)
                .padding(dragHitPadding)
                .contentShape(Rectangle())
                .padding(-dragHitPadding)
                .gesture(panelDragGesture(center: center))
        }
        .frame(
            width: size.width + gripPad,
            height: size.height + gripPad,
            alignment: .topLeading
        )
        .scaleEffect((isDragging || isResizing) ? 1.03 : 1)
        .shadow(color: .black.opacity((isDragging || isResizing) ? 0.5 : 0), radius: 18, y: 8)
        .position(x: center.x + gripPad / 2, y: center.y + gripPad / 2)
        .sensoryFeedback(trigger: isDragging) { _, dragging in
            dragging ? .impact(flexibility: .rigid, intensity: 1) : nil
        }
        .sensoryFeedback(.selection, trigger: snapCell)
        .sensoryFeedback(trigger: isResizing) { _, resizing in
            resizing ? .impact(flexibility: .rigid, intensity: 0.8) : nil
        }
        .animation(.easeOut(duration: 0.14), value: isDragging)
        .animation(.easeOut(duration: 0.14), value: isResizing)
    }

    /// Long-press then drag on the panel body to reposition (not applied to the resize grip).
    private func panelDragGesture(center: CGPoint) -> some Gesture {
        LongPressGesture(minimumDuration: 0.3)
            .sequenced(before: DragGesture(minimumDistance: 0, coordinateSpace: .global))
            .onChanged { value in
                guard case .second(true, let drag) = value else { return }
                if !isDragging {
                    isDragging = true
                    dragOrigin = center
                }
                guard let drag, let origin = dragOrigin else { return }
                let proposed = CGPoint(
                    x: origin.x + drag.translation.width,
                    y: origin.y + drag.translation.height)
                let snapped = clamp(snap(proposed))
                let cell =
                    Int((snapped.x / hapticGrid).rounded()) &* 100_000
                    &+ Int((snapped.y / hapticGrid).rounded())
                if cell != snapCell { snapCell = cell }
                model.movablePanelCenters[id] = snapped
            }
            .onEnded { _ in
                if let final = model.movablePanelCenters[id] {
                    model.setMovablePanelCenter(id, final, bounds: bounds)
                }
                isDragging = false
                dragOrigin = nil
            }
    }

    /// L-corner grip outside the panel's bottom-trailing corner; long-press then drag to scale uniformly.
    private func resizeHandle(_ resize: Resize) -> some View {
        let gripColor = isResizing ? LiveDesign.accent : LiveDesign.muted
        return CornerResizeGrip()
            .stroke(
                gripColor,
                style: StrokeStyle(lineWidth: 1.5, lineCap: .square)
            )
            // Vertex sits on the overlay anchor (panel bottom-trailing); legs extend inward.
            .frame(width: gripVisualSize, height: gripVisualSize, alignment: .bottomTrailing)
            // Touch target extends past the visible bracket along the exterior legs.
            .frame(width: gripHitSize, height: gripHitSize, alignment: .bottomTrailing)
            .contentShape(Rectangle())
            .gesture(resizeGesture(resize))
    }

    private func resizeGesture(_ resize: Resize) -> some Gesture {
        LongPressGesture(minimumDuration: 0.3)
            .sequenced(before: DragGesture(minimumDistance: 0, coordinateSpace: .global))
            .onChanged { value in
                guard case .second(true, let drag) = value else { return }
                if !isResizing {
                    isResizing = true
                    resizeStartScale = resize.scale
                }
                guard let drag else { return }
                // Exterior bottom-trailing grip: drag down-right enlarges, up-left shrinks.
                // Normalise by the base footprint so the feel is consistent at any current scale.
                let reach = resize.baseSize.width + resize.baseSize.height
                let delta = (drag.translation.width + drag.translation.height) / reach
                let newScale = min(
                    max(resizeStartScale + delta, resize.range.lowerBound), resize.range.upperBound)
                resize.onChange(newScale)
            }
            .onEnded { _ in isResizing = false }
    }

    private func resolvedCenter() -> CGPoint {
        if let session = model.movablePanelCenters[id] { return session }
        if let stored = model.movablePanelPositions[id] { return stored.center(in: bounds) }
        return defaultCenter
    }

    private func clamp(_ point: CGPoint) -> CGPoint {
        let halfWidth = size.width / 2
        let halfHeight = size.height / 2
        return CGPoint(
            x: min(max(bounds.minX + halfWidth, point.x), bounds.maxX - halfWidth),
            y: min(max(bounds.minY + halfHeight, point.y), bounds.maxY - halfHeight))
    }

    private func snap(_ point: CGPoint) -> CGPoint {
        CGPoint(
            x: (point.x / positionGrid).rounded() * positionGrid,
            y: (point.y / positionGrid).rounded() * positionGrid)
    }
}

/// The on-screen rectangle where video is drawn with `AVLayerVideoGravity.resizeAspect` (aspect fit):
/// letterbox when the container is wider than the clip, pillarbox when taller.
func aspectFitRect(videoSize: CGSize, in container: CGRect) -> CGRect {
    guard videoSize.width > 0, videoSize.height > 0, container.width > 0, container.height > 0
    else {
        return container
    }
    let videoAspect = videoSize.width / videoSize.height
    let containerAspect = container.width / container.height
    if containerAspect > videoAspect {
        let height = container.height
        let width = height * videoAspect
        return CGRect(
            x: container.minX + (container.width - width) / 2,
            y: container.minY,
            width: width,
            height: height)
    }
    let width = container.width
    let height = width / videoAspect
    return CGRect(
        x: container.minX,
        y: container.minY + (container.height - height) / 2,
        width: width,
        height: height)
}

/// Applies a video track's `preferredTransform` so width/height match the displayed frame.
func videoDisplaySize(naturalSize: CGSize, transform: CGAffineTransform) -> CGSize {
    let rect = CGRect(origin: .zero, size: naturalSize).applying(transform)
    return CGSize(width: abs(rect.width), height: abs(rect.height))
}

/// The on-screen scale applied to the live image to de-squeeze anamorphic footage: shrink one axis
/// by the squeeze factor (letterbox for the shared horizontal direction, else pillarbox).
func desqueezeScale(_ desqueeze: NikonDesqueeze) -> CGSize {
    guard desqueeze.factor > 1 else { return CGSize(width: 1, height: 1) }
    let factor = CGFloat(desqueeze.factor)
    return desqueeze.horizontal
        ? CGSize(width: 1, height: 1 / factor)
        : CGSize(width: 1 / factor, height: 1)
}

/// A still's presented size once de-squeezed: the source with the chosen axis divided out.
///
/// Stills cannot use ``desqueezeScale`` the way the live feed does. The feed layer is scaled inside
/// a fixed rect, but a still is FITTED to its container first, so scaling afterwards would push the
/// image outside the frame it was just fitted into. De-squeezing the size before the fit keeps the
/// whole picture on screen and lets everything anchored to the fitted rect — the AF box on instant
/// review, the zoom transform in the viewer — follow without knowing about anamorphic at all.
func desqueezedSize(_ size: CGSize, _ desqueeze: NikonDesqueeze) -> CGSize {
    guard desqueeze.factor > 1, size.width > 0, size.height > 0 else { return size }
    let factor = CGFloat(desqueeze.factor)
    return desqueeze.horizontal
        ? CGSize(width: size.width, height: size.height / factor)
        : CGSize(width: size.width / factor, height: size.height)
}

/// ``desqueezedSize`` as an aspect ratio, for the SwiftUI fits that take one. `nil` when
/// de-squeeze is off, which `aspectRatio(_:contentMode:)` reads as "use the image's own".
func desqueezedAspectRatio(_ size: CGSize, _ desqueeze: NikonDesqueeze) -> CGFloat? {
    guard desqueeze.factor > 1, size.width > 0, size.height > 0 else { return nil }
    let presented = desqueezedSize(size, desqueeze)
    return presented.width / presented.height
}

/// The visible (de-squeezed) image rectangle inside the full feed rect — the same centred sub-rect
/// the scale above produces, so framing overlays land on the de-squeezed image.
func desqueezedRect(_ full: CGRect, _ desqueeze: NikonDesqueeze) -> CGRect {
    guard desqueeze.factor > 1 else { return full }
    let factor = CGFloat(desqueeze.factor)
    if desqueeze.horizontal {
        let height = full.height / factor
        return CGRect(x: full.minX, y: full.midY - height / 2, width: full.width, height: height)
    }
    let width = full.width / factor
    return CGRect(x: full.midX - width / 2, y: full.minY, width: width, height: full.height)
}

/// Framing aids that must register pixel-exact with the live image — guides, grid, crosshair, and
/// level. Drawn as an overlay *on the feed image itself* (like the AF boxes), so they share the feed
/// rectangle by construction instead of recomputing it. Positioned against the visible feed rect the
/// same way the index.html prototype does.
struct FeedAlignedAssists: View {
    @Environment(NativeAppModel.self) private var model
    /// Clean output mode (DISP 2). Which tools survive it is decided by `MonitorChromePolicy` via
    /// `renderedLiveAssistTools` — nothing unless the operator pinned it. This flag only carries
    /// the layout consequence (no bottom bars, so the EV needle drops to the feed edge).
    var clean: Bool = false
    /// When set (e.g. letterboxed media playback), framing overlays align to this rect instead of
    /// the full geometry.
    var feed: CGRect? = nil
    /// Tools omitted from this overlay (e.g. horizon level during clip playback).
    var excludeTools: Set<MonitorAssistTool> = []
    /// When true, reads playback assist visibility instead of the live monitor set.
    var usePlaybackContext: Bool = false

    var body: some View {
        GeometryReader { proxy in
            let baseFeed = feed ?? CGRect(origin: .zero, size: proxy.size)
            let visible =
                (usePlaybackContext
                ? model.assist.playbackTools
                : model.renderedLiveAssistTools).subtracting(excludeTools)
            let feed = desqueezedRect(
                baseFeed, model.assist.desqueeze(visible: visible.contains(.desqueeze)))
            ZStack {
                if visible.contains(.guides) {
                    MonitorAspectGuideFrames(
                        selectedRatios: model.assist.selectedGuides,
                        maskEnabled: model.assist.guideMask, feed: feed)
                }
                if visible.contains(.evMeter),
                    // Photography-only: a persisted visibility set from an older build may
                    // still carry the tool, so the render guards the mode as well.
                    model.isPhotographyMode,
                    let sixths = model.cameraPropertySnapshot.evIndicatorSixths,
                    model.cameraPropertySnapshot.evIndicatorLit != false
                {
                    // Camera-fed exposure needle, seated bottom-centre of the feed. It lifts
                    // above the capture bar's lane only where a bar actually overlays the feed
                    // (landscape live, portrait fill); clean mode and portrait fit keep the
                    // feed bottom free, so it drops to the edge.
                    let feedBottomFree =
                        model.monitorIsPortrait
                        && (model.isPhotographyMode
                            || model.preferences.portraitFeedAspect != .fill)
                    EVMeterView(sixths: sixths)
                        .position(
                            x: feed.midX, y: feed.maxY - (clean || feedBottomFree ? 28 : 92)
                        )
                        .allowsHitTesting(false)
                }
                if visible.contains(.grid) {
                    MonitorFeedGrid(
                        feed: feed, thirds: model.assist.gridThirds, phi: model.assist.gridPhi,
                        diagonal: model.assist.gridDiagonal)
                }
                if visible.contains(.crosshair) {
                    MonitorFeedCrosshair(feed: feed)
                }
                // Drawn once over the whole feed like every other framing aid, from the same rect
                // — so the divider lands exactly on the boundary the grade was split at.
                if let split = LUTResolution.splitComparison(
                    visibleTools: visible, enabled: model.assist.splitComparison,
                    vertical: model.assist.splitVertical, muted: model.splitComparisonMuted)
                {
                    MonitorFeedComparisonMarks(
                        vertical: split == .vertical, feed: feed,
                        originalLabel: SplitComparison.logLabel,
                        processedLabel: SplitComparison.lutLabel)
                }
                if visible.contains(.level) {
                    FeedLevelView(
                        style: model.assistConfiguration.level.style, feed: feed,
                        visibleBounds: Self.visibleBounds(
                            contentGlobal: proxy.frame(in: .global), size: proxy.size,
                            screen: screenBounds))
                }
            }
        }
        .allowsHitTesting(false)
    }

    /// The foreground scene's bounds — the on-screen area the over-widened feed content gets
    /// clipped to (the portrait fill crop frame spans the full viewport width, so the screen
    /// intersection and the clip intersection coincide).
    private var screenBounds: CGRect? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let scene = scenes.first { $0.activationState == .foregroundActive } ?? scenes.first
        return scene?.coordinateSpace.bounds
    }

    /// The portion of this overlay that is actually on screen, in its own coordinate space.
    ///
    /// Framing aids register pixel-exact with the feed content — including content that portrait
    /// fill (and fill + de-squeeze) over-widens past the screen and clips. HUD instruments like the
    /// level gauge instead seat against what the operator can see; this recovers that rect by
    /// intersecting the content with the screen (`screen` and `contentGlobal` share the global
    /// space). Falls back to the full content bounds when the intersection degenerates (no scene
    /// yet, zero-size first layout).
    static func visibleBounds(contentGlobal: CGRect, size: CGSize, screen: CGRect?) -> CGRect {
        let bounds = CGRect(origin: .zero, size: size)
        guard let screen else { return bounds }
        let screenLocal = screen.offsetBy(dx: -contentGlobal.minX, dy: -contentGlobal.minY)
        let visible = bounds.intersection(screenLocal)
        return visible.isNull || visible.isEmpty ? bounds : visible
    }
}

/// Artificial horizon, two styles: a rolling horizon line and a two-axis bubble gauge; both go
/// green within ±0.8° of level.
///
/// Reads the **camera's** virtual horizon (PTP `AngleLevelYawing` 0xD07E roll /
/// `AngleLevelPitching` 0xD07D pitch) so the horizon reflects the shot's tilt, not the monitor's.
/// The value encoding is undocumented — decoded best-effort and logged for HW calibration
/// (category `camera-level`). Falls back to the monitor's CoreMotion until the body reports one.
struct FeedLevelView: View {
    @Environment(NativeAppModel.self) private var model
    let style: AssistConfiguration.Level.Style
    let feed: CGRect
    /// On-screen portion of the overlay in its coordinate space — what the gauge seats against.
    let visibleBounds: CGRect
    @State private var device = DeviceLevel()

    var body: some View {
        let usesDeviceFallback = model.cameraLevelRoll == nil
        let roll = model.cameraLevelRoll ?? device.roll
        let pitch = model.cameraLevelPitch ?? device.pitch
        // Portrait fill overlays a capture strip on the visible feed's bottom edge; the roll track
        // seats above it. Fit tiles its controls below the feed band, so nothing to clear there.
        let bottomChrome =
            model.monitorIsPortrait && model.preferences.portraitFeedAspect == .fill
            ? CGFloat(MonitorPortraitLayout.captureBarHeight) : 0
        Group {
            if style == .gauge {
                LevelGaugeView(
                    roll: roll, pitch: pitch, feed: feed, visibleBounds: visibleBounds,
                    isPortrait: model.monitorIsPortrait, bottomChrome: bottomChrome)
            } else {
                LevelHorizonView(roll: roll)
                    .position(x: feed.midX, y: feed.midY)
            }
        }
        // Only run device motion while it's actually the source — stop it once the camera supplies a
        // level so the monitor's own tilt can't leak into the readout.
        .onAppear { if usesDeviceFallback { device.start() } }
        .onChange(of: usesDeviceFallback) { _, fallback in
            fallback ? device.start() : device.stop()
        }
        // The gravity→roll mapping depends on which way the interface is rotated, so keep the
        // motion source told about the current shell orientation.
        .onChange(of: model.monitorIsPortrait, initial: true) { _, portrait in
            device.isPortrait = portrait
        }
        .onDisappear { device.stop() }
    }
}

/// Streams the device's gravity-derived roll/pitch (degrees) while the level overlay is on. Gravity
/// arrives in CoreMotion's fixed, portrait-referenced device frame (+x out the right edge, +y out
/// the top, +z out of the screen), so the screen-plane roll depends on which way the interface is
/// rotated — `isPortrait` selects the mapping for the two orientations the app supports (Portrait,
/// LandscapeRight). The simulator reports no motion, so the mapping is derived from CoreMotion's
/// documented axis conventions; on-hardware sign calibration may still want a one-line flip.
@Observable
final class DeviceLevel {
    var roll: Double = 0
    var pitch: Double = 0
    /// True while the monitor shell is laid out portrait; kept current by the hosting view.
    var isPortrait = false

    @ObservationIgnored private let manager = CMMotionManager()

    /// Screen-plane roll in degrees from the device-frame gravity vector: 0 = upright for the
    /// given interface orientation, positive = tilted clockwise from the viewer's perspective.
    ///
    /// Roll is the angle of gravity off screen-down, toward screen-right: `atan2(g·right, g·down)`.
    /// Portrait: screen right/down = device +x/−y. LandscapeRight (home side right, device +x
    /// pointing at the sky, so g.x = −1 when level): screen right/down = device −y/−x.
    static func displayRoll(gravityX: Double, gravityY: Double, isPortrait: Bool) -> Double {
        let radians =
            isPortrait
            ? atan2(gravityX, -gravityY)
            : atan2(-gravityY, -gravityX)
        return radians * 180 / .pi
    }

    func start() {
        guard manager.isDeviceMotionAvailable, !manager.isDeviceMotionActive else { return }
        manager.deviceMotionUpdateInterval = 1.0 / 30.0
        manager.startDeviceMotionUpdates(to: .main) { [weak self] motion, _ in
            guard let self, let g = motion?.gravity else { return }
            let newRoll = Self.displayRoll(gravityX: g.x, gravityY: g.y, isPortrait: isPortrait)
            let newPitch = atan2(g.z, (g.x * g.x + g.y * g.y).squareRoot()) * 180 / .pi
            // Light low-pass so the readout settles instead of jittering on every sample.
            roll = roll * 0.75 + newRoll * 0.25
            pitch = pitch * 0.75 + newPitch * 0.25
        }
    }

    func stop() {
        if manager.isDeviceMotionActive { manager.stopDeviceMotionUpdates() }
    }
}

/// Rolling horizon: two accent wings around a centre ring, rotating with roll; green when level.
struct LevelHorizonView: View {
    let roll: Double

    var body: some View {
        let level = abs(roll) < 0.8
        let color = level ? LiveDesign.good : LiveDesign.accent
        HStack(spacing: 10) {
            Capsule().fill(color).frame(width: 64, height: 2)
            Circle().stroke(color, lineWidth: 1.6).frame(width: 10, height: 10)
            Capsule().fill(color).frame(width: 64, height: 2)
        }
        .rotationEffect(.degrees(roll))
        .animation(.easeOut(duration: 0.18), value: level)
    }
}

/// Two-axis level: a horizontal track (roll) near the bottom and a vertical track (pitch) on the
/// right. Each track carries 2° tick graduations so you can feel how far off you are, a correction
/// chevron pointing the way back to centre (more chevrons = further off), and a live degree readout.
/// A track snaps green within ±0.6° on its own axis.
/// The body's exposure indicator as a compact glass strip: a ±3 EV tick bar (taller ticks
/// on whole stops), the camera's 1/6-EV needle, and a signed numeric readout that keeps the
/// truth when the needle clamps at the rail. Read-only — the value comes straight from the
/// camera's own metering.
struct EVMeterView: View {
    let sixths: Int

    private var ev: Double { Double(sixths) / 6 }

    private var readout: String {
        String(format: "%+.1f", ev)
    }

    var body: some View {
        HStack(spacing: 10) {
            Text(readout)
                .font(.system(size: 11.5, weight: .semibold, design: .monospaced))
                .foregroundStyle(abs(ev) < 0.01 ? LiveDesign.text : LiveDesign.accent)
                .frame(width: 34, alignment: .trailing)
            Canvas { context, size in
                let midY = size.height / 2
                let usable = size.width
                let evSpan = 3.0
                func x(forEV value: Double) -> CGFloat {
                    let clamped = min(evSpan, max(-evSpan, value))
                    return CGFloat((clamped + evSpan) / (2 * evSpan)) * usable
                }
                // Baseline.
                var base = Path()
                base.move(to: CGPoint(x: 0, y: midY))
                base.addLine(to: CGPoint(x: usable, y: midY))
                context.stroke(base, with: .color(.white.opacity(0.25)), lineWidth: 1)
                // Ticks every 1/3 EV; whole stops taller.
                var third = -9
                while third <= 9 {
                    let value = Double(third) / 3
                    let tall = third % 3 == 0
                    let height: CGFloat = tall ? 8 : 4
                    var tick = Path()
                    let tickX = x(forEV: value)
                    tick.move(to: CGPoint(x: tickX, y: midY - height / 2))
                    tick.addLine(to: CGPoint(x: tickX, y: midY + height / 2))
                    context.stroke(
                        tick, with: .color(.white.opacity(tall ? 0.55 : 0.3)), lineWidth: 1)
                    third += 1
                }
                // The needle.
                var needle = Path()
                let needleX = x(forEV: ev)
                needle.move(to: CGPoint(x: needleX, y: 1))
                needle.addLine(to: CGPoint(x: needleX, y: size.height - 1))
                context.stroke(needle, with: .color(LiveDesign.accent), lineWidth: 2)
            }
            .frame(width: 132, height: 16)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .liquidGlass(in: Capsule())
    }
}

struct LevelGaugeView: View {
    let roll: Double
    let pitch: Double
    let feed: CGRect
    /// On-screen portion of the overlay's coordinate space (see `FeedAlignedAssists.visibleBounds`).
    let visibleBounds: CGRect
    let isPortrait: Bool
    /// Height of chrome overlaying the visible feed's bottom edge (portrait fill capture strip).
    let bottomChrome: CGFloat

    /// Seats for the two tracks. The gauge is a HUD instrument, not a framing aid: unlike
    /// grid/crosshair/guides (which stay pixel-exact with the image content, even when portrait
    /// fill or de-squeeze widen it past the screen), the gauge seats against the VISIBLE feed —
    /// the content rect intersected with the on-screen bounds — so neither track can land in the
    /// clipped-away overhang.
    ///
    /// Roll (horizontal track): centred, lifted off the visible bottom edge — landscape by the
    /// bottom capture/assist bars that overlay the feed (chrome bottom inset 12 + control height
    /// 58, plus the gauge's readout half-height and a small gap), portrait by a bottom-edge hug
    /// plus `bottomChrome` for any strip overlaying the visible feed (fill's capture bar).
    /// Pitch (vertical track): hugs the visible trailing edge, readout on the feed side.
    static func seats(
        feed: CGRect, visibleBounds: CGRect, isPortrait: Bool, bottomChrome: CGFloat
    ) -> (roll: CGPoint, pitch: CGPoint) {
        var visible = feed.intersection(visibleBounds)
        if visible.isNull || visible.isEmpty { visible = feed }
        let rollLift = (isPortrait ? 30 : 104) + bottomChrome
        return (
            roll: CGPoint(x: visible.midX, y: visible.maxY - rollLift),
            pitch: CGPoint(x: visible.maxX - 44, y: visible.midY)
        )
    }

    var body: some View {
        let seats = Self.seats(
            feed: feed, visibleBounds: visibleBounds, isPortrait: isPortrait,
            bottomChrome: bottomChrome)
        ZStack {
            LevelAxisGauge(orientation: .horizontal, value: roll)
                .position(seats.roll)
            LevelAxisGauge(orientation: .vertical, value: pitch)
                .position(seats.pitch)
        }
        .allowsHitTesting(false)
    }
}

/// One axis of the level gauge — a graduated track with a bead, a correction chevron, and a degree
/// readout. `value` is signed degrees (0 = level); a positive value drives the bead toward the + end.
private struct LevelAxisGauge: View {
    enum Orientation { case horizontal, vertical }
    let orientation: Orientation
    let value: Double

    private let span = 84.0  // px from centre to the ±maxAngle end of the track
    private let maxAngle = 8.0  // degrees mapped to the end of the track
    private let tickStep = 2.0  // graduation spacing in degrees
    private let threshold = 0.6  // |value| below this reads "level"

    private var isHorizontal: Bool { orientation == .horizontal }
    private var isLevel: Bool { abs(value) < threshold }
    private var tint: Color { isLevel ? LiveDesign.good : LiveDesign.accent }
    private var beadOffset: CGFloat { CGFloat(max(-1, min(1, value / maxAngle)) * span) }

    /// 1–3, larger the further off level — drives how many correction chevrons show.
    private var urgency: Int {
        switch abs(value) {
        case ..<(maxAngle / 3): return 1
        case ..<(2 * maxAngle / 3): return 2
        default: return 3
        }
    }

    var body: some View {
        let trackLen = CGFloat(span * 2 + 28)
        ZStack {
            graduations
                .frame(
                    width: isHorizontal ? trackLen : 26,
                    height: isHorizontal ? 26 : trackLen)
            if !isLevel { chevrons }
            bead
            readout
        }
        .animation(.easeOut(duration: 0.12), value: isLevel)
        .animation(.easeOut(duration: 0.09), value: value)
    }

    /// Baseline + 2° tick graduations, the centre tick emphasised.
    private var graduations: some View {
        Canvas { ctx, size in
            let mid = CGPoint(x: size.width / 2, y: size.height / 2)
            var base = Path()
            if isHorizontal {
                base.move(to: CGPoint(x: mid.x - CGFloat(span), y: mid.y))
                base.addLine(to: CGPoint(x: mid.x + CGFloat(span), y: mid.y))
            } else {
                base.move(to: CGPoint(x: mid.x, y: mid.y - CGFloat(span)))
                base.addLine(to: CGPoint(x: mid.x, y: mid.y + CGFloat(span)))
            }
            ctx.stroke(base, with: .color(.white.opacity(0.22)), lineWidth: 2)

            var deg = -maxAngle
            while deg <= maxAngle + 0.001 {
                let t = CGFloat(deg / maxAngle * span)
                let centre = abs(deg) < 0.001
                let half: CGFloat = centre ? 9 : 5
                var tick = Path()
                if isHorizontal {
                    tick.move(to: CGPoint(x: mid.x + t, y: mid.y - half))
                    tick.addLine(to: CGPoint(x: mid.x + t, y: mid.y + half))
                } else {
                    tick.move(to: CGPoint(x: mid.x - half, y: mid.y - t))
                    tick.addLine(to: CGPoint(x: mid.x + half, y: mid.y - t))
                }
                ctx.stroke(
                    tick, with: .color(.white.opacity(centre ? 0.75 : 0.34)),
                    lineWidth: centre ? 2 : 1)
                deg += tickStep
            }
        }
    }

    private var bead: some View {
        Circle()
            .fill(tint)
            .frame(width: 13, height: 13)
            .overlay(Circle().stroke(.black.opacity(0.45), lineWidth: 2))
            .shadow(color: .black.opacity(0.5), radius: 3)
            .offset(
                x: isHorizontal ? beadOffset : 0,
                y: isHorizontal ? 0 : -beadOffset)
    }

    /// Chevrons just centre-ward of the bead, pointing toward centre — the way to re-level.
    private var chevrons: some View {
        let toNegative = value > 0  // need to move toward the − end to re-centre
        let symbol =
            isHorizontal
            ? (toNegative ? "chevron.left" : "chevron.right")
            : (toNegative ? "chevron.down" : "chevron.up")
        let gap: CGFloat = 16
        let sign = CGFloat(value > 0 ? 1 : -1)
        return Group {
            if isHorizontal {
                HStack(spacing: -2) {
                    ForEach(Array(0..<urgency), id: \.self) { i in chevronGlyph(symbol, index: i) }
                }
            } else {
                VStack(spacing: -2) {
                    ForEach(Array(0..<urgency), id: \.self) { i in chevronGlyph(symbol, index: i) }
                }
            }
        }
        .offset(
            x: isHorizontal ? beadOffset - sign * gap : 0,
            y: isHorizontal ? 0 : -beadOffset + sign * gap)
    }

    private func chevronGlyph(_ symbol: String, index: Int) -> some View {
        Image(systemName: symbol)
            .font(.system(size: 10, weight: .heavy))
            .foregroundStyle(LiveDesign.accent)
            .opacity(1.0 - Double(index) * 0.22)
    }

    private var readout: some View {
        let shown = abs(value) < 0.05 ? 0 : value
        return Text(String(format: "%+.1f°", shown))
            .font(.system(size: 11, weight: .semibold, design: .monospaced))
            .foregroundStyle(isLevel ? LiveDesign.good : LiveDesign.text.opacity(0.85))
            .fixedSize()
            .offset(
                x: isHorizontal ? 0 : -42,
                y: isHorizontal ? -24 : 0)
    }
}

/// The camera-aware false-colour key (the Nikon typed extension: zones placed on this camera's
/// curve and clip), drawn by the shared `MonitorFalseColorReference`.
enum FalseColorReference {
    struct Segment: Equatable, Identifiable {
        let id: Int
        let lowerFraction: Double
        let upperFraction: Double
        let band: FalseColorBand
    }

    struct AxisMarker: Equatable, Identifiable {
        let id: Int
        let label: String
        let fraction: Double
    }

    static func values(
        scale: FalseColorScale, mapping: ExposureSignalMapping
    ) -> MonitorFalseColorReferenceValues {
        let scaleLabel =
            switch scale {
            case .stops: "ZC Stops"
            case .ire: "IRE"
            case .limits: "Limits"
            }
        // The measured curve's compact key label; the photo previews are display-referred.
        let curveLabel =
            switch mapping.curve {
            case .redLog3G10: "L3G10"
            case .nikonNLog: "N-Log"
            case .srgb: "sRGB"
            case .hlg: "HLG"
            }
        let axisLabels: [String] =
            switch scale {
            case .stops: []
            case .ire: ["clip / shadows", "18%", "skin hi", "highlights → clip"]
            case .limits: ["crushed", "midtones untouched", "clipped"]
            }
        return MonitorFalseColorReferenceValues(
            subtitle: "\(scaleLabel) · \(curveLabel)",
            segments: segments(scale: scale, mapping: mapping).map {
                MonitorFalseColorReferenceSegment(
                    id: $0.id, lowerFraction: $0.lowerFraction, upperFraction: $0.upperFraction,
                    red: $0.band.red, green: $0.band.green, blue: $0.band.blue)
            },
            markers: scale == .stops
                ? stopAxisMarkers(mapping: mapping).map {
                    MonitorFalseColorReferenceMarker(
                        id: $0.id, label: $0.label, fraction: $0.fraction)
                } : [],
            axisLabels: axisLabels)
    }

    static func segments(
        scale: FalseColorScale, mapping: ExposureSignalMapping
    ) -> [Segment] {
        let bands = scale.bands(mapping: mapping)
        switch scale {
        case .stops:
            let domain = stopReferenceDomain(mapping: mapping)
            return bands.enumerated().map { index, band in
                Segment(
                    id: index,
                    lowerFraction: stopFraction(
                        band.lowerBound, in: domain, infiniteFallback: 0),
                    upperFraction: stopFraction(
                        band.upperBound, in: domain, infiniteFallback: 1),
                    band: band)
            }
        case .ire, .limits:
            return bands.enumerated().map { index, band in
                Segment(
                    id: index,
                    lowerFraction: min(1, max(0, band.lowerBound / 100)),
                    upperFraction: band.upperBound.isFinite
                        ? min(1, max(0, band.upperBound / 100)) : 1,
                    band: band)
            }
        }
    }

    static func stopAxisMarkers(mapping: ExposureSignalMapping) -> [AxisMarker] {
        let domain = stopReferenceDomain(mapping: mapping)
        let maximum = FalseColorMap.maximumSceneStop(mapping: mapping)
        let markers: [(String, Double)] = [
            ("Min", FalseColorMap.minimumSceneStop),
            ("−3", -3),
            ("18%", 0),
            ("Skin", 1),
            ("+2", 2),
            ("Max", maximum),
        ]
        return markers.enumerated().map { index, marker in
            AxisMarker(
                id: index, label: marker.0,
                fraction: stopFraction(marker.1, in: domain, infiniteFallback: 0))
        }
    }

    private static func stopReferenceDomain(
        mapping: ExposureSignalMapping
    ) -> ClosedRange<Double> {
        let lower = FalseColorMap.minimumSceneStop - 1.0 / 6
        let upper = max(6, FalseColorMap.maximumSceneStop(mapping: mapping) + 1.0 / 6)
        return lower...upper
    }

    private static func stopFraction(
        _ value: Double, in domain: ClosedRange<Double>, infiniteFallback: Double
    ) -> Double {
        guard value.isFinite else { return infiniteFallback }
        return min(1, max(0, (value - domain.lowerBound) / (domain.upperBound - domain.lowerBound)))
    }
}

/// The shared Pocket / Insta audio meter over this camera's levels. A source that has not
/// reported yet draws at the floor, as on Pocket.
struct NikonAudioMeter: View {
    let levels: AudioMeterLevels?
    let sensitivity: String?

    var body: some View {
        let floor = AudioMeterBallistics.floorDB
        let label = sensitivity?.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        MonitorAudioMeter(
            left: levels?.left.levelDB ?? floor, leftPeak: levels?.left.peakDB ?? floor,
            right: levels?.right.levelDB ?? floor, rightPeak: levels?.right.peakDB ?? floor,
            sensitivityLabel: label?.isEmpty == false ? label : nil)
    }
}
