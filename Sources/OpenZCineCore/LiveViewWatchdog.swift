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
    private let repeatedFrameTimeoutSeconds: TimeInterval

    /// Timestamp of the last good frame received.
    private(set) public var lastGoodFrameAt: Date
    /// Current streak of consecutive bad (unparsable) frames.
    private(set) public var consecutiveBadFrames: Int = 0

    /// Identity of the most recent payload, and when it was first seen repeating. Arrival alone
    /// cannot tell a live stream from a camera replaying one cached frame — see
    /// ``recordGoodFrame(at:signature:)``.
    private var lastSignature: UInt64?
    private var repeatingSince: Date?

    /// Stall thresholds: max seconds between good frames, max consecutive unparsable frames, and
    /// max seconds the same image may repeat before the stream counts as dead.
    public init(
        stallTimeoutSeconds: TimeInterval = 6,
        maxConsecutiveBadFrames: Int = 12,
        repeatedFrameTimeoutSeconds: TimeInterval = 4
    ) {
        self.stallTimeoutSeconds = stallTimeoutSeconds
        self.maxConsecutiveBadFrames = maxConsecutiveBadFrames
        self.repeatedFrameTimeoutSeconds = repeatedFrameTimeoutSeconds
        lastGoodFrameAt = Date()
    }

    /// Current status. Call `check(at:)` to refresh the stall-timeout evaluation.
    public private(set) var status: Status = .streaming

    /// Whether the current stall is a body replaying one cached frame rather than a stream that
    /// went quiet. Both restart, but they read very differently in a connection log — and only
    /// this one arrives while frames are still being delivered on time.
    public var isRepeatingLastFrame: Bool {
        status == .stalled && repeatingSince != nil
    }

    /// Records a successfully decoded frame with no payload identity — the caller is holding the
    /// last image deliberately (Command's header-only pulls, a resume after a stream restart), so
    /// repetition here is expected and the repeat tracking resets rather than accumulating.
    public mutating func recordGoodFrame(at timestamp: Date) {
        lastSignature = nil
        repeatingSince = nil
        lastGoodFrameAt = timestamp
        consecutiveBadFrames = 0
        status = .streaming
    }

    /// Records a successfully decoded frame together with an identity for its payload
    /// (``LiveFrameSignature``).
    ///
    /// Arrival is not liveness. A wedged body keeps answering `GetLiveViewImageEx` with the same
    /// cached JPEG, so every frame decodes, every frame counts as good, and the operator watches a
    /// frozen image under readouts that claim the stream is healthy — the shape of #283, and the
    /// reason a dead stream could sit there indefinitely instead of being recovered or reported.
    /// A live sensor never emits the same bytes twice (noise alone guarantees it), so a payload
    /// that repeats for longer than the timeout is positive evidence of a replay, not a slow scene.
    ///
    /// Recovery is self-correcting: a genuinely new payload clears the streak and returns the
    /// status to `.streaming`, so a body that un-wedges is not held down by a stale verdict.
    public mutating func recordGoodFrame(at timestamp: Date, signature: UInt64) {
        if lastSignature == signature {
            let since = repeatingSince ?? timestamp
            repeatingSince = since
            if timestamp.timeIntervalSince(since) >= repeatedFrameTimeoutSeconds {
                lastGoodFrameAt = timestamp
                consecutiveBadFrames = 0
                status = .stalled
                return
            }
        } else {
            lastSignature = signature
            repeatingSince = nil
        }
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
        lastSignature = nil
        repeatingSince = nil
        lastGoodFrameAt = Date()
        status = .streaming
    }
}

/// Cheap identity for a live-view payload, so ``LiveViewWatchdog`` can tell a moving stream from a
/// body replaying one cached frame.
///
/// Sampled rather than hashed whole: the cost has to stay flat per frame at 40 fps, and identity is
/// all that is being asked. Identical payloads always agree, which is the direction that matters.
/// Two DIFFERENT frames colliding is possible in principle but has to recur unbroken for seconds
/// before it can trip the watchdog, and live sensor noise makes that vanishingly unlikely.
public enum LiveFrameSignature {
    /// Bytes sampled across the payload. Enough to separate frames of a noisy sensor, small enough
    /// that a 2 MB JPEG costs the same as a 40 KB one.
    private static let sampleCount = 512

    public static func of(_ payload: Data) -> UInt64 {
        // FNV-1a. Length is folded in first so two payloads that differ only in size still differ
        // even when the sampled bytes happen to line up.
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        hash = mix(hash, UInt64(payload.count))
        guard !payload.isEmpty else { return hash }
        let step = max(1, payload.count / sampleCount)
        var offset = 0
        while offset < payload.count {
            hash = mix(hash, UInt64(payload[payload.startIndex + offset]))
            offset += step
        }
        return hash
    }

    private static func mix(_ hash: UInt64, _ value: UInt64) -> UInt64 {
        (hash ^ value) &* 0x0000_0100_0000_01B3
    }
}
