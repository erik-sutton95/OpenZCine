import Foundation

/// Decides when a live-view stall is the BODY being busy rather than the link being dead.
///
/// Opening the camera's own menu stops fresh live-view frames — Nikon serves the last cached
/// frame — which reads to the watchdog exactly like the wedged-body replay of #283. The
/// difference that matters: restarting live view (`StartLiveView`) forces the body back to its
/// shooting screen, so the recovery loop's restarts were what kept slamming the operator's
/// menu shut, every few seconds, on every transport (#297).
///
/// The discriminator available without new camera knowledge: a replaying body whose COMMAND
/// channel still answers is doing something — a menu, playback, image review — and deserves
/// patience; the hold pulls slowly and resumes the moment payloads change (leaving the menu
/// resumes the still-active stream by itself). The hold is bounded so the genuine wedge of
/// #283 still self-heals — just after minutes instead of seconds, which a wedged body does
/// not mind and an operator in a menu very much does.
public enum BodyBusyHoldPolicy {
    /// Whether a stall should hold instead of restarting.
    public static func shouldHold(isRepeatingLastFrame: Bool, commandChannelAnswers: Bool) -> Bool {
        isRepeatingLastFrame && commandChannelAnswers
    }

    /// How long the body may stay busy before the stall escalates to the restart path.
    /// Long enough for a real menu session; short enough that a wedged body (#283) still
    /// recovers unattended. [verify-on-HW] against real menu dwell times.
    public static let maxHoldSeconds: TimeInterval = 180

    /// Frame-pull cadence while holding — enough to notice the stream coming back within a
    /// beat, light enough to stop hammering a body that is busy elsewhere.
    public static let holdPullIntervalSeconds: TimeInterval = 2
}
