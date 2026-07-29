import Foundation

/// Live-view punch-in for checking critical focus.
///
/// The whole feature is one number applied at one point in the pipeline, and the reason it needs a
/// file of its own is WHERE that point is.
///
/// ## It is the last transform, and that is not arbitrary
///
/// Magnification composes with de-squeeze, Fit/Fill, orientation and the LUT, and the ordering is
/// forced rather than chosen. De-squeeze changes the image's SHAPE, so it has to settle before
/// anything decides how big to draw it; Fit/Fill then decides the framing. Punch-in scales that
/// settled result about its centre — so it magnifies exactly what the operator was looking at, and
/// punching back out lands on the identical framing rather than a re-derived one.
///
/// Applying it earlier would make the punch-in interact with the fit: a 2× punch on a de-squeezed
/// frame would re-fit to a different rectangle and the image would jump sideways as it zoomed.
///
/// ## It wraps the overlays, not just the raster
///
/// The transform belongs on the whole feed stack — raster AND the AF box, focus ring and guides
/// drawn over it. Applied to the raster alone the overlays stay at their unmagnified positions
/// while the picture grows under them, so the box the operator is using to judge focus no longer
/// sits on the thing it is measuring. (Peaking is baked into the frame upstream, so it travels
/// either way; the geometry overlays do not.)
///
/// This is a MONITORING transform. It never changes the camera's crop mode, resolution, recorded
/// image, or camera-side digital zoom.
public enum Magnification {

    /// The scale to apply to the settled feed rect, about its centre.
    ///
    /// Exactly 1 when inactive, so the shells can apply this unconditionally and punching out
    /// lands on a framing that is identical to never having punched in — not a re-derived one.
    /// That identity is what stops repeated toggling from accumulating drift.
    ///
    /// Scalars rather than a rect: this is shared with Android through Kotlin, which has no
    /// CGRect, and each shell already owns its own geometry type.
    public static func scale(factor: Double, isActive: Bool) -> Double {
        guard isActive, factor.isFinite, factor > 1 else { return 1 }
        return factor
    }

    /// Which AF box the punch-in follows: the subject the body selected, else the AF area (box 0).
    ///
    /// Shared so both shells aim at the same box. With subject detection on, the selected box is
    /// the face or eye actually being focused — the AF area rectangle around it is the wrong
    /// target at 4×, where the difference between "the face" and "the eye" is the whole question.
    public static func anchorBoxIndex(boxCount: Int, selectedBoxIndex: Int?) -> Int? {
        guard boxCount > 0 else { return nil }
        guard let selectedBoxIndex, selectedBoxIndex >= 0, selectedBoxIndex < boxCount else {
            return 0
        }
        return selectedBoxIndex
    }

    /// The punch-in's fixed point, in unit coordinates of the feed rect.
    ///
    /// The camera's own focus box, not the middle of the frame. A centred punch-in is close to
    /// useless for the job this tool exists to do: focus is rarely in the middle of the shot, so
    /// centring magnifies whatever happens to be there instead of the thing being focused.
    ///
    /// It is the FIXED POINT of the scale, not a point that gets moved to the middle. The box
    /// stays exactly where it is drawn and the picture grows outward around it, which is what
    /// makes the result always in bounds: a fixed point inside the unit square keeps the visible
    /// window inside it at every factor, so there is no clamping and no different behaviour near
    /// an edge. Recentring instead would need both, and could not deliver at the edges anyway.
    ///
    /// Recomputed per frame rather than latched at punch-in, so moving the focus point — by tap or
    /// on the body — takes the magnified view with it.
    ///
    /// `[verify-on-HW]` With subject detection driving the box, this follows the detection frame
    /// by frame; if that reads as swimming at 4× on real hardware the fix is hysteresis here, not
    /// a change of anchor.
    public static func anchor(
        boxCenterX: Int?,
        boxCenterY: Int?,
        coordinateWidth: Int,
        coordinateHeight: Int
    ) -> (x: Double, y: Double) {
        let centre = (x: 0.5, y: 0.5)
        guard let boxCenterX, let boxCenterY, coordinateWidth > 0, coordinateHeight > 0
        else { return centre }
        let x = Double(boxCenterX) / Double(coordinateWidth)
        let y = Double(boxCenterY) / Double(coordinateHeight)
        guard x.isFinite, y.isFinite else { return centre }
        return (x: min(max(x, 0), 1), y: min(max(y, 0), 1))
    }

    /// Whether the quick-access button belongs on screen: the tool is on, and live view is the
    /// thing being shown. Disabling the tool takes the button with it.
    public static func showsButton(toolEnabled: Bool) -> Bool { toolEnabled }

    /// The punched-in state after the tool is switched off.
    ///
    /// Always false. Leaving a punch-in armed behind a disabled tool is how the button and the
    /// transform desynchronise — the operator would have a magnified feed and no visible control
    /// that explains it.
    public static func activeAfterDisabling() -> Bool { false }

    /// Accessibility/label text for the quick-access button.
    public static func buttonLabel(factor: AssistConfiguration.Magnification.Factor, isActive: Bool)
        -> String
    {
        isActive ? "Exit \(factor.rawValue) magnification" : "Magnify \(factor.rawValue)"
    }
}
