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
/// ## Overlays come along for free, and that is the point
///
/// Peaking, guides, the grid and the AF boxes are all registered to the feed rect. Scaling that
/// rect carries them with it, so a magnified view shows peaking on the magnified pixels rather
/// than a stale overlay floating over a zoomed image — which is the only way a punch-in is useful
/// for judging focus at all.
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
