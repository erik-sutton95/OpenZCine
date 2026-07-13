import Foundation

/// Detects live-view stalls and triggers recovery.
///
/// A live-view stream over WiFi is expected to drop the occasional frame. This watchdog
/// distinguishes normal jitter from an actual stall using two signals: time since the last
/// good frame, and a streak of consecutive bad (unparsable) frames. When either crosses its
/// threshold, the watchdog declares `.stalled` so the host can restart the session.
///
/// Pure value type — timestamps are abstract `Date` values so the watchdog is fully testable
/// without a live camera.
public struct LiveViewWatchdog: Sendable {
    /// Current health status of the live-view stream.
    public enum Status: Equatable, Sendable {
        /// Good frames are arriving within the timeout.
        case streaming
        /// No good frame within the stall timeout, or the bad-frame streak was exceeded. The
        /// host should restart the live-view session.
        case stalled
    }

    private let stallTimeoutSeconds: TimeInterval
    private let maxConsecutiveBadFrames: Int

    /// Timestamp of the last good frame received.
    private(set) public var lastGoodFrameAt: Date
    /// Current streak of consecutive bad (unparsable) frames.
    private(set) public var consecutiveBadFrames: Int = 0

    /// Stall thresholds: max seconds between good frames, and max consecutive unparsable frames.
    public init(
        stallTimeoutSeconds: TimeInterval = 6,
        maxConsecutiveBadFrames: Int = 12
    ) {
        self.stallTimeoutSeconds = stallTimeoutSeconds
        self.maxConsecutiveBadFrames = maxConsecutiveBadFrames
        lastGoodFrameAt = Date()
    }

    /// Current status. Call `check(at:)` to refresh the stall-timeout evaluation.
    public private(set) var status: Status = .streaming

    /// Records a successfully decoded frame. Resets the bad-frame streak and the stall deadline.
    public mutating func recordGoodFrame(at timestamp: Date) {
        lastGoodFrameAt = timestamp
        consecutiveBadFrames = 0
        status = .streaming
    }

    /// Records a frame that arrived but could not be decoded. Increments the bad-frame streak
    /// and declares `.stalled` once the threshold is exceeded.
    public mutating func recordBadFrame() {
        consecutiveBadFrames += 1
        if consecutiveBadFrames >= maxConsecutiveBadFrames {
            status = .stalled
        }
    }

    /// Evaluates the stall timeout against the given timestamp. Call periodically (e.g. each
    /// loop iteration) so a quiet stream is detected even when no frames arrive at all.
    public mutating func check(at now: Date) {
        guard status != .stalled else { return }
        if now.timeIntervalSince(lastGoodFrameAt) >= stallTimeoutSeconds {
            status = .stalled
        }
    }

    /// Resets all counters for a fresh streaming attempt.
    public mutating func prepareForRestart() {
        consecutiveBadFrames = 0
        lastGoodFrameAt = Date()
        status = .streaming
    }
}
