import Foundation
import ImageCaptureCore
import Testing

@testable import Runner

/// Regression cover for the "session must recover without an app restart" defect class
/// (#264 first connect needs cancel+retry, #254 USB reattach, #253 camera power cycle).
///
/// Every case uses the `usb:` host key of a device that is not attached, so establishment fails
/// immediately inside `establishSession` with no socket, no camera and no waiting — the connection
/// *lifecycle* is what is under test, not the transport.
@MainActor
@Suite("Camera connection lifecycle")
struct ConnectionLifecycleTests {
    private static let absentUSBHost = "usb:lifecycle-tests-not-attached"

    private func model() -> NativeAppModel {
        let model = NativeAppModel()
        model.cameraHost = Self.absentUSBHost
        return model
    }

    /// Lets the establishment task run to completion. The absent-USB path throws on its first
    /// `await`, so a couple of yields is enough; polling keeps it robust without a fixed sleep.
    private func settle(_ model: NativeAppModel) async {
        for _ in 0..<200 {
            if !model.debugIsEstablishingConnection { return }
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    @Test("An explicit cancel releases the single-flight latch immediately")
    func cancelReleasesLatch() async {
        let model = model()
        model.connectToCamera()
        #expect(model.debugIsEstablishingConnection)

        model.cancelConnectionAttempt()

        // #264: the latch used to survive until the abandoned attempt's own `defer` ran — up to a
        // full socket timeout — and every retry in that window was silently swallowed.
        #expect(model.debugIsEstablishingConnection == false)
        #expect(model.debugHasCameraSession == false)
        #expect(model.sessionRecovery == .idle)
    }

    @Test("A retry immediately after a cancel is not swallowed")
    func retryAfterCancelIsAccepted() async {
        let model = model()
        model.connectToCamera()
        model.cancelConnectionAttempt()

        let generationBeforeRetry = model.debugConnectionGeneration
        model.connectToCamera()

        #expect(model.debugIsEstablishingConnection)
        #expect(model.debugConnectionGeneration > generationBeforeRetry)
        await settle(model)
    }

    @Test("A failed attempt leaves exactly the state an explicit cancel leaves")
    func failureAndCancelAgreeOnCleanState() async {
        let cancelled = model()
        cancelled.connectToCamera()
        cancelled.cancelConnectionAttempt()
        // Settle both, or this compares a finished failure against a still-unwinding cancel.
        await settle(cancelled)

        let failed = model()
        failed.connectToCamera()
        await settle(failed)

        // The acceptance criterion behind #264: no hidden state distinguishes the two, so the
        // identical retry works without the operator having to cancel first.
        #expect(failed.debugIsEstablishingConnection == cancelled.debugIsEstablishingConnection)
        #expect(failed.debugHasCameraSession == cancelled.debugHasCameraSession)
        #expect(failed.connectedIdentity == nil)
        #expect(cancelled.connectedIdentity == nil)
        #expect(failed.sessionRecovery == cancelled.sessionRecovery)
        // `connection` is deliberately NOT compared. `settle` waits for the establishment latch,
        // but with no monitor up the discovery loop then resumes asynchronously, flipping
        // .disconnected → .scanning on each model's own schedule — so both an absolute
        // `== .disconnected` and an `a == b` comparison race, in either direction. The invariant
        // that actually holds is that neither attempt left a live connection behind; the
        // lifecycle state asserted above is what #264 is about.
        #expect(failed.connection != .connected)
        #expect(cancelled.connection != .connected)
    }

    @Test("A failed attempt surfaces a retryable failure rather than spinning")
    func failureIsRetryable() async {
        let model = model()
        model.connectToCamera()
        await settle(model)

        #expect(model.connectionPhase == .failed)
        #expect(model.connectionFailureDetail.isEmpty == false)
        // The card's "Try again" is accepted only from a settled failure.
        model.retryConnectionAttempt()
        #expect(model.debugIsEstablishingConnection)
        await settle(model)
    }

    @Test("Overlapping connect triggers coalesce instead of stacking sessions")
    func noDuplicateSessions() async {
        let model = model()
        let before = model.debugConnectionGeneration
        model.connectToCamera()
        let afterFirst = model.debugConnectionGeneration
        model.connectToCamera()
        model.connectToCamera()

        // A PTP camera accepts one command channel per initiator: extra taps must be dropped, not
        // opened as a second attempt (each attempt bumps the teardown generation exactly once).
        #expect(afterFirst == before + 1)
        #expect(model.debugConnectionGeneration == afterFirst)
        await settle(model)
    }

    @Test("Cancelling in each machine-driven phase leaves a clean, immediately retryable state")
    func cancelInEveryPhase() async {
        for phase in [
            CameraConnectionPhase.joiningWiFi, .discovering, .handshaking, .pairing,
            .preparingLiveView,
        ] {
            let model = model()
            model.connectToCamera()
            model.connectionPhase = phase

            model.cancelConnectionAttempt()

            #expect(model.debugIsEstablishingConnection == false, "latch held after \(phase)")
            #expect(model.debugHasCameraSession == false, "session survived cancel in \(phase)")
            #expect(model.sessionRecovery == .idle, "recovery armed after cancel in \(phase)")

            model.connectToCamera()
            #expect(model.debugIsEstablishingConnection, "retry swallowed after \(phase)")
            await settle(model)
        }
    }

    @Test("Teardown disposes queued camera-setting writes so a reconnect cannot replay them")
    func teardownDropsQueuedWrites() async {
        let model = model()
        model.debugEnqueueCameraWrite(.movieExposureIndex)
        #expect(model.debugPendingCameraWriteCount == 1)

        model.connectToCamera()

        // Every connect runs the full clear first, so a reconnect starts from the camera's own
        // authoritative state instead of replaying writes queued against the dead session.
        #expect(model.debugPendingCameraWriteCount == 0)
        await settle(model)
    }
}

/// The recovery affordance's state machine as the operator drives it.
@MainActor
@Suite("Dropped-session recovery")
struct SessionRecoveryLifecycleTests {
    private func recoveringModel() -> NativeAppModel {
        let model = NativeAppModel()
        model.cameraHost = "usb:recovery-tests-not-attached"
        model.isMonitorPresented = true
        model.forceSessionRecoveryState(.waitingForOperator(attemptsMade: 8))
        return model
    }

    @Test("A drop keeps the operator in the monitor with the frame marked as held")
    func dropKeepsMonitorUp() {
        let model = recoveringModel()

        #expect(model.isMonitorPresented)
        #expect(model.sessionRecovery.isRecovering)
        #expect(model.liveFPS == SessionRecoveryCopy.heldFrameBadge)
    }

    @Test("Back to operator menu stops retrying and leaves the monitor")
    func operatorMenuExitCancelsRetries() {
        let model = recoveringModel()

        model.exitMonitorToOperatorMenu()

        // #253's duplicate-session risk: an explicit exit must never be undone by a late reconnect.
        #expect(model.debugHasSessionRecoveryTask == false)
        #expect(model.sessionRecovery == .idle)
        #expect(model.isMonitorPresented == false)
        #expect(model.connection == .disconnected)
    }

    @Test("A manual disconnect cancels recovery")
    func manualDisconnectCancelsRecovery() {
        let model = recoveringModel()

        model.disconnect()

        #expect(model.debugHasSessionRecoveryTask == false)
        #expect(model.sessionRecovery == .idle)
    }

    /// #264's hidden latch, on the recovery path this time. `connectToCamera` releases the
    /// single-flight latch as part of its own teardown, but only *after* the guard — so a Retry
    /// landing while an attempt was still in flight got swallowed and started nothing. Recovery
    /// connects run without the timeout watchdog, so nothing bounded that wait.
    @Test("Retry abandons the in-flight attempt instead of being swallowed by its own latch")
    func retryReleasesTheEstablishmentLatch() {
        let model = recoveringModel()
        model.connectToCamera(preservingMonitorSurface: true)
        #expect(model.debugIsEstablishingConnection)
        let abandoned = model.debugConnectionGeneration

        model.retrySessionRecovery()

        // The generation bump disowns the abandoned attempt: its late `defer` is scoped to the
        // old generation, so it can no longer unlatch the attempt that replaced it.
        #expect(model.debugConnectionGeneration > abandoned)
        #expect(model.debugIsEstablishingConnection == false, "retry swallowed by the stale latch")
        #expect(model.debugHasSessionRecoveryTask)

        model.exitMonitorToOperatorMenu()
    }

    @Test("Recovery never arms without a monitor to preserve")
    func noRecoveryWithoutMonitor() {
        let model = NativeAppModel()
        model.cameraHost = "usb:recovery-tests-not-attached"
        model.isMonitorPresented = false

        model.retrySessionRecovery()

        #expect(model.debugHasSessionRecoveryTask == false)
        #expect(model.sessionRecovery == .idle)
    }

    /// #254's headline case: a physical detach is NOT an app-level disconnect. The cable pull has
    /// to hold the monitor and arm the bounded loop; the operator's own Disconnect has to leave.
    @Test("A transport detach arms recovery where an app-level disconnect does not")
    func transportDetachArmsRecoveryUnlikeDisconnect() async {
        let detached = NativeAppModel()
        detached.cameraHost = "usb:recovery-tests-not-attached"
        detached.isMonitorPresented = true

        detached.debugSimulateTransportDetach()

        #expect(detached.debugHasSessionRecoveryTask)
        #expect(detached.isMonitorPresented)
        #expect(detached.connection == .reconnecting)
        #expect(detached.liveFPS == SessionRecoveryCopy.heldFrameBadge)
        for _ in 0..<200 where !detached.sessionRecovery.isRecovering {
            try? await Task.sleep(for: .milliseconds(10))
        }
        #expect(detached.sessionRecovery.isRecovering)
        detached.exitMonitorToOperatorMenu()

        let disconnected = NativeAppModel()
        disconnected.cameraHost = "usb:recovery-tests-not-attached"
        disconnected.isMonitorPresented = true

        disconnected.disconnect()

        #expect(disconnected.debugHasSessionRecoveryTask == false)
        #expect(disconnected.sessionRecovery == .idle)
        #expect(disconnected.isMonitorPresented == false)
    }
}

/// The USB transport's detach contract (#254). ImageCaptureCore reports a removal per device, and
/// the transport backing the live session must die with its own cable — and only its own.
@Suite("USB transport detach")
struct USBCameraTransportDetachTests {
    @Test("Detaching the session's own device ends the event stream")
    func detachEndsEventStream() async {
        let device = ICCameraDevice()
        let transport = USBCameraTransport(device: device)

        transport.closeIfDetached(device)

        // What the session's drain loop reads, and the only signal that reaches
        // `recoverFromEndedEventChannel`. Before the fix the stream stayed open forever.
        await #expect(throws: NativeCameraSessionError.self) {
            _ = try await transport.nextEvent()
        }
    }

    @Test("Detaching an unrelated camera leaves the live session's stream open")
    func unrelatedDetachIsIgnored() async {
        let device = ICCameraDevice()
        let transport = USBCameraTransport(device: device)

        transport.closeIfDetached(ICCameraDevice())

        let streamEnded = await withTaskGroup(of: Bool.self) { group in
            group.addTask {
                _ = try? await transport.nextEvent()
                return true
            }
            group.addTask {
                try? await Task.sleep(for: .milliseconds(100))
                return false
            }
            let first = await group.next() ?? false
            group.cancelAll()
            return first
        }
        #expect(streamEnded == false, "an unrelated camera's detach killed a live session")
        transport.close()
    }
}
