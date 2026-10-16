import CoreMotion
import MonitorPresentation
import MonitorUI
import OpenCineCameraControls
import OpenCineMedia
import OpenZCineCore
import SwiftUI

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

/// Nikon's saved panel identities adapt to the common drag owner without a resize control.
struct MovablePanel<Content: View>: View {
    @Environment(NativeAppModel.self) private var model
    let id: String
    let size: CGSize
    let defaultCenter: CGPoint
    let bounds: CGRect
    @ViewBuilder var content: () -> Content

    var body: some View {
        let center =
            model.movablePanelCenters[id]
            ?? model.movablePanelPositions[id]?.center(in: bounds) ?? defaultCenter
        let layout = MonitorScopePanelLayout(
            baseSize: size, preferredSize: size,
            center: center, scale: 1, canvas: bounds, movementBounds: bounds, resizable: false)
        MonitorMovableScopePanel(
            layout: layout, enabled: !model.interfaceLocked, onMove: move,
            content: content)
    }

    private func move(_ event: MonitorScopePanelMove) {
        switch event {
        case .began(let center), .changed(let center): model.movablePanelCenters[id] = center
        case .ended:
            if let center = model.movablePanelCenters[id] {
                model.setMovablePanelCenter(id, center, bounds: bounds)
            }
        case .cancelled: model.movablePanelCenters.removeValue(forKey: id)
        }
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
                MonitorOperatorFramingMarks(
                    assist: model.assist, feed: feed,
                    visible: Set(visible.map(\.selection)), guideFallback: model.assist.guideAspect,
                    comparison: LUTResolution.splitComparison(
                        visibleTools: visible,
                        enabled: model.assist.splitComparison, vertical: model.assist.splitVertical,
                        muted: model.splitComparisonMuted
                    ).map {
                        .init(
                            vertical: $0 == .vertical, originalLabel: SplitComparison.logLabel,
                            processedLabel: SplitComparison.lutLabel)
                    })
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
        // Both styles are the shared level owner's; Nikon declares them both.
        MonitorLevelOverlay(
            display: style == .gauge
                ? .gauges(rollDeg: roll, tiltDeg: pitch) : .horizon(rollDeg: roll),
            feed: feed,
            viewport: Self.gaugeViewport(visibleBounds, bottomChrome: bottomChrome),
            portrait: model.monitorIsPortrait)
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
        scale: FalseColorScale, mapping: ExposureSignalMapping, read709: Bool = false
    ) -> MonitorFalseColorReferenceValues {
        let selection: MonitorFalseColorSelection =
            switch scale {
            case .stops: .sceneStops
            case .video: .stops
            case .ire: .ire
            case .limits: .limits
            }
        let curveLabel =
            switch mapping.curve {
            case .redLog3G10: "L3G10"
            case .nikonNLog: "N-Log"
            case .srgb: "sRGB"
            case .hlg: "HLG"
            }
        return MonitorFalseColorReferenceValues(
            subtitle:
                "\(selection.referenceScaleLabel) · \(FalseColorMap.readsThroughLook(mapping: mapping, read709: read709) ? "709" : curveLabel)",
            segments: segments(scale: scale, mapping: mapping, read709: read709).map {
                MonitorFalseColorReferenceSegment(
                    id: $0.id, lowerFraction: $0.lowerFraction, upperFraction: $0.upperFraction,
                    red: $0.band.red, green: $0.band.green, blue: $0.band.blue)
            },
            markers: scale == .stops
                ? stopAxisMarkers(mapping: mapping, read709: read709).map {
                    MonitorFalseColorReferenceMarker(
                        id: $0.id, label: $0.label, fraction: $0.fraction)
                } : [],
            axisLabels: FalseColorAssist.legendLabels(scale: selection))
    }

    static func segments(
        scale: FalseColorScale, mapping: ExposureSignalMapping, read709: Bool = false
    ) -> [Segment] {
        let bands = scale.bands(mapping: mapping, read709: read709)
        let domain = stopReferenceDomain(mapping: mapping, read709: read709)
        return bands.enumerated().map { index, band in
            Segment(
                id: index,
                lowerFraction: scale == .stops
                    ? stopFraction(band.lowerBound, in: domain, infiniteFallback: 0)
                    : min(1, max(0, band.lowerBound / 100)),
                upperFraction: scale == .stops
                    ? stopFraction(band.upperBound, in: domain, infiniteFallback: 1)
                    : band.upperBound.isFinite ? min(1, max(0, band.upperBound / 100)) : 1,
                band: band)
        }
    }

    static func stopAxisMarkers(mapping: ExposureSignalMapping, read709: Bool = false)
        -> [AxisMarker]
    {
        let domain = stopReferenceDomain(mapping: mapping, read709: read709)
        let maximum = FalseColorMap.maximumSceneStop(mapping: mapping, read709: read709)
        let markers: [(String, Double)] = [
            ("Min", FalseColorMap.minimumSceneStop), ("−2", -2), ("−1", -1),
            ("18%", 0), ("+1", 1), ("+2", 2), ("Clip", maximum),
        ]
        return markers.enumerated().map { index, marker in
            AxisMarker(
                id: index, label: marker.0,
                fraction: stopFraction(marker.1, in: domain, infiniteFallback: 0))
        }
    }

    private static func stopReferenceDomain(
        mapping: ExposureSignalMapping, read709: Bool
    ) -> ClosedRange<Double> {
        let lower = FalseColorMap.minimumSceneStop - 0.5
        let upper = max(6, FalseColorMap.maximumSceneStop(mapping: mapping, read709: read709) + 0.5)
        return lower...upper
    }

    private static func stopFraction(
        _ value: Double, in domain: ClosedRange<Double>, infiniteFallback: Double
    ) -> Double {
        guard value.isFinite else { return infiniteFallback }
        return min(1, max(0, (value - domain.lowerBound) / (domain.upperBound - domain.lowerBound)))
    }
}
