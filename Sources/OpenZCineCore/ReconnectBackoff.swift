import Foundation

/// Jittered exponential backoff schedule for reconnect / live-view-restart retries.
///
/// Plain doubling makes every client (and every retry within one client) wake at the same instants,
/// so a flaky access point gets hit by synchronized reconnect bursts. Spreading each delay by a
/// random fraction de-correlates the attempts — the standard mitigation for reconnect storms.
///
/// The jitter sample is injected (`0...1`) rather than drawn internally so the schedule is pure and
/// unit-testable: pass `Double.random(in: 0...1)` at the call site, or `0.5` for the midpoint.
public struct ReconnectBackoff: Sendable, Equatable {
    /// Delay used for the very first retry (attempt 0), before any exponential growth.
    public var baseSeconds: Double
    /// Hard ceiling on the returned delay, applied before and after jitter.
    public var maxSeconds: Double
    /// Per-attempt growth factor (2 = double each attempt).
    public var multiplier: Double
    /// Proportional spread applied to each delay, in `0...1` (0.3 = ±30%).
    public var jitterFraction: Double

    public init(
        baseSeconds: Double = 0.5,
        maxSeconds: Double = 30,
        multiplier: Double = 2,
        jitterFraction: Double = 0.3
    ) {
        self.baseSeconds = baseSeconds
        self.maxSeconds = maxSeconds
        self.multiplier = multiplier
        self.jitterFraction = jitterFraction
    }

    /// The delay (seconds) to wait before retry `attempt` (0 = first retry, growing from there).
    ///
    /// - Parameters:
    ///   - attempt: zero-based retry index; negatives are treated as 0.
    ///   - jitter: a sample in `0...1` (clamped); 0 = lower bound, 0.5 = un-jittered, 1 = upper bound.
    public func delaySeconds(forAttempt attempt: Int, jitter: Double) -> Double {
        let exponent = Double(max(0, attempt))
        let capped = min(maxSeconds, baseSeconds * pow(multiplier, exponent))
        let clampedJitter = min(1, max(0, jitter))
        // Map the 0...1 sample onto ±jitterFraction around the un-jittered delay.
        let signedSpread = (clampedJitter * 2 - 1) * jitterFraction
        let jittered = capped * (1 + signedSpread)
        return min(maxSeconds, max(0, jittered))
    }
}
