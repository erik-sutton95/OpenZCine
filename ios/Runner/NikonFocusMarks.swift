import MonitorPresentation
import MonitorUI
import OpenCineAppKit
import OpenCineCameraControls
import OpenCineCore
import OpenZCineCore
import SwiftUI

/// One AF / subject box mapped from the live-view header's coordinate space onto the PRESENTED
/// picture inside `size`.
///
/// Presented, not the whole frame: the raster carries the de-squeeze as a centred `scaleEffect`
/// (`LiveFrameRaster.feedScale`), so an anamorphic setup paints the image into a narrower (or
/// shorter) sub-rect of the same frame. Mapping into the frame left the box drifting sideways off
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

/// The camera's AF and subject-detection boxes (from the live-view header) as the shared focus
/// marks every app draws: box 0, the AF area, is the focus mark at the size the camera declares,
/// styled by AF state (see `primaryBoxColor`); detected face and eye boxes (box 1 and up) are the
/// shared tracking brackets in green.
struct LiveFocusBoxOverlay: View, Equatable {
    let focus: PTPLiveViewFocusInfo
    /// App-only focus-point lock: tints the AF box accent and badges it with the shared lock.
    var locked: Bool = false
    /// 0 to 1 while long-pressing the AF box to lock it: how much of its outline has drawn in.
    var lockProgress: CGFloat = 0
    /// Whether the picture underneath is flipped left-to-right. The camera's box coordinates never
    /// are, so the boxes have to be flipped here to keep landing on the face they are tracking.
    var mirrored: Bool = false
    /// Top-to-bottom presentation flip; AF metadata stays in source coordinates.
    var mirroredVertically: Bool = false
    /// The de-squeeze the raster below is presenting with; see ``liveFocusBoxRect``.
    var desqueeze = NikonDesqueeze.off

    nonisolated static func == (lhs: LiveFocusBoxOverlay, rhs: LiveFocusBoxOverlay) -> Bool {
        // `focusResult` / `trackingAFActive` (drawing state via `primaryBoxColor`) are stored
        // properties of `focus`, so its memberwise == already covers them.
        lhs.focus == rhs.focus && lhs.locked == rhs.locked
            && lhs.lockProgress == rhs.lockProgress && lhs.mirrored == rhs.mirrored
            && lhs.mirroredVertically == rhs.mirroredVertically
            && lhs.desqueeze == rhs.desqueeze
    }

    /// Idle AF-box white opacity: slightly transparent so acquired/tracking green reads as a
    /// state change.
    private static let idleWhiteOpacity = 0.72

    /// Box 0 (AF area) state to colour, Nikon-body-like, in precedence order:
    /// 1. `locked` (app-side focus-point lock): accent at full opacity, plus the lock badge.
    /// 2. AF acquired (`focusResult == .focused`) or subject tracking engaged
    ///    (`trackingAFActive`, the header's tracking-AF status byte): green at full opacity.
    /// 3. Idle / hunting (`.unknown` / `.notFocused`): dim white; no distinct red state.
    private var primaryBoxColor: Color {
        if locked { return LiveDesign.accent }
        if focus.focusResult == .focused || focus.trackingAFActive { return .green }
        return .white.opacity(Self.idleWhiteOpacity)
    }

    var body: some View {
        GeometryReader { proxy in
            let marks = Self.marks(
                focus, in: proxy.size, desqueeze: desqueeze, mirrored: mirrored,
                mirroredVertically: mirroredVertically)
            MonitorTrackingLayer(
                brackets: marks.subjects.map {
                    MonitorTrackingBracketValue(normalizedRect: $0, color: .green, lineWidth: 1.5)
                },
                focus: marks.area.map {
                    MonitorFocusMark(
                        point: CGPoint(x: $0.midX, y: $0.midY), size: $0.size,
                        color: primaryBoxColor, focusLocked: locked,
                        lockProgress: Double(lockProgress))
                },
                feed: CGRect(origin: .zero, size: proxy.size))
        }
        .allowsHitTesting(false)
    }

    /// The boxes in normalized picture coordinates through ``liveFocusBoxRect``: the AF area
    /// (box 0) and the detected subjects after it.
    nonisolated static func marks(
        _ focus: PTPLiveViewFocusInfo, in size: CGSize, desqueeze: NikonDesqueeze,
        mirrored: Bool, mirroredVertically: Bool
    ) -> (area: CGRect?, subjects: [CGRect]) {
        guard size.width > 0, size.height > 0 else { return (nil, []) }
        let rects = focus.boxes.map { box in
            liveFocusBoxRect(
                box, focus: focus, in: size, desqueeze: desqueeze, mirrored: mirrored,
                mirroredVertically: mirroredVertically
            ).map {
                CGRect(
                    x: $0.minX / size.width, y: $0.minY / size.height,
                    width: $0.width / size.width, height: $0.height / size.height)
            }
        }
        return (rects.first ?? nil, rects.dropFirst().compactMap { $0 })
    }
}

/// AF / subject-detection boxes, isolated from per-frame feed publishes.
struct LiveFeedFocusOverlay: View {
    @Environment(NativeAppModel.self) private var model
    let lockProgress: CGFloat

    var body: some View {
        // The AF box is an element like any other: on by default in DISP 1 and DISP 2 (focus
        // feedback the operator relies on even in the stripped-back view), and hideable in both.
        // (Command never mounts the feed, so no mode guard is needed.)
        if model.chromeSectionMounts(.focusBox), let focus = model.liveViewFocus,
            !focus.boxes.isEmpty
        {
            // Focus metadata repeats identically on most frames: the Equatable guard skips the
            // redraw unless a box, lock or progress changed.
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
            // below), while the shared layer draws the marks.
            .opacity(focusBoxEditDimmed ? 0.3 : 1)
            // The badge goes on the primary AF box, not the whole feed: a dashed outline round
            // the entire image would name nothing.
            .overlay { focusBoxEditTarget(focus) }
        }
    }

    /// The AF box is force-mounted while editing a mode that has it switched off: dim it so the
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
