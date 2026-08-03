/// Congestion-adaptive live-view degradation.
///
/// The frame fetch runs under a hard deadline whose breach closes the command channel — with a
/// static quality setting, a congested link turns slow frames into disconnections ("constant
/// dropouts" on a weak router). This policy watches inter-frame intervals and steps the
/// requested `LiveViewImageSize` DOWN while frames drift toward the deadline, then back UP after
/// sustained health. The operator's stream preset is the ceiling: adaptation only ever degrades
/// below it, and recovers to it. Compression is deliberately untouched — size-priority
/// compression is known to block badly on hardware.
public struct LiveViewAdaptiveQuality: Sendable, Equatable {
    public enum Verdict: String, Equatable, Sendable {
        case hold
        case stepDown
        case stepUp
    }

    /// EWMA of inter-frame intervals, seconds. Exposed for tests and diagnostics.
    public private(set) var intervalEWMA: Double = 0
    private var lastStepAt: Double?
    private var healthySince: Double?

    public init() {}

    /// Smoothing factor: tracks a real shift within a few frames, absorbs one-frame jitter.
    private static let alpha = 0.3
    /// EWMA above this (≈ under 2.2 fps) is sustained congestion → step down.
    private static let congestedIntervalSeconds = 0.45
    /// A single interval above this is a spike the EWMA would under-react to → step down now.
    private static let spikeIntervalSeconds = 2.5
    /// EWMA below this (≈ above 6.5 fps) counts toward recovery.
    private static let healthyIntervalSeconds = 0.15
    /// Continuous health required before stepping back up.
    private static let stepUpAfterHealthySeconds = 45.0
    /// Minimum spacing between steps in either direction — a step restarts the stream, which
    /// itself costs a second-plus, so thrashing would be worse than either tier.
    private static let stepCooldownSeconds = 8.0

    /// Feeds one frame arrival. `now` is any monotonic seconds timeline (the caller supplies it
    /// so the policy stays pure and testable).
    public mutating func recordFrame(intervalSeconds: Double, now: Double) -> Verdict {
        intervalEWMA =
            intervalEWMA <= 0
            ? intervalSeconds
            : intervalEWMA + Self.alpha * (intervalSeconds - intervalEWMA)

        if intervalEWMA <= Self.healthyIntervalSeconds {
            if healthySince == nil { healthySince = now }
        } else {
            healthySince = nil
        }

        if let last = lastStepAt, now - last < Self.stepCooldownSeconds { return .hold }

        if intervalSeconds >= Self.spikeIntervalSeconds
            || intervalEWMA >= Self.congestedIntervalSeconds
        {
            lastStepAt = now
            healthySince = nil
            return .stepDown
        }
        if let healthySince, now - healthySince >= Self.stepUpAfterHealthySeconds {
            lastStepAt = now
            // The streak restarts toward the next rung rather than cascading straight to the top.
            self.healthySince = now
            return .stepUp
        }
        return .hold
    }

    /// A stream restart (any cause) invalidates the health streak; the EWMA keeps its link
    /// knowledge — α converges it within a few frames of the new tier anyway.
    public mutating func noteStreamRestart() {
        healthySince = nil
    }
}
