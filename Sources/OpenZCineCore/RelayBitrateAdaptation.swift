import Foundation

/// The broadcaster's latency-vs-quality stance, chosen by the operator in Sharing settings.
///
/// Both profiles keep the adaptive bitrate ladder and the skip-don't-queue delivery rule; the
/// profile only moves the knobs where a little latency genuinely buys picture:
/// - a longer keyframe interval spends fewer bits on keyframes (each is 3–8× a predicted frame),
///   which the rate controller reinvests in every other frame;
/// - a deeper per-viewer in-flight window rides out link jitter instead of skipping, and every
///   skip avoided is a broken reference chain and a forced keyframe avoided.
///
/// B-frames were considered and REJECTED for both profiles: reordering would break the
/// skip-and-resume architecture (frames must be droppable per-viewer without corrupting the
/// chain for others) and would need decode-side timestamp reordering the monitor's
/// newest-frame-wins contract has no use for.
public enum RelayEncoderProfile: String, CaseIterable, Codable, Equatable, Sendable {
    /// Tightest glass-to-glass path — today's defaults. The right stance for pulling focus.
    case lowLatency
    /// Trades roughly four frames of latency (~130 ms at 30 fps) for steadier quality.
    case quality

    public var title: String {
        switch self {
        case .lowLatency: "Low latency"
        case .quality: "Quality"
        }
    }

    /// Upper bound on the encoder's own keyframe cadence. Forced keyframes (joins, resumes)
    /// are unaffected — a joiner never waits longer in either profile.
    public var maxKeyframeInterval: Int {
        switch self {
        case .lowLatency: 50
        case .quality: 120
        }
    }

    /// Frames a viewer may have queued-but-undrained before new ones are skipped.
    public var maxInFlightFramesPerPeer: Int {
        switch self {
        case .lowLatency: 2
        case .quality: 4
        }
    }
}

/// Where "the camera feed is starving" begins, given what this session's feed does when the
/// relay is NOT competing with it.
///
/// A fixed floor alone sets the equilibrium in the wrong place: the ladder stops helping the
/// moment the feed clears the floor, so a 35 fps session pins at 20-something while the relay
/// keeps the rest of the channel. Anchoring the threshold to the session's own unloaded
/// baseline makes the ladder keep stepping until the operator's monitor gets its rate back.
/// The absolute floor remains for sessions with no measured baseline yet.
public enum RelayCameraStarvePolicy {
    /// Below any healthy live-view cadence, above a suffocated one.
    public static let absoluteFloorFPS: Double = 15
    /// Fraction of the unloaded baseline under which the relay counts as the cause.
    public static let baselineFraction: Double = 0.72

    public static func starveThresholdFPS(soloBaselineFPS: Double) -> Double {
        guard soloBaselineFPS > 0 else { return absoluteFloorFPS }
        return max(absoluteFloorFPS, soloBaselineFPS * baselineFraction)
    }
}

/// Steps the relay's video bitrate against observed congestion.
///
/// The broadcaster serves every viewer from ONE encode, so the stream must fit the slowest link
/// that is supposed to keep up. Two observations feed the signal, and both matter:
/// - a tick where no viewer could accept a frame (the encode was skipped) — though TCP buffering
///   makes this LAGGY on an infrastructure path: send completions fire when the kernel accepts
///   the bytes, so a drowning router can look clear from the send side;
/// - the broadcaster's OWN camera feed starving. The camera downlink and the relay uplink share
///   one radio, so the first honest casualty of an oversized stream is the broadcaster's
///   monitor. A relay that looks gorgeous on the watchers while the operator drops to 5 fps has
///   the priorities exactly backwards.
///
/// Recovery is deliberately slower than degradation — a set network that just choked once will
/// choke again, and oscillating bitrate reads worse on a monitor than a steady, slightly softer
/// picture.
public struct RelayBitrateAdaptation: Equatable, Sendable {
    /// Bits per second, best first. The relay carries LOG footage that every watcher grades
    /// through a LUT — quantization noise invisible in the flat image gets contrast-stretched
    /// into blotching, so the ladder is deliberately generous for the content, not the pixel
    /// count. The floor keeps a usable picture on a genuinely bad channel rather than none.
    public static let ladder = [10_000_000, 7_000_000, 4_500_000, 3_000_000]
    /// Worst permitted frame QP per rung, same order as `ladder`. At the top the cap is strict —
    /// full budget, no excuse for mush. Descending rungs RELAX it: log grain at a strict cap can
    /// cost more bits than the low targets allow, and a cap the rate controller cannot honor
    /// turns a step-down into a no-op right when shrinking the stream is the whole point.
    public static let maxFrameQPLadder = [36, 39, 42, 45]

    /// Fraction of saturated ticks in a window that forces a step DOWN.
    public static let stepDownSaturation = 0.3
    /// Saturation must stay below this for `stepUpAfterCleanSeconds` before a step UP.
    public static let stepUpSaturation = 0.05
    /// Window over which saturation is judged.
    public static let windowSeconds: TimeInterval = 5
    /// Clean time required before recovering one rung.
    public static let stepUpAfterCleanSeconds: TimeInterval = 30

    /// Index into `ladder` for the current rate.
    public private(set) var rungIndex = 0
    public var bitsPerSecond: Int { Self.ladder[rungIndex] }
    public var maxFrameQP: Int { Self.maxFrameQPLadder[rungIndex] }

    private var windowStartedAt: TimeInterval
    private var ticksInWindow = 0
    private var saturatedTicksInWindow = 0
    private var previousTickSaturated = false
    private var cleanSince: TimeInterval

    public init(now: TimeInterval = 0) {
        windowStartedAt = now
        cleanSince = now
    }

    /// Records one broadcast tick. Returns the new bitrate when the rung changed, else nil.
    ///
    /// A single saturated tick is PACING, not congestion: with a two-frame in-flight cap at
    /// stream rate, every viewer is momentarily "full" all the time. Only consecutive
    /// saturated ticks — the stream outrunning the drain for real — count toward stepping
    /// down; counting the blips is what walked multi-watcher sessions to the floor and kept
    /// them there.
    public mutating func recordTick(saturated: Bool, now: TimeInterval) -> Int? {
        ticksInWindow += 1
        if saturated && previousTickSaturated { saturatedTicksInWindow += 1 }
        previousTickSaturated = saturated
        guard now - windowStartedAt >= Self.windowSeconds, ticksInWindow > 0 else { return nil }

        let saturation = Double(saturatedTicksInWindow) / Double(ticksInWindow)
        ticksInWindow = 0
        saturatedTicksInWindow = 0
        windowStartedAt = now

        if saturation > Self.stepDownSaturation {
            cleanSince = now
            if rungIndex < Self.ladder.count - 1 {
                rungIndex += 1
                return bitsPerSecond
            }
            return nil
        }
        if saturation > Self.stepUpSaturation {
            // Not bad enough to drop, not clean enough to climb — the clean clock restarts.
            cleanSince = now
            return nil
        }
        if rungIndex > 0, now - cleanSince >= Self.stepUpAfterCleanSeconds {
            rungIndex -= 1
            cleanSince = now
            return bitsPerSecond
        }
        return nil
    }
}
