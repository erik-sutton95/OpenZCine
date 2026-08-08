import Foundation

/// Whether an interrupted camera session is being recovered, and how the operator is told.
///
/// Both shells drive the same three states so a dropped link reads identically on iPhone and
/// Android: the monitor stays up on the last frame, automatic retries run bounded, and when the
/// budget is spent the operator — not the app — decides what happens next.
public enum SessionRecoveryState: Equatable, Sendable {
    /// No recovery in progress: either the session is live, or none was ever established.
    case idle
    /// An automatic reconnect is running (or waiting out its backoff). `attempt` is 1-based.
    case retrying(attempt: Int, maxAttempts: Int)
    /// The automatic budget is spent. The operator chooses: retry, or leave the monitor.
    case waitingForOperator(attemptsMade: Int)
    /// Reconnects kept SUCCEEDING but the session kept dying young (see
    /// ``SessionDropStormGuard``). Automatic recovery is paused to protect the camera; the
    /// operator chooses.
    case pausedAfterRepeatedDrops(drops: Int)

    /// Whether the operator should be shown the recovery affordance over the frozen frame.
    public var isRecovering: Bool { self != .idle }
}

/// Cross-run damping for sessions that reconnect cleanly but keep dying.
///
/// ``SessionRecoveryPolicy`` bounds one recovery run, but a run that *succeeds* resets the
/// budget — so a periodic external killer (another device PTP-probing the camera, an unanswered
/// body-side liveness probe) produced an unbounded storm of instant reconnects. Nikon bodies
/// wedge under that churn: enough rapid session opens and the camera stops accepting
/// connections until a battery pull. This guard counts DROPS rather than failures, across
/// recovery runs; when they cluster, automatic recovery pauses and the operator decides.
///
/// Reset on operator action (retry, disconnect, fresh connect) — never on reconnect success,
/// because success is exactly what a storm fakes well.
public struct SessionDropStormGuard: Sendable, Equatable {
    private var dropTimesSeconds: [Double] = []

    public init() {}

    /// Drops older than this no longer count toward the storm verdict.
    public static let windowSeconds: Double = 120
    /// This many drops inside the window pauses automatic recovery.
    public static let pauseAfterDrops = 3

    /// Records a session drop at `now` (any monotonic seconds timeline) and reports whether
    /// automatic recovery must pause.
    public mutating func noteDrop(now: Double) -> Bool {
        dropTimesSeconds.append(now)
        dropTimesSeconds.removeAll { now - $0 > Self.windowSeconds }
        return dropTimesSeconds.count >= Self.pauseAfterDrops
    }

    /// Drops currently inside the window (drives the operator-facing count).
    public var dropsInWindow: Int { dropTimesSeconds.count }

    public mutating func reset() { dropTimesSeconds.removeAll() }
}

/// What the recovery loop should do after `n` consecutive failed reconnect attempts.
public enum SessionRecoveryDecision: Equatable, Sendable {
    /// Wait this long (seconds; 0 = immediately), then attempt again.
    case retry(afterSeconds: Double)
    /// Stop retrying and hand the decision back to the operator.
    case stop
}

/// The shared reconnect rule: when to retry a dropped camera session, how long to back off, and
/// when to stop and ask the operator.
///
/// This lives in the core deliberately. A dropped USB cable, a camera power cycle, and a flaky
/// access point are the same event to the operator, and the two shells must not disagree about how
/// long the app keeps trying — that disagreement is what produced an unbounded retry loop on
/// Android and no retry at all on iOS.
public struct SessionRecoveryPolicy: Sendable, Equatable {
    /// Jittered exponential schedule applied from the second attempt onward.
    public var backoff: ReconnectBackoff
    /// How many automatic attempts to make before handing back to the operator.
    public var maxAutomaticAttempts: Int

    public init(
        backoff: ReconnectBackoff = ReconnectBackoff(baseSeconds: 0.5, maxSeconds: 8),
        maxAutomaticAttempts: Int = 8
    ) {
        self.backoff = backoff
        self.maxAutomaticAttempts = max(0, maxAutomaticAttempts)
    }

    /// The monitor's schedule: retry at once, then 0.5s → 8s jittered, giving up after 8 attempts
    /// (~30s of backoff plus attempt time). Long enough to ride out a camera power cycle or a cable
    /// reseat; short enough that a camera that is genuinely gone stops burning the phone's radio.
    public static let monitor = SessionRecoveryPolicy()

