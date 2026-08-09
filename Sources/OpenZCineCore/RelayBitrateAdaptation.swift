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

/// The skip-don't-queue rule applied to a STAGE of the broadcaster's own pipeline rather than to
/// a viewer's link: how many frames may be inside the stage before new ones are dropped.
///
/// The per-viewer window (`RelayEncoderProfile.maxInFlightFramesPerPeer`) bounds the network, and
/// while the network is the slow part that is the only bound needed. But the broadcaster's encode
/// is a stage too, and it can become the slow part on its own: an iOS screen recording takes its
/// share of the same hardware encoder, so the encode drops below the source rate while every
/// viewer link still reports clear. Handing that stage a frame it has no capacity for is the same
/// mistake in a different place — the frames are kept, latency accumulates by seconds, and the
/// picture snaps back to live only when the contention ends and the backlog drains at full speed.
///
/// A skipped ENCODE costs no keyframe. The reference chain runs over the frames the encoder
/// actually saw, so a frame never handed to it leaves no gap: the next encoded frame still
/// predicts from the last one every viewer already has. (A skipped SEND is the opposite — the
/// viewer is missing a link it needs, which is why the link layer latches `needsKeyframe`.)
public struct RelayEncodeLane: Equatable, Sendable {
    /// Frames inside the stage before the next is dropped.
    ///
    /// Two, matching the link layer's low-latency window, for the same reason: one being worked
    /// on and one behind it. A depth of one would idle the stage between arrivals, so any encode
    /// running a hair longer than the frame interval would alias the stream to half the source
    /// rate instead of the ~90% the hardware can still deliver. Two bounds the added latency at
    /// one frame's work — tens of milliseconds — instead of the unbounded seconds this exists
    /// to prevent.
    public static let defaultDepth = 2

    public let depth: Int
    public private(set) var framesInFlight = 0

    public init(depth: Int = RelayEncodeLane.defaultDepth) {
        self.depth = max(1, depth)
    }

    /// Claims the lane for one frame. `false` means SKIP this frame: the stage has not drained,
    /// and a monitor shows the newest frame or it is not a monitor.
    public mutating func admit() -> Bool {
        guard framesInFlight < depth else { return false }
        framesInFlight += 1
        return true
    }

    /// Gives the lane back when the stage finishes. Floored at zero so a stray completion — a
    /// broadcast stopped mid-frame, an encoder swapped under a live session — cannot lend the
    /// lane depth it does not have and quietly reopen the unbounded path.
    public mutating func release() { framesInFlight = max(0, framesInFlight - 1) }
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
