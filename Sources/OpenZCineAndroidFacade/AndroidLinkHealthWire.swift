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
        resetSignalBars: Bool
    ) -> AndroidLinkHealthSnapshot? {
        guard let phase = AndroidCameraLinkPhaseWire(rawValue: phaseRaw) else { return nil }
        let health = CameraLinkHealthScorer.score(
            CameraLinkHealthInputs(
                phase: phase.corePhase,
                ptpRoundTripMilliseconds: roundTripMilliseconds,
                liveViewFPS: liveViewFPS,
                targetLiveViewFPS: targetLiveViewFPS,
                secondsSinceLastGoodFrame: secondsSinceLastGoodFrame,
                consecutiveBadFrames: consecutiveBadFrames,
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
        return AndroidLinkHealthSnapshot(
            score: health.linkHealthScore,
            signalBars: displayedBars,
            detailCaption: health.detailCaption)
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