    /// Decides the next step given how many consecutive attempts have already failed.
    ///
    /// - Parameters:
    ///   - failures: consecutive failed attempts so far. `0` means the link just dropped and
    ///     nothing has been tried yet, which retries immediately — the overwhelmingly common case
    ///     is a blip the very next Init clears.
    ///   - jitter: a sample in `0...1` (see ``ReconnectBackoff``); pass `0.5` for the midpoint.
    public func decision(afterFailedAttempts failures: Int, jitter: Double)
        -> SessionRecoveryDecision
    {
        let failed = max(0, failures)
        guard failed < maxAutomaticAttempts else { return .stop }
        guard failed > 0 else { return .retry(afterSeconds: 0) }
        return .retry(afterSeconds: backoff.delaySeconds(forAttempt: failed - 1, jitter: jitter))
    }

    /// The state to publish after `failures` consecutive failures, for the same inputs as
    /// ``decision(afterFailedAttempts:jitter:)``. Keeps the operator-visible attempt counter and the
    /// give-up point from drifting apart across shells.
    public func state(afterFailedAttempts failures: Int) -> SessionRecoveryState {
        let failed = max(0, failures)
        guard failed < maxAutomaticAttempts else {
            return .waitingForOperator(attemptsMade: failed)
        }
        return .retrying(attempt: failed + 1, maxAttempts: maxAutomaticAttempts)
    }
}

/// Operator-facing copy for the recovery affordance, shared so both shells say the same thing.
public enum SessionRecoveryCopy {
    /// Headline over the frozen frame.
    public static func title(_ state: SessionRecoveryState) -> String {
        switch state {
        case .idle: return ""
        case .retrying: return "Reconnecting…"
        case .waitingForOperator: return "Camera disconnected"
        case .pausedAfterRepeatedDrops: return "Connection keeps dropping"
        }
    }

    /// Supporting line. Truthful about what is on screen: the frame is held, not live.
    public static func detail(_ state: SessionRecoveryState, deviceName: String) -> String {
        let name = deviceName.trimmingCharacters(in: .whitespacesAndNewlines)
        let camera = name.isEmpty ? "The camera" : name
        switch state {
        case .idle:
            return ""
        case .retrying(let attempt, let maxAttempts):
            return
                "\(camera) dropped off. Holding the last frame — attempt \(attempt) of \(maxAttempts)."
        case .waitingForOperator(let attemptsMade):
            let tries = attemptsMade == 1 ? "1 try" : "\(attemptsMade) tries"
            return "\(camera) didn't come back after \(tries). The frame below is held, not live."
        case .pausedAfterRepeatedDrops(let drops):
            return
                "\(camera) reconnected but dropped \(drops) times in quick succession. Automatic retries are paused to protect the camera — another device may be scanning for cameras. The frame below is held, not live."
        }
    }

    /// Badge shown on the monitor's frame-rate readout while the feed is not live.
    public static let heldFrameBadge = "NO LINK"
}

/// Bounded time budget for each machine-driven connection phase.
///
/// Every phase the app can advance on its own gets a truthful ceiling, so a first connection that
/// stops making progress fails with an actionable error and a Retry instead of spinning forever
/// (the "cancel and try again" workaround). Phases that wait on a human — the Wi-Fi join prompt,
/// a pairing confirmation on the camera body — return `nil`: hurrying an operator is not a timeout.
public enum CameraConnectionTimeout {
    /// Seconds this phase may run before the attempt is failed, or `nil` when it waits on a person.
    ///
    /// The USB budget is the larger one: ImageCaptureCore's card enumeration gates the session-open
    /// ack, and on a full CFexpress card that legitimately takes over a minute.
    public static func budgetSeconds(for phase: CameraConnectionPhase, isUSB: Bool) -> Double? {
        switch phase {
        case .idle, .readyToJoin, .pairing, .confirmOnCamera, .connected, .failed:
            return nil
        case .joiningWiFi:
            return 45
        case .discovering:
            return 40
        case .handshaking:
            return isUSB ? 120 : 60
        case .preparingLiveView:
            return 40
        }
    }

    /// Operator-facing failure copy for a phase that ran out its budget.
    public static func timeoutMessage(phase: CameraConnectionPhase, deviceName: String) -> String {
        let name = deviceName.trimmingCharacters(in: .whitespacesAndNewlines)
        let camera = name.isEmpty ? "the camera" : name
        switch phase {
        case .joiningWiFi:
            return
                "Couldn't join \(camera)'s Wi‑Fi network in time. Check the camera is still broadcasting, then try again."
        case .discovering:
            return
                "Couldn't find \(camera) on the network in time. Check Connect to PC is on, then try again."
        case .handshaking:
            return
                "\(camera) stopped responding while connecting. Try again — if it keeps happening, power-cycle the camera."
        case .preparingLiveView:
            return "\(camera) connected but never started live view. Try again."
        case .idle, .readyToJoin, .pairing, .confirmOnCamera, .connected, .failed:
            return "The connection attempt timed out. Try again."
        }
    }
}
