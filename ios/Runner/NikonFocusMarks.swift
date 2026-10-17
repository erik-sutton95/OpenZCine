import MonitorPresentation
import MonitorUI
import OpenCineAppKit
import OpenCineCameraControls
import OpenCineCameraVocabulary
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

/// Nikon AF boxes in camera orientation, normalized to the camera's coordinate space (twin of the
/// Android `NikonFocusAreas`).
struct NikonFocusAreas: Equatable {
    let primary: TrackingBox?
    let others: [TrackingBox]
    /// Focus achieved, or the camera is tracking a subject: the shared confirmed colour.
    let confirmed: Bool
}

/// Nil when the camera reports no usable coordinate space (twin of the Android `nikonFocusAreas`).
func nikonFocusAreas(_ focus: PTPLiveViewFocusInfo) -> NikonFocusAreas? {
    guard focus.coordinateWidth > 0, focus.coordinateHeight > 0 else { return nil }
    let width = Double(focus.coordinateWidth)
    let height = Double(focus.coordinateHeight)
    func normalized(_ box: PTPLiveViewAFBox) -> TrackingBox? {
        guard box.width > 0, box.height > 0 else { return nil }
        return TrackingBox(
            x: (Double(box.centerX) - Double(box.width) / 2) / width,
            y: (Double(box.centerY) - Double(box.height) / 2) / height,
            width: Double(box.width) / width, height: Double(box.height) / height)
    }
    return NikonFocusAreas(
        primary: focus.boxes.first.flatMap(normalized),
        others: focus.boxes.dropFirst().compactMap(normalized),
        confirmed: focus.focusResult == .focused || focus.trackingAFActive)
}

/// The camera's AF boxes on the shared focus layer every app draws, over the presented (de-squeezed)
/// picture: the primary box is the focus mark (its size, the focus result colour, the hold-to-lock
/// fill and the lock glyph); further boxes draw as plain confirmed areas.
struct LiveFocusBoxOverlay: View, Equatable {
    let focus: PTPLiveViewFocusInfo
    /// App-only focus-point lock: the shared lock glyph on the AF box.
    var locked: Bool = false
    /// 0 to 1 while long-pressing the AF box to lock it: how much of its outline has drawn in.
    var lockProgress: CGFloat = 0
    /// Whether the picture underneath is flipped left-to-right. The camera's box coordinates never
    /// are, so the shared layer flips them to keep landing on the face they are tracking.
    var mirrored: Bool = false
    /// Top-to-bottom presentation flip; AF metadata stays in source coordinates.
    var mirroredVertically: Bool = false
    /// The de-squeeze the raster below is presenting with; see ``liveFocusBoxRect``.
    var desqueeze = NikonDesqueeze.off

    nonisolated static func == (lhs: LiveFocusBoxOverlay, rhs: LiveFocusBoxOverlay) -> Bool {
        lhs.focus == rhs.focus && lhs.locked == rhs.locked
            && lhs.lockProgress == rhs.lockProgress && lhs.mirrored == rhs.mirrored
            && lhs.mirroredVertically == rhs.mirroredVertically
            && lhs.desqueeze == rhs.desqueeze
    }

    var body: some View {
        GeometryReader { proxy in
            if proxy.size.width > 0, proxy.size.height > 0,
                let areas = nikonFocusAreas(focus)
            {
                MonitorOperatorFocusLayer(
                    palette: LiveDesign.self,
                    focus: areas.primary.map {
                        CGPoint(x: $0.x + $0.width / 2, y: $0.y + $0.height / 2)
                    },
                    mirrored: mirrored, showTapFocusBox: true,
                    flippedVertically: mirroredVertically, focusLocked: locked,
                    focusArea: areas.primary, otherFocusAreas: areas.others,
                    focusConfirmed: areas.confirmed, focusLockProgress: Double(lockProgress),
                    feed: desqueezedRect(CGRect(origin: .zero, size: proxy.size), desqueeze))
            }
        }
        .allowsHitTesting(false)
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
