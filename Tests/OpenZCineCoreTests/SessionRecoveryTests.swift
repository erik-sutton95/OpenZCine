import Testing

@testable import OpenZCineCore

@Suite("Session recovery policy")
struct SessionRecoveryPolicyTests {
    @Test("The first attempt after a drop runs immediately")
    func firstAttemptIsImmediate() {
        let policy = SessionRecoveryPolicy.monitor
        #expect(policy.decision(afterFailedAttempts: 0, jitter: 0.5) == .retry(afterSeconds: 0))
        #expect(policy.state(afterFailedAttempts: 0) == .retrying(attempt: 1, maxAttempts: 8))
    }

    @Test("Later attempts follow the shared jittered backoff")
    func laterAttemptsBackOff() {
        let policy = SessionRecoveryPolicy.monitor
        // jitter 0.5 is the un-jittered midpoint, so the schedule is exactly 0.5 → 1 → 2 → 4.
        #expect(policy.decision(afterFailedAttempts: 1, jitter: 0.5) == .retry(afterSeconds: 0.5))
        #expect(policy.decision(afterFailedAttempts: 2, jitter: 0.5) == .retry(afterSeconds: 1))
        #expect(policy.decision(afterFailedAttempts: 3, jitter: 0.5) == .retry(afterSeconds: 2))
        #expect(policy.decision(afterFailedAttempts: 4, jitter: 0.5) == .retry(afterSeconds: 4))
    }

    @Test("The schedule is capped, never unbounded")
    func delayIsCapped() {
        let policy = SessionRecoveryPolicy.monitor
        guard case .retry(let seconds) = policy.decision(afterFailedAttempts: 7, jitter: 1) else {
            Issue.record("expected a retry before the attempt budget is spent")
            return
        }
        #expect(seconds <= policy.backoff.maxSeconds)
    }

    @Test("Automatic retries stop at the attempt budget and hand back to the operator")
    func stopsAtBudget() {
        let policy = SessionRecoveryPolicy.monitor
        #expect(policy.decision(afterFailedAttempts: 7, jitter: 0.5) != .stop)
        #expect(policy.decision(afterFailedAttempts: 8, jitter: 0.5) == .stop)
        #expect(policy.decision(afterFailedAttempts: 99, jitter: 0.5) == .stop)
        #expect(policy.state(afterFailedAttempts: 8) == .waitingForOperator(attemptsMade: 8))
    }

    @Test("A zero-attempt policy never auto-retries")
    func zeroAttemptPolicyNeverRetries() {
        let policy = SessionRecoveryPolicy(maxAutomaticAttempts: 0)
        #expect(policy.decision(afterFailedAttempts: 0, jitter: 0.5) == .stop)
        #expect(policy.state(afterFailedAttempts: 0) == .waitingForOperator(attemptsMade: 0))
    }

    @Test("Negative failure counts are treated as none")
    func negativeFailuresClamp() {
        let policy = SessionRecoveryPolicy.monitor
        #expect(policy.decision(afterFailedAttempts: -3, jitter: 0.5) == .retry(afterSeconds: 0))
        #expect(policy.state(afterFailedAttempts: -3) == .retrying(attempt: 1, maxAttempts: 8))
    }

    @Test("Only idle means the operator sees a live feed")
    func recoveringFlag() {
        #expect(SessionRecoveryState.idle.isRecovering == false)
        #expect(SessionRecoveryState.retrying(attempt: 1, maxAttempts: 8).isRecovering)
        #expect(SessionRecoveryState.waitingForOperator(attemptsMade: 8).isRecovering)
    }
}

@Suite("Session recovery copy")
struct SessionRecoveryCopyTests {
    @Test("Retrying copy names the camera and the bounded attempt count")
    func retryingCopy() {
        let state = SessionRecoveryState.retrying(attempt: 3, maxAttempts: 8)
        #expect(SessionRecoveryCopy.title(state) == "Reconnecting…")
        let detail = SessionRecoveryCopy.detail(state, deviceName: "Nikon ZR")
        #expect(detail.contains("Nikon ZR"))
        #expect(detail.contains("attempt 3 of 8"))
    }

    @Test("Exhausted copy is honest that the frame is held, not live")
    func exhaustedCopy() {
        let state = SessionRecoveryState.waitingForOperator(attemptsMade: 8)
        #expect(SessionRecoveryCopy.title(state) == "Camera disconnected")
        let detail = SessionRecoveryCopy.detail(state, deviceName: "Nikon ZR")
        #expect(detail.contains("8 tries"))
        #expect(detail.contains("held, not live"))
    }

    @Test("A single try is not pluralised")
    func singleTryCopy() {
        let detail = SessionRecoveryCopy.detail(
            .waitingForOperator(attemptsMade: 1), deviceName: "Nikon ZR")
        #expect(detail.contains("1 try"))
    }

    @Test("A blank device name degrades to a generic subject")
    func blankDeviceName() {
        let detail = SessionRecoveryCopy.detail(
            .retrying(attempt: 1, maxAttempts: 8), deviceName: "   ")
        #expect(detail.hasPrefix("The camera"))
    }

    @Test("Idle produces no copy")
    func idleCopy() {
        #expect(SessionRecoveryCopy.title(.idle).isEmpty)
        #expect(SessionRecoveryCopy.detail(.idle, deviceName: "Nikon ZR").isEmpty)
    }
}

@Suite("Connection phase timeouts")
struct CameraConnectionTimeoutTests {
    @Test("Every machine-driven phase is bounded")
    func machineDrivenPhasesAreBounded() {
        for phase in [
            CameraConnectionPhase.joiningWiFi, .discovering, .handshaking, .preparingLiveView,
        ] {
            #expect(CameraConnectionTimeout.budgetSeconds(for: phase, isUSB: false) != nil)
            #expect(CameraConnectionTimeout.budgetSeconds(for: phase, isUSB: true) != nil)
        }
    }

    @Test("Phases that wait on a person are never timed out")
    func operatorPhasesAreUnbounded() {
        for phase in [
            CameraConnectionPhase.idle, .readyToJoin, .pairing, .confirmOnCamera, .connected,
            .failed,
        ] {
            #expect(CameraConnectionTimeout.budgetSeconds(for: phase, isUSB: false) == nil)
        }
    }

    @Test("USB gets the longer handshake budget for the card enumeration")
    func usbHandshakeBudgetIsLarger() {
        let wifi = CameraConnectionTimeout.budgetSeconds(for: .handshaking, isUSB: false)
        let usb = CameraConnectionTimeout.budgetSeconds(for: .handshaking, isUSB: true)
        #expect((usb ?? 0) > (wifi ?? 0))
    }

    @Test("Timeout copy names the phase's actual failure and stays actionable")
    func timeoutCopy() {
        #expect(
            CameraConnectionTimeout.timeoutMessage(phase: .discovering, deviceName: "Nikon ZR")
                .contains("Connect to PC"))
        #expect(
            CameraConnectionTimeout.timeoutMessage(phase: .handshaking, deviceName: "Nikon ZR")
                .contains("Nikon ZR"))
        #expect(
            CameraConnectionTimeout.timeoutMessage(phase: .joiningWiFi, deviceName: "")
                .contains("the camera"))
    }
}
