import Foundation
import OpenZCineCore

/// Stable numeric values carried from the Android shell into the shared link-health scorer.
public enum AndroidCameraLinkPhaseWire: Int, Sendable {
    case disconnected = 0
    case connecting = 1
    case connectedIdle = 2
    case streaming = 3
    case recovering = 4
    case demo = 5

    fileprivate var corePhase: CameraLinkPhase {
        switch self {
        case .disconnected: .disconnected
        case .connecting: .connecting
        case .connectedIdle: .connectedIdle
        case .streaming: .streaming
        case .recovering: .recovering
        case .demo: .demo
        }
    }
}

/// What the live-view pump's ``LiveViewWatchdog`` knows about the stream and the Kotlin shell
/// cannot.
///
/// An unparsable frame is caught and dropped inside `PTPIPClientSession.runLiveViewPump` and never
/// crosses JNI, so a shell-side streak is permanently zero and `CameraLinkHealthScorer`'s
/// bad-frame penalty could never fire — the bars stayed high exactly as the body degraded.
/// Freshness has the same flaw one step removed: Kotlin can only time frame ARRIVALS, the
/// consumer's clock, while iOS times the decode (`NativeAppRoot.streamUntilStall` sets
/// `lastGoodFrameAt` beside `watchdog.recordGoodFrame`).
///
/// Carried as the timestamp rather than an elapsed value because the pump publishes once per poll:
/// a stream that dies inside a blocked socket read has to keep ageing while nothing is published,
/// which a frozen delta would read as perfectly fresh at exactly the wrong moment.
public struct AndroidLiveViewStreamHealth: Equatable, Sendable {
    /// When the pump last decoded a frame.
    public let lastGoodFrameAt: Date
    /// The watchdog's current unparsable-frame streak.
    public let consecutiveBadFrames: Int

    /// Creates one pump-authored stream observation.
    public init(lastGoodFrameAt: Date, consecutiveBadFrames: Int) {
        self.lastGoodFrameAt = lastGoodFrameAt
        self.consecutiveBadFrames = max(0, consecutiveBadFrames)
    }

    /// Seconds since the last decoded frame, measured at scoring time. Clamped at zero so a
    /// wall-clock adjustment can never report a frame from the future as negative age.
    public func secondsSinceLastGoodFrame(now: Date = Date()) -> Double {
        max(0, now.timeIntervalSince(lastGoodFrameAt))
    }
}

/// Swift-scored health record consumed by Android Compose.
public struct AndroidLinkHealthSnapshot: Equatable, Sendable {
    /// Shared 0–100 link health score.
    public let score: Int
    /// Hysteresis-filtered 0–4 signal bars.
    public let signalBars: Int
    /// Honest detail assembled by `CameraLinkHealthScorer`.
    public let detailCaption: String

    /// Creates one Android-facing health record.
    public init(score: Int, signalBars: Int, detailCaption: String) {
        self.score = score
        self.signalBars = signalBars
        self.detailCaption = detailCaption
    }
}

/// Serializes Android's real shell observations through the portable shared health policy.
///
/// The process has one active Android camera session at a time. Keeping the
/// `LinkSignalBars` filter here ensures Kotlin never reimplements its
/// hysteresis rules. A new connection must pass `resetSignalBars: true`.
public enum AndroidLinkHealthWire {
    /// Lock-protected process state for the one active Android camera link.
    /// `NSLock` provides the synchronization Swift's static-state checker
    /// cannot infer, so the container's unchecked Sendable conformance is
    /// deliberately scoped to this private implementation detail.
    private final class SignalBarsStorage: @unchecked Sendable {
        let lock = NSLock()
        var signalBars = LinkSignalBars()
    }

    private static let storage = SignalBarsStorage()

    /// Scores one genuine Android session observation, or `nil` for invalid wire input.
    public static func snapshot(
        phaseRaw: Int,
        roundTripMilliseconds: Double?,
        liveViewFPS: Double?,
        targetLiveViewFPS: Double,
        secondsSinceLastGoodFrame: Double?,
        consecutiveBadFrames: Int,
        recentCommandFailures: Int,
        isRecoveringStream: Bool,
        isUSBTransport: Bool,
        resetSignalBars: Bool,
        /// Measured link throughput, appended to the caption for the same reason iOS appends it:
        /// the score cannot say whether a healthy-latency link is simply too narrow to carry the
        /// operator's preset. `nil` before the first frame, and never shown for USB — a cable has
        /// no radio to be narrow.
        throughputMegabitsPerSecond: Double? = nil,
        /// The live-view pump's own view of the stream, present whenever a pump is running. It
        /// OUTRANKS both frame observations above, because the shell cannot produce either honestly
        /// — see ``AndroidLiveViewStreamHealth``. `nil` (no pump) leaves the shell's values in
        /// place.
        liveViewStreamHealth: AndroidLiveViewStreamHealth? = nil
    ) -> AndroidLinkHealthSnapshot? {
        guard let phase = AndroidCameraLinkPhaseWire(rawValue: phaseRaw) else { return nil }
        let health = CameraLinkHealthScorer.score(
            CameraLinkHealthInputs(
                phase: phase.corePhase,
                ptpRoundTripMilliseconds: roundTripMilliseconds,
                liveViewFPS: liveViewFPS,
                targetLiveViewFPS: targetLiveViewFPS,
                secondsSinceLastGoodFrame: liveViewStreamHealth?.secondsSinceLastGoodFrame()
                    ?? secondsSinceLastGoodFrame,
                consecutiveBadFrames: liveViewStreamHealth?.consecutiveBadFrames
                    ?? consecutiveBadFrames,
                recentCommandFailures: recentCommandFailures,
                isRecoveringStream: isRecoveringStream))
        storage.lock.lock()
        defer { storage.lock.unlock() }
        if resetSignalBars { storage.signalBars = LinkSignalBars() }
        let filteredBars = storage.signalBars.update(score: health.linkHealthScore)
        // USB frame timing is still included in the score and detail, but it
        // is not radio strength. Mirror iOS's full-bar presentation for an
        // alive physical cable without pretending Wi-Fi signal measurement.
        let displayedBars = isUSBTransport && health.linkHealthScore > 0 ? 4 : filteredBars
        var caption = health.detailCaption
        if !isUSBTransport, let throughputMegabitsPerSecond {
            var sampler = LinkThroughputSampler()
            // One second of the measured rate reconstructs it exactly through the shared
            // formatter, so both shells round and label the number identically.
            sampler.record(
                bytes: Int((throughputMegabitsPerSecond * 1_000_000 / 8).rounded()), seconds: 1)
            if let rate = sampler.formatted { caption += " · \(rate)" }
        }
        return AndroidLinkHealthSnapshot(
            score: health.linkHealthScore,
            signalBars: displayedBars,
            detailCaption: caption)
    }

    /// Encodes a snapshot as `score<TAB>bars<TAB>detail` for the JNI bridge.
    public static func encode(_ snapshot: AndroidLinkHealthSnapshot) -> String? {
        guard
            !snapshot.detailCaption.contains("\t"),
            !snapshot.detailCaption.contains("\n"),
            !snapshot.detailCaption.contains("\r")
        else { return nil }
        return "\(snapshot.score)\t\(snapshot.signalBars)\t\(snapshot.detailCaption)"
    }
}
