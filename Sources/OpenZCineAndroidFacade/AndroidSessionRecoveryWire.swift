import Foundation
import OpenZCineCore

/// Serializes the Android monitor's reconnect decisions through the shared
/// ``SessionRecoveryPolicy`` so Kotlin never owns a second copy of the retry
/// schedule or the give-up point.
///
/// The wire is deliberately one scalar in each direction: a reconnect decision
/// is taken at most once per attempt (seconds apart), so the JNI hop costs
/// nothing measurable and buys one source of truth across both shells.
public enum AndroidSessionRecoveryWire {
    /// Sentinel for "stop retrying and hand the decision back to the operator".
    /// A real delay is always `>= 0`, so a negative value is unambiguous.
    public static let stopSentinel: Int64 = -1

    /// Milliseconds to wait before the next reconnect attempt, or
    /// ``stopSentinel`` once the automatic budget is spent.
    ///
    /// - Parameters:
    ///   - failures: consecutive failed attempts so far; `0` is a fresh drop.
    ///   - jitter: a sample in `0...1`; the caller draws it so the schedule
    ///     stays pure and testable.
    public static func retryDelayMilliseconds(failures: Int, jitter: Double) -> Int64 {
        switch SessionRecoveryPolicy.monitor.decision(afterFailedAttempts: failures, jitter: jitter)
        {
        case .stop:
            return stopSentinel
        case .retry(let seconds):
            return Int64((seconds * 1000).rounded())
        }
    }

    /// How many automatic attempts the shared policy allows, so the Compose
    /// affordance can show a truthful "attempt N of M".
    public static var maximumAutomaticAttempts: Int {
        SessionRecoveryPolicy.monitor.maxAutomaticAttempts
    }
}
