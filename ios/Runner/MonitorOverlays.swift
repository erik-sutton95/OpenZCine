import CoreMotion
import MonitorPresentation
import MonitorUI
import OpenCineMedia
import OpenZCineCore
import SwiftUI

struct FeedAssistOverlayModule: View {
    @Environment(NativeAppModel.self) private var model
    let viewportWidth: Double
    /// The shared layout's picture rect, in this module's (viewport) space.
    let picture: CGRect
    /// Suppresses the floating scope/false-colour `MovablePanel`s. Set by `MonitorShell`'s
    /// portrait branch: those panels bleed over the narrow portrait feed strip and are redundant
    /// there — `PortraitScopesStack` already shows scopes. Landscape never passes this.
    var suppressFloatingScopes: Bool = false

    var body: some View {
        // Photography filters the cinema-only panels (a flipped-over video scope must not
        // ride into the photo chrome); the persisted set itself is untouched.
        let visible = model.renderedLiveAssistTools
        GeometryReader { proxy in
            let screenBounds = CGRect(
                x: 0, y: 0, width: CGFloat(viewportWidth), height: proxy.size.height)
            // Bands the inside-fallback anchors must clear: the status pill on top, the floating
            // assist/capture strips on the bottom (reserved in every mode — see
            // `landscapeBottomBarHeight` in MonitorUnified.swift).
            let chromeClearance = EdgeInsets(
                top: CGFloat(
                    MonitorEdgeInsets.chrome(for: .zero).clearingWindowControls.top
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
                                picture, size, .bottomTrailing,
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
    var audioLevels: MonitorAudioMeterLevels?
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

/// Long-press-and-drag wrapper for a floating panel (a scope or the false-colour reference). After a
/// brief hold the panel lifts and follows the finger, clamped inside `bounds` and snapped to a coarse
/// grid; a rigid tap fires on pick-up and a light tick on each snap, in keeping with the assist
/// haptics. Positions persist across launches via `model.movablePanelPositions`.
struct MovablePanel<Content: View>: View {
    @Environment(NativeAppModel.self) private var model
    let id: String
    let size: CGSize
    let defaultCenter: CGPoint
    let bounds: CGRect
    @ViewBuilder var content: () -> Content

    @State private var dragOrigin: CGPoint?
    @State private var isDragging = false
    @State private var snapCell = 0

    // A fine position snap keeps the drag feeling smooth; the haptic ticks on a coarser interval so
    // it doesn't buzz continuously while moving.
    private let positionGrid: CGFloat = 4
    private let hapticGrid: CGFloat = 22
    /// Invisible padding around the panel body for long-press drag pickup.
    private let dragHitPadding: CGFloat = 10

    var body: some View {
        let center = clamp(resolvedCenter())
        content()
            .frame(width: size.width, height: size.height, alignment: .topLeading)
            .padding(dragHitPadding)
            .contentShape(Rectangle())
            .padding(-dragHitPadding)
            .gesture(panelDragGesture(center: center))
            .scaleEffect(isDragging ? 1.03 : 1)
            .shadow(color: .black.opacity(isDragging ? 0.5 : 0), radius: 18, y: 8)
            .position(x: center.x, y: center.y)
            .sensoryFeedback(trigger: isDragging) { _, dragging in
                dragging ? .impact(flexibility: .rigid, intensity: 1) : nil
            }
            .sensoryFeedback(.selection, trigger: snapCell)
            .animation(.easeOut(duration: 0.14), value: isDragging)
    }

    /// Long-press then drag on the panel body to reposition.
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
                MonitorLevelOverlay(
                    display: .gauges(rollDeg: roll, tiltDeg: pitch), feed: feed,
                    viewport: Self.gaugeViewport(visibleBounds, bottomChrome: bottomChrome),
                    portrait: model.monitorIsPortrait)
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

    /// Where the shared gauge seats: the on-screen feed area less any strip overlaying its
    /// bottom edge (portrait fill's capture bar). The gauge is a HUD instrument, so unlike the
    /// framing aids it never lands in content clipped off screen.
    static func gaugeViewport(_ visibleBounds: CGRect, bottomChrome: CGFloat) -> CGRect {
        CGRect(
            x: visibleBounds.minX, y: visibleBounds.minY, width: visibleBounds.width,
            height: max(0, visibleBounds.height - bottomChrome))
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
    let levels: MonitorAudioMeterLevels?
    let sensitivity: String?

    var body: some View {
        let floor = MonitorAudioMeterBallistics.floorDB
        let label = sensitivity?.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        MonitorAudioMeter(
            left: levels?.left.levelDB ?? floor, leftPeak: levels?.left.peakDB ?? floor,
            right: levels?.right.levelDB ?? floor, rightPeak: levels?.right.peakDB ?? floor,
            sensitivityLabel: label?.isEmpty == false ? label : nil)
    }
}
