import Foundation
import ImageCaptureCore
import OpenCineCore
import OpenZCineCore
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

    /// Hardware pass 2026-10-25 (1.11): the wait for a dozing body ran under "Establishing a
    /// secure link" with no waiting step.
    @Test("The body wake shows its waiting step and hands back to the handshake on an answer")
    func bodyWakeShowsTheWaitingStep() {
        let model = model()
        model.noteBodyWake(.waiting)
        #expect(model.isAwaitingBodyWake)
        #expect(model.connectionStageDetail == NikonBodyWake.wakingMessage(deviceName: ""))
        model.noteBodyWake(.answered)
        #expect(!model.isAwaitingBodyWake)
        #expect(model.connectionStageDetail.isEmpty)
    }

    @Test("A late wake step from a superseded attempt never touches the current one")
    func staleWakeProgressIsDropped() async {
        let model = model()
        struct Superseded: Error {}
        let stale = model.bodyWakeProgressHandler(requireCurrent: { throw Superseded() })
        stale(.waiting)
        for _ in 0..<20 { await Task.yield() }
        #expect(!model.isAwaitingBodyWake)
        #expect(model.connectionStageDetail.isEmpty)
        let current = model.bodyWakeProgressHandler(requireCurrent: {})
        current(.waiting)
        for _ in 0..<20 { await Task.yield() }
        #expect(model.isAwaitingBodyWake)
    }

    @Test("Cancel retires an unanswered take-over before a late confirmation")
    func cancelledTakeOverCannotStartConnection() {
        let model = model()
        defer { model.cancelConnectionAttempt() }
        let held = DiscoveredCamera(
            ip: Self.absentUSBHost, name: "SIMULATED held camera", source: .heldByAnotherDevice,
            heldByDeviceName: "SIMULATED other phone")
        model.connectToCamera(held)
        #expect(!model.debugIsEstablishingConnection, "operator consent precedes admission")
        let generation = model.debugConnectionGeneration
        model.cancelConnectionAttempt()
        model.confirmTakeOver()
        #expect(
            model.debugConnectionGeneration == generation,
            "a retired consent cannot admit a connection")
        #expect(!model.debugIsEstablishingConnection)
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

    @Test("Reports stay held back from connect start through recovery until the attempt retires")
    func connectAttemptHoldsReportUploads() async {
        let model = model()
        #expect(model.debugHoldsReportingCameraPath == false)
        model.connectToCamera()
        #expect(model.debugHoldsReportingCameraPath)
        model.cancelConnectionAttempt()
        #expect(model.debugHoldsReportingCameraPath == false)

        // A drop into recovery keeps the hold; leaving it releases it (A6-08).
        model.connection = .reconnecting
        #expect(model.debugHoldsReportingCameraPath)
        model.connection = .disconnected
        #expect(model.debugHoldsReportingCameraPath == false)

        // A failed attempt releases the hold with its latch.
        model.connectToCamera()
        #expect(model.debugHoldsReportingCameraPath)
        await settle(model)
        #expect(model.debugHoldsReportingCameraPath == false)
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

    /// The RECOV-forever wedge: the attempt-1 card grace must elapse in the MODEL even while the
    /// first attempt is still in flight. The timer used to live in the overlay as a `.task` on a
    /// view that renders nothing until the card shows — SwiftUI never ran it, so a stalled first
    /// attempt (a killed hotspot) was a permanent RECOV chip with no card and no way out.
    @Test("The attempt-1 card grace elapses while the first attempt is still in flight")
    func recoveryCardGraceElapsesDuringAttemptOne() async {
        let model = NativeAppModel()
        model.cameraHost = "usb:recovery-tests-not-attached"
        model.isMonitorPresented = true

        model.debugSimulateTransportDetach()
        #expect(model.sessionRecoveryCardGraceElapsed == false)

        for _ in 0..<400 where !model.sessionRecoveryCardGraceElapsed {
            try? await Task.sleep(for: .milliseconds(10))
        }
        #expect(
            model.sessionRecoveryCardGraceElapsed,
            "grace never elapsed — the attempt-1 card is unreachable")

        model.exitMonitorToOperatorMenu()
        #expect(model.sessionRecoveryCardGraceElapsed == false)
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

/// A6-02: a returned PTP control session is not a recovered monitor. Recovery ends only on a
/// source frame and a presented picture after the attempt started, and the whole automatic run
/// stops at the shared 180 s budget. SIMULATED transport and virtual clock (`SessionRecoveryPeers`).
@MainActor
@Suite("Dropped-session recovery proof")
struct SessionRecoveryPictureTests {
    @MainActor
    final class Peer {
        private struct Sleeper {
            let id: UUID
            let at: TimeInterval
            let continuation: CheckedContinuation<Void, Error>
        }
        var time: TimeInterval = 0
        var connects = 0
        var controlReady = false
        var establishing = false
        var picture: (sourceAt: TimeInterval?, presentedAt: TimeInterval?) = (nil, nil)
        var onConnect: () -> Void = {}
        /// The device a presence sweep names as holding the camera.
        var holder: String?
        private var sleepers: [Sleeper] = []

        var peers: NativeAppModel.SessionRecoveryPeers {
            .init(
                connect: { [unowned self] in
                    connects += 1
                    onConnect()
                },
                isEstablishing: { [unowned self] in establishing },
                hasControlSession: { [unowned self] in controlReady },
                picture: { [unowned self] in picture },
                now: { [unowned self] in time },
                sleep: { [unowned self] in try await pause($0) },
                holder: holder == nil ? nil : { @MainActor [unowned self] _ in holder })
        }

        private func pause(_ duration: Duration) async throws {
            try Task.checkCancellation()
            let id = UUID()
            let parts = duration.components
            let at = time + Double(parts.seconds) + Double(parts.attoseconds) / 1e18
            try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { continuation in
                    sleepers.append(Sleeper(id: id, at: at, continuation: continuation))
                }
            } onCancel: {
                Task { @MainActor in
                    guard let index = self.sleepers.firstIndex(where: { $0.id == id }) else {
                        return
                    }
                    let sleeper = self.sleepers.remove(at: index)
                    sleeper.continuation.resume(throwing: CancellationError())
                }
            }
        }

        private func settle() async { for _ in 0..<64 { await Task.yield() } }

        /// Wakes virtual sleepers in time order until `done` holds or the clock reaches `limit`.
        func drive(until limit: TimeInterval, _ done: () -> Bool = { false }) async -> Bool {
            for _ in 0..<20_000 {
                await settle()
                if done() { return true }
                guard let next = sleepers.map(\.at).min(), next <= limit else {
                    time = max(time, limit)
                    await settle()
                    return done()
                }
                time = max(time, next)
                let ready = sleepers.filter { $0.at <= next }
                sleepers.removeAll { $0.at <= next }
                for sleeper in ready { sleeper.continuation.resume() }
            }
            return done()
        }
    }

    private func recovering(_ peer: Peer) -> NativeAppModel {
        let model = NativeAppModel()
        model.cameraHost = "usb:recovery-picture-tests-not-attached"
        model.isMonitorPresented = true
        model.sessionRecoveryPeers = peer.peers
        return model
    }

    private func waitingForOperator(_ model: NativeAppModel) -> Bool {
        if case .waitingForOperator = model.sessionRecovery { return true }
        return false
    }

    @Test("A returned control session without a picture keeps recovering")
    func controlWithoutPictureKeepsRecovering() async {
        let peer = Peer()
        peer.onConnect = { peer.controlReady = true }
        let model = recovering(peer)

        model.debugSimulateTransportDetach()
        _ = await peer.drive(until: 5)

        #expect(peer.connects == 1)
        #expect(model.sessionRecovery == .retrying(attempt: 1, maxAttempts: 8))
        model.exitMonitorToOperatorMenu()
    }

    @Test("A picture from before the attempt does not end recovery")
    func stalePictureKeepsRecovering() async {
        let peer = Peer()
        peer.time = 100
        peer.picture = (99, 99)
        peer.onConnect = { peer.controlReady = true }
        let model = recovering(peer)

        model.debugSimulateTransportDetach()
        _ = await peer.drive(until: 105)

        #expect(model.sessionRecovery.isRecovering)
        model.exitMonitorToOperatorMenu()
    }

    @Test("A source frame and presented picture after the attempt started end recovery")
    func freshPictureEndsRecovery() async {
        let peer = Peer()
        peer.onConnect = { peer.controlReady = true }
        let model = recovering(peer)

        model.debugSimulateTransportDetach()
        _ = await peer.drive(until: 1)
        peer.picture = (peer.time, peer.time)
        let recovered = await peer.drive(until: 2) { model.sessionRecovery == .idle }

        #expect(recovered)
        #expect(peer.connects == 1)
        model.exitMonitorToOperatorMenu()
    }

    @Test("A dial that never returns hands to the operator at the total budget")
    func hungAttemptsStopAtBudget() async {
        let peer = Peer()
        peer.onConnect = { peer.establishing = true }
        let model = recovering(peer)

        model.debugSimulateTransportDetach()
        let handedOver = await peer.drive(until: 400) { waitingForOperator(model) }

        #expect(handedOver)
        #expect(peer.time <= 180.001, "automatic recovery ran \(peer.time) s")
        model.exitMonitorToOperatorMenu()
    }

    @Test("Control sessions that never show a picture stop at the total budget")
    func controlOnlyAttemptsStopAtBudget() async {
        let peer = Peer()
        peer.onConnect = { peer.controlReady = true }
        let model = recovering(peer)

        model.debugSimulateTransportDetach()
        let handedOver = await peer.drive(until: 400) { waitingForOperator(model) }

        #expect(handedOver)
        #expect(peer.time <= 180.001, "automatic recovery ran \(peer.time) s")
        #expect(peer.connects > 1, "a control-only attempt is retried, not accepted")
        model.exitMonitorToOperatorMenu()
    }

    /// OpenCine #253: before the first attempt dials, presence is asked three times, one second
    /// apart. Those pauses run on the episode's clock; on a wall-clock sleep the first attempt
    /// never dialed inside a virtual drive (Core 238bb3a pin, run 40171934283).
    @Test("The first attempt's presence asks run on the episode clock, then it dials")
    func firstAttemptPresenceAsksUseTheEpisodeClock() async {
        let peer = Peer()
        peer.onConnect = { peer.controlReady = true }
        var asks: [TimeInterval] = []
        var peers = peer.peers
        peers.holder = { _ in
            asks.append(peer.time)
            return nil
        }
        let model = NativeAppModel()
        model.cameraHost = "192.168.1.30"
        model.isMonitorPresented = true
        model.sessionRecoveryPeers = peers

        model.debugSimulateTransportDetach()
        let dialed = await peer.drive(until: 10) { peer.connects == 1 }

        #expect(dialed)
        #expect(asks.count == 3, "asks: \(asks)")
        #expect(
            zip(asks, asks.dropFirst()).allSatisfy { abs($1 - $0 - 1) < 0.001 }, "asks: \(asks)")
        model.exitMonitorToOperatorMenu()
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

    /// Hosted run 39248287990 aborted in `NativeNikonPort.startDiscovery` with
    /// `swift_abortRetainUnowned`: the shared integration's stream termination reached the port
    /// after the test's model was gone. A late call must do nothing.
    @MainActor
    @Test("The Nikon port ignores calls that arrive after its model is gone")
    func portOutlivingItsModelIgnoresLateCalls() async throws {
        var owner: NativeAppModel? = NativeAppModel()
        weak let released = owner
        let port = NativeNikonPort(model: try #require(owner))
        owner = nil
        try #require(released == nil, "the model must be released for this check to mean anything")
        port.startDiscovery(.passive)
        port.found([])
        port.cancel()
        port.forget(hosts: ["SIMULATED-gone"])
        #expect(port.requestedMode == .passive)
        await #expect(throws: CancellationError.self) {
            _ = try await port.connect(
                .saved(host: "SIMULATED-gone", path: .infrastructure), takingOverConfirmed: false)
        }
    }

    /// CodeRabbit on #440: observation never reports a deallocation, so a model torn down while a
    /// connect waited left the shared flow's attempt suspended for good. Releasing the model must
    /// end the attempt with `CancellationError`. The staged `connecting` outcome holds the attempt
    /// without dialling anything.
    @MainActor
    @Test("Releasing the model ends a pending Nikon connect")
    func releasingTheModelEndsAPendingConnect() async throws {
        var owner: NativeAppModel? = NativeAppModel()
        weak let released = owner
        let port = NativeNikonPort(model: try #require(owner))
        port.demoOutcome = "connecting"
        var handshaking = false
        port.onPhase = { phase, _ in if phase == .handshaking { handshaking = true } }
        let attempt = Task { @MainActor in
            try await port.connect(
                .saved(host: "SIMULATED-pending", path: .infrastructure),
                takingOverConfirmed: false)
        }
        for _ in 0..<200 where !handshaking { await Task.yield() }
        try #require(handshaking, "the staged connect must be pending before the release")
        owner = nil
        try #require(released == nil, "the model must be released for this check to mean anything")
        // A watchdog unblocks an attempt still suspended after two seconds, so a regression fails
        // here instead of hanging the suite.
        let watchdog = Watchdog()
        let timer = Task { @MainActor in
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            watchdog.fired = true
            attempt.cancel()
        }
        let result = await attempt.result
        timer.cancel()
        #expect(!watchdog.fired, "the attempt stayed suspended after its model was released")
        switch result {
        case .success: Issue.record("a released model's attempt connected")
        case .failure(let error): #expect(error is CancellationError)
        }
    }

    /// The real saved-camera path is paused at its existing join adapter. Unlike demo staging,
    /// this starts establishment work and catches that work retaining the model across an await.
    @MainActor
    @Test("Releasing the model cancels a native Nikon connect waiting for its network join")
    func releasingTheModelEndsAPendingNativeConnect() async throws {
        let join = PendingNativeJoin()
        var owner: NativeAppModel? = NativeAppModel()
        weak var released = owner
        let setup = PTPIPSavedCameraRecord(
            host: "192.0.2.1", displayName: "SIMULATED ZR", transport: "Wi-Fi", lastSeenAt: nil,
            presentation: .init(customName: nil, wifiSSID: "NIKON_ZR_TEST"),
            pairedViaCameraAccessPoint: true, path: .cameraAccessPoint(ssid: "NIKON_ZR_TEST"))
        owner?.savedCameras = [setup]
        owner?.connectedWiFiSSID = nil
        owner?.cameraNetworkJoinPeers = .init(
            join: { _ in try await join.wait() }, isAlive: { _ in true },
            dial: { _ in Issue.record("a pending join must not reach a camera dial") })
        let port = NativeNikonPort(model: try #require(owner))
        let attempt = Task { @MainActor in
            try await port.connect(.saved(host: setup.host, path: .cameraAccessPoint))
        }
        defer {
            attempt.cancel()
            join.cancel()
            owner?.cancelConnectionAttempt()
        }
        for _ in 0..<200 where !join.entered { await Task.yield() }
        try #require(join.entered, "the native connection must reach its pending join")
        owner = nil
        #expect(released == nil, "native establishment retained its externally released model")
        let watchdog = Watchdog()
        let timer = Task { @MainActor in
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            watchdog.fired = true
            attempt.cancel()
        }
        let result = await attempt.result
        timer.cancel()
        #expect(!watchdog.fired, "the native connect stayed suspended after owner release")
        switch result {
        case .success: Issue.record("a released native model's attempt connected")
        case .failure(let error): #expect(error is CancellationError)
        }
        for _ in 0..<200 where !join.cancelled { await Task.yield() }
        #expect(join.cancelled, "owner release must also cancel the pending native operation")
    }

    @MainActor
    @Test("An overlapping Nikon connect preserves native work until its model is released")
    func overlappingNativeConnectKeepsTheEstablishmentAlive() async throws {
        let join = PendingNativeJoin()
        var owner: NativeAppModel? = NativeAppModel()
        weak var released = owner
        let setup = PTPIPSavedCameraRecord(
            host: "192.0.2.246", displayName: "SIMULATED ZR", transport: "Wi-Fi", lastSeenAt: nil,
            presentation: .init(customName: nil, wifiSSID: "NIKON_ZR_TEST"),
            pairedViaCameraAccessPoint: true, path: .cameraAccessPoint(ssid: "NIKON_ZR_TEST"))
        owner?.savedCameras = [setup]
        owner?.connectedWiFiSSID = nil
        owner?.cameraNetworkJoinPeers = .init(
            join: { _ in try await join.wait() }, isAlive: { _ in true },
            dial: { _ in Issue.record("the held native join must not dial a camera") })
        let port = NativeNikonPort(model: try #require(owner))
        let first = Task { @MainActor in
            try await port.connect(.saved(host: setup.host, path: .cameraAccessPoint))
        }
        defer {
            first.cancel()
            join.cancel()
            owner?.cancelConnectionAttempt()
        }
        for _ in 0..<200 where !join.entered { await Task.yield() }
        try #require(join.entered, "the real native join must be pending before the overlap")
        let generation = owner?.debugConnectionGeneration
        var secondFinished = false
        let second = Task { @MainActor in
            defer { secondFinished = true }
            return try await port.connect(.saved(host: setup.host, path: .cameraAccessPoint))
        }
        defer { second.cancel() }
        // The newest port waiter replaces the old waiter, while the native funnel coalesces
        // their shared establishment. Replacing its release watch must not cancel that work.
        await #expect(throws: CancellationError.self) { _ = try await first.value }
        for _ in 0..<200 { await Task.yield() }
        #expect(owner?.debugConnectionGeneration == generation)
        #expect(owner?.debugIsEstablishingConnection == true)
        #expect(!join.cancelled, "replacing a watch cancelled the shared native establishment")
        #expect(!secondFinished, "the replacement waiter must keep waiting for the native join")

        owner = nil
        #expect(released == nil)
        let watchdog = Watchdog()
        let timer = Task { @MainActor in
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            watchdog.fired = true
            second.cancel()
        }
        let result = await second.result
        timer.cancel()
        #expect(!watchdog.fired, "the replacement watch failed to cancel work on owner release")
        switch result {
        case .success: Issue.record("the released model's replacement waiter connected")
        case .failure(let error): #expect(error is CancellationError)
        }
        for _ in 0..<200 where !join.cancelled { await Task.yield() }
        #expect(join.cancelled, "the active replacement watch must still cancel native work")
    }

    @MainActor
    private final class PendingNativeJoin {
        var entered = false
        var cancelled = false
        private var continuation: CheckedContinuation<Void, Error>?

        func wait() async throws {
            entered = true
            try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { continuation in
                    self.continuation = continuation
                    if Task.isCancelled { cancel() }
                }
            } onCancel: {
                Task { @MainActor in self.cancel() }
            }
        }

        func cancel() {
            cancelled = true
            let waiter = continuation
            continuation = nil
            waiter?.resume(throwing: CancellationError())
        }
    }

    @MainActor
    private final class Watchdog {
        var fired = false
    }
}

/// SIMULATED SDK completion that ignores cancellation until a pending native read returns.
@MainActor
@Suite("Native Nikon connection admission")
struct NativeNikonConnectionAdmissionTests {
    @Test("The current native connection can still approve its pairing challenge")
    func currentOwnerCanApprovePairing() async throws {
        let handshake = PendingPairingHandshake(holdAfterDecision: true)
        let setup = PTPIPSavedCameraRecord(
            host: "192.0.2.247", displayName: "SIMULATED ZR", transport: "Wi-Fi", lastSeenAt: nil,
            presentation: .init(customName: nil, wifiSSID: "NIKON_ZR_TEST"),
            pairedViaCameraAccessPoint: true, path: .cameraAccessPoint(ssid: "NIKON_ZR_TEST"))
        var owner: NativeAppModel? = NativeAppModel()
        weak var released = owner
        owner?.savedCameras = [setup]
        owner?.connectedWiFiSSID = nil
        owner?.cameraNetworkJoinPeers = .init(
            join: { _ in }, isAlive: { _ in true },
            dial: { _ in Issue.record("the simulated SDK owns this establishment") },
            establish: { _, _, _, challenge, _ in
                try await handshake.establish(onPairingChallenge: challenge)
            })
        let port = NativeNikonPort(model: try #require(owner))
        let attempt = Task { @MainActor in
            try await port.connect(.saved(host: setup.host, path: .cameraAccessPoint))
        }
        defer {
            handshake.completeNativeRead()
            handshake.completeDecision()
            attempt.cancel()
            owner?.cancelConnectionAttempt()
        }
        for _ in 0..<200 where !handshake.entered { await Task.yield() }
        try #require(handshake.entered)
        try #require(handshake.hasPairingHandler)
        handshake.completeNativeRead()
        for _ in 0..<200 where handshake.accepted == nil { await Task.yield() }
        #expect(handshake.accepted == true, "the active owner's pairing policy is preserved")
        owner = nil
        #expect(released == nil)
        await #expect(throws: CancellationError.self) { _ = try await attempt.value }
        handshake.completeDecision()
    }

    @Test("A late native pairing challenge is rejected after its model is released")
    func latePairingAfterOwnerReleaseIsRejected() async throws {
        let handshake = PendingPairingHandshake()
        let setup = PTPIPSavedCameraRecord(
            host: "192.0.2.251", displayName: "SIMULATED ZR", transport: "Wi-Fi", lastSeenAt: nil,
            presentation: .init(customName: nil, wifiSSID: "NIKON_ZR_TEST"),
            pairedViaCameraAccessPoint: true, path: .cameraAccessPoint(ssid: "NIKON_ZR_TEST"))
        var owner: NativeAppModel? = NativeAppModel()
        weak var released = owner
        owner?.savedCameras = [setup]
        owner?.connectedWiFiSSID = nil
        owner?.cameraNetworkJoinPeers = .init(
            join: { _ in }, isAlive: { _ in true },
            dial: { _ in Issue.record("the simulated SDK owns this establishment") },
            establish: { _, _, _, challenge, _ in
                try await handshake.establish(onPairingChallenge: challenge)
            })
        let port = NativeNikonPort(model: try #require(owner))
        let attempt = Task { @MainActor in
            try await port.connect(.saved(host: setup.host, path: .cameraAccessPoint))
        }
        defer {
            handshake.completeNativeRead()
            attempt.cancel()
            owner?.cancelConnectionAttempt()
        }
        for _ in 0..<200 where !handshake.entered { await Task.yield() }
        try #require(handshake.entered, "the real connection must reach the SDK boundary")
        try #require(handshake.hasPairingHandler, "the real startup policy must supply pairing")
        owner = nil
        try #require(released == nil)
        await #expect(throws: CancellationError.self) { _ = try await attempt.value }

        // A native read can finish after Task.cancel. Deliver its actual callback from that
        // cancelled establishment task, rather than testing a detached policy helper.
        handshake.completeNativeRead()
        for _ in 0..<200 where handshake.accepted == nil { await Task.yield() }
        #expect(handshake.accepted == false, "a released model cannot approve late pairing")
    }

    @Test("A late saved-profile failure cannot start pairing after its model is released")
    func lateProfileFailureCannotEscalateAfterOwnerRelease() async throws {
        let handshake = PendingProfileFailure()
        let setup = PTPIPSavedCameraRecord(
            host: "192.0.2.248", displayName: "SIMULATED ZR", transport: "Wi-Fi", lastSeenAt: nil,
            presentation: .init(customName: nil, wifiSSID: "NIKON_ZR_TEST"),
            pairedViaCameraAccessPoint: true, path: .cameraAccessPoint(ssid: "NIKON_ZR_TEST"))
        let store = NativeCameraConnectionStore.shared
        try #require(!store.savedCameras().contains { $0.host == setup.host })
        try #require(!store.knownPairedCameras().contains { $0.host == setup.host })
        store.upsertSavedCamera(
            host: setup.host, displayName: setup.displayName, transport: setup.transport,
            onCameraAccessPoint: true, path: setup.path)
        defer { store.forgetKnownPairing(host: setup.host) }
        var owner: NativeAppModel? = NativeAppModel()
        weak var released = owner
        owner?.savedCameras = [setup]
        owner?.connectedWiFiSSID = nil
        owner?.cameraNetworkJoinPeers = .init(
            join: { _ in }, isAlive: { _ in true },
            dial: { _ in Issue.record("the simulated SDK owns this establishment") },
            establish: { _, _, pairing, _, _ in
                try await handshake.establish(requestPairing: pairing)
            })
        let port = NativeNikonPort(model: try #require(owner))
        let attempt = Task { @MainActor in
            try await port.connect(.saved(host: setup.host, path: .cameraAccessPoint))
        }
        defer {
            handshake.completeNativeRead()
            attempt.cancel()
            owner?.cancelConnectionAttempt()
        }
        for _ in 0..<200 where handshake.attempts == 0 { await Task.yield() }
        try #require(handshake.attempts == 1)
        try #require(handshake.firstRequestedPairing == false, "exercise the real saved profile")
        owner = nil
        try #require(released == nil)
        await #expect(throws: CancellationError.self) { _ = try await attempt.value }
        handshake.completeNativeRead()
        for _ in 0..<200 { await Task.yield() }
        #expect(handshake.readCompleted)
        #expect(handshake.attempts == 1, "an abandoned profile failure must not start pairing")
    }

    @MainActor
    private final class PendingProfileFailure {
        var attempts = 0
        var firstRequestedPairing: Bool?
        var readCompleted = false
        private var nativeRead: CheckedContinuation<Void, Never>?

        func establish(requestPairing: Bool) async throws -> NativeCameraSession {
            attempts += 1
            if attempts > 1 { throw CancellationError() }
            firstRequestedPairing = requestPairing
            // Native work already admitted can report an ordinary error after cancellation.
            await withCheckedContinuation { nativeRead = $0 }
            readCompleted = true
            throw NativeCameraSessionError.savedProfileRequired
        }

        func completeNativeRead() {
            let waiter = nativeRead
            nativeRead = nil
            waiter?.resume()
        }
    }

    @MainActor
    private final class PendingPairingHandshake {
        var entered = false
        var hasPairingHandler = false
        var accepted: Bool?
        private var nativeRead: CheckedContinuation<Void, Never>?
        private let holdAfterDecision: Bool
        private var decision: CheckedContinuation<Void, Never>?

        init(holdAfterDecision: Bool = false) {
            self.holdAfterDecision = holdAfterDecision
        }

        func establish(onPairingChallenge: NativePairingChallengeHandler?) async throws
            -> NativeCameraSession
        {
            entered = true
            hasPairingHandler = onPairingChallenge != nil
            // Intentionally not cancellation-aware, like a native read already in progress.
            await withCheckedContinuation { nativeRead = $0 }
            accepted = await onPairingChallenge?(
                PTPIPPairingChallenge(data: Data(), cameraName: "SIMULATED ZR"))
            if holdAfterDecision { await withCheckedContinuation { decision = $0 } }
            throw CancellationError()
        }

        func completeNativeRead() {
            let waiter = nativeRead
            nativeRead = nil
            waiter?.resume()
        }

        func completeDecision() {
            let waiter = decision
            decision = nil
            waiter?.resume()
        }
    }
}

/// FINAL-Z3-08: Cancel on the iOS "Wants to Join" alert is a "no" for the automatic re-offers
/// (reconnect, setup watch), never for the operator's own next Connect or Try again. Every peer is
/// SIMULATED: the join is the alert's answer, the dial is recorded and refused, no Wi-Fi changes.
@MainActor
@Suite("Camera access-point join decline")
struct CameraAccessPointJoinDeclineTests {
    private static let ssid = "NIKON_ZR_TEST"
    private static let host = "192.0.2.1"

    @MainActor
    private final class Peers {
        var events: [String] = []
        var answers: [Bool] = []
        var answersProbe = false

        func install(on model: NativeAppModel) {
            model.cameraNetworkJoinPeers = NativeAppModel.CameraNetworkJoinPeers(
                join: { [unowned self] target in
                    guard case .specificSSID(let ssid) = target else {
                        Issue.record("join target lost the saved SSID")
                        return
                    }
                    events.append("join:\(ssid)")
                    if !(answers.isEmpty ? true : answers.removeFirst()) {
                        throw WiFiJoinCoordinator.JoinError.userDenied
                    }
                },
                isAlive: { [unowned self] _ in answersProbe },
                dial: { [unowned self] host in events.append("dial:\(host)") })
        }
    }

    private func accessPointSetup() -> PTPIPSavedCameraRecord {
        PTPIPSavedCameraRecord(
            host: Self.host, displayName: "SIMULATED ZR", transport: "Wi-Fi", lastSeenAt: nil,
            presentation: PTPIPSavedCameraPresentation(customName: nil, wifiSSID: Self.ssid),
            pairedViaCameraAccessPoint: true, path: .cameraAccessPoint(ssid: Self.ssid))
    }

    private func model(_ peers: Peers, setup: PTPIPSavedCameraRecord) -> NativeAppModel {
        let model = NativeAppModel()
        model.savedCameras = [setup]
        model.connectedWiFiSSID = nil
        model.cameraHost = setup.host
        peers.install(on: model)
        return model
    }

    private func settle(_ model: NativeAppModel) async {
        for _ in 0..<300 {
            if !model.debugIsEstablishingConnection { return }
            try? await Task.sleep(for: .milliseconds(10))
        }
        Issue.record("the attempt never settled")
    }

    @Test("Cancel then an immediate Try again asks to join once more before any dial")
    func explicitRetryAfterDeclineAsksAgain() async throws {
        let peers = Peers()
        let setup = accessPointSetup()
        let model = model(peers, setup: setup)
        defer { model.cancelConnectionAttempt() }
        peers.answers = [false, true]
        peers.answersProbe = true

        model.connectSavedCamera(setup)
        await settle(model)
        #expect(peers.events == ["join:\(Self.ssid)"])
        #expect(model.connectionPhase == .failed)

        // The shared flow's Try again on the failed row.
        try model.runSharedConnect(.saved(host: Self.host, path: .cameraAccessPoint))
        await settle(model)
        #expect(
            peers.events == ["join:\(Self.ssid)", "join:\(Self.ssid)", "dial:\(Self.host)"],
            "exactly one more join request, and the dial only after it")
    }

    @Test("An automatic reconnect after a decline neither re-prompts nor dials off-network")
    func automaticReconnectAfterDeclineStaysQuiet() async {
        let peers = Peers()
        let setup = accessPointSetup()
        let model = model(peers, setup: setup)
        defer { model.cancelConnectionAttempt() }
        peers.answers = [false]

        model.connectSavedCamera(setup)
        await settle(model)

        // A setup watch or paired reconnect: the funnel without an operator tap.
        model.connectToCamera(setup: setup)
        await settle(model)
        #expect(peers.events == ["join:\(Self.ssid)"], "no second alert, no dial")
        #expect(model.connectionPhase == .failed)
        // The failed attempt restarts the discovery loop, which writes its own status into the
        // live `connectionMessage` ("Searching for cameras on Wi-Fi and USB-C..."); the failure
        // card reads the pinned `connectionFailureDetail` for exactly that reason. Give the loop
        // its window, then check the copy the operator actually sees.
        let decline = WiFiJoinCoordinator.JoinError.userDenied.errorDescription
        var waited = 0
        while model.connectionMessage == decline, waited < 300 {
            try? await Task.sleep(for: .milliseconds(10))
            waited += 1
        }
        #expect(model.connectionFailureDetail == decline)
        #expect(model.connectionPhase == .failed)
    }

    @Test("An automatic reconnect after a decline still dials a camera that already answers")
    func automaticReconnectDialsWhenOnTheCameraNetwork() async {
        let peers = Peers()
        let setup = accessPointSetup()
        let model = model(peers, setup: setup)
        defer { model.cancelConnectionAttempt() }
        peers.answers = [false]

        model.connectSavedCamera(setup)
        await settle(model)

        // The operator joined the camera's Wi-Fi in Settings; iOS 26 hides the SSID from us.
        peers.answersProbe = true
        model.connectToCamera(setup: setup)
        await settle(model)
        #expect(peers.events == ["join:\(Self.ssid)", "dial:\(Self.host)"])
    }
}

/// A refused camera Wi-Fi join shows the shared copy and the Settings fallback, never the
/// platform's developer text (JOIN-ERROR-COPY).
@MainActor
@Suite("Refused camera Wi-Fi join")
struct RefusedCameraWiFiJoinTests {
    @Test("A non-refusal failure replaces the previous refusal card and Settings action")
    func nonRefusalFailureReplacesPreviousRefusalCard() throws {
        let model = NativeAppModel()
        defer { model.cancelConnectionAttempt() }
        let refusal = CameraHotspotJoinRefusal(code: 8, network: "SIMULATED camera")
        model.surfaceCameraWiFiJoinFailure(refusal.message, refusal: refusal)
        let initialCard = NativeNikonPort.failure(
            model.lastConnectError, reason: model.lastConnectFailureReason,
            message: model.connectionFailureDetail)
        #expect(initialCard.message == refusal.message)
        #expect(initialCard.actions.contains(.openSettings))

        let message = "Joined the camera network but couldn't find the camera. Try again."
        model.surfaceCameraWiFiJoinFailure(message)
        let replacementCard = NativeNikonPort.failure(
            model.lastConnectError, reason: model.lastConnectFailureReason,
            message: model.connectionFailureDetail)
        #expect(model.lastConnectError == nil)
        #expect(replacementCard.message == message)
        #expect(!replacementCard.actions.contains(.openSettings))
        #expect(replacementCard.actions.contains(.retry))
    }

    @Test("A system refusal keeps the shared copy and offers Settings")
    func systemRefusalKeepsSharedCopy() throws {
        let refusal = CameraHotspotJoinRefusal(code: 8, network: "Z_6002199")
        guard case .refused(let typed) = WiFiJoinCoordinator.mapHotspotError(refusal) else {
            Issue.record("a typed refusal must stay typed")
            return
        }
        #expect(typed == refusal)
        let message = try #require(WiFiJoinCoordinator.JoinError.refused(refusal).errorDescription)
        #expect(message == refusal.message && !message.contains("internal"))
        let card = NativeNikonPort.failure(refusal, reason: .joinFailed, message: message)
        #expect(Array(card.actions.prefix(2)) == [.openSettings, .retry])
        #expect(card.message == refusal.message)
    }

    @Test("Cancel and an unusable network name keep their own cases")
    func declineAndInvalidNameKeepTheirCases() {
        guard
            case .userDenied = WiFiJoinCoordinator.mapHotspotError(
                CameraHotspotJoinRefusal(code: 7, network: "Z_6002199"))
        else {
            Issue.record("a declined join stays userDenied")
            return
        }
        guard
            case .invalidSSID = WiFiJoinCoordinator.mapHotspotError(
                CameraHotspotJoinRefusal(code: 1, network: ""))
        else {
            Issue.record("an invalid SSID stays invalidSSID")
            return
        }
    }
}

/// Hardware pass 4.1 (iPhone and Galaxy S25 on one Nikon ZR): after the Galaxy took the camera,
/// the iPhone showed "Camera taken over" while its old live-view pumps kept running on the dropped
/// link, and an in-place reconnect from them took the camera back three seconds later. The ZR hung
/// after the repeated hand-overs. A taken-over monitor retires its old link without a word to the
/// body and never dials. SIMULATED transport and virtual clock (`SessionRecoveryPeers`).
@MainActor
@Suite("Take-over recovery")
struct TakeOverRecoveryTests {
    @Test("A taken-over monitor retires the old link's pumps and never dials")
    func takenOverRetiresTheOldLinkAndNeverDials() async {
        let peer = SessionRecoveryPictureTests.Peer()
        peer.holder = "Galaxy S25"
        let model = NativeAppModel()
        model.cameraHost = "192.168.1.30"
        model.isMonitorPresented = true
        model.sessionRecoveryPeers = peer.peers
        let runtime = NikonMonitorRuntime(link: ParkedMonitorLink())
        model.debugAttachMonitorRuntime(runtime)
        defer { model.debugAttachMonitorRuntime(nil) }
        runtime.startKeepAlive(isBusy: { false }, failures: { _ in }, recover: {})
        runtime.startEventDrain(receive: { _ in }, unexpectedEnd: {})
        #expect(runtime.hasBackgroundPumps)

        model.debugSimulateTransportDetach()
        let stopped = await peer.drive(until: 30) {
            model.sessionRecovery == .takenOver(holder: "Galaxy S25")
        }

        #expect(stopped)
        #expect(peer.connects == 0, "a taken-over monitor never dials the camera")
        #expect(!runtime.hasBackgroundPumps, "nothing more goes over the dropped link")
        #expect(!model.sessionRecovery.claimsCamera)
        model.exitMonitorToOperatorMenu()
    }
}

/// A link whose pushed-event read parks until the runtime retires it.
@MainActor
private final class ParkedMonitorLink: NikonMonitorLink {
    let serialNumber = "SIMULATED"

    func supportsProperty(_ property: PTPPropertyCode) -> Bool { true }
    func configureLiveView(size: UInt8, compression: UInt8) async {}
    func startLiveView() async throws {}
    func stopLiveView() async {}
    func liveViewFrame(deadline: Duration?) async throws -> PTPLiveViewFrame {
        throw NativeCameraSessionError.connectionClosed
    }
    func readLastCommandRoundTripMilliseconds() -> Double? { nil }
    func sendKeepAlive() async throws {}
    func nextEvent() async throws -> PTPEvent {
        try await Task.sleep(for: .seconds(3_600))
        throw NativeCameraSessionError.connectionClosed
    }
    func pollStillReleaseReadiness() async throws -> StillReleaseReadiness { .complete }
    func shutdown() async {}
    func writeCameraProperty(_ write: PTPCameraPropertyWrite) async throws {}
    func readCameraProperty(_ property: PTPPropertyCode) async throws -> Data { Data() }
    func startRecording() async throws {}
    func stopRecording() async throws {}
}

/// Hardware pass 2026-10-28 (Nikon ZR, iOS 323): after a disconnect every connect sat on
/// "Starting live view" forever. The connect task ends at `enterLiveView` and releases the
/// single-flight latch there, and the watchdog's failure path required that latch, so the
/// 40 s "never started live view" budget could never end the attempt. SIMULATED transport that
/// answers the handshake and then never answers again; virtual watchdog clock, no real waits.
@MainActor
@Suite("Live view start budget")
struct LiveViewStartBudgetTests {
    private static let host = "usb:SIMULATED-live-view-stall"

    @Test("A connection that never starts live view fails after its budget and can be retried")
    func stalledLiveViewStartFailsWithRetry() async throws {
        let clock = WatchdogClock()
        let attempts = StalledAttempts()
        let model = NativeAppModel()
        model.connectionClock = clock.clock
        model.cameraHost = Self.host
        model.cameraNetworkJoinPeers = .init(
            join: { _ in }, isAlive: { _ in true },
            dial: { _ in Issue.record("the simulated SDK owns this establishment") },
            establish: { host, _, pairing, _, _ in
                // A fresh camera link per attempt, so a retry is seen reaching the SDK boundary.
                let transport = StallAfterHandshakeTransport()
                attempts.transports.append(transport)
                let session = try await NativeCameraSession.establish(
                    transport: transport, host: host, cameraName: "SIMULATED ZR",
                    requestPairing: pairing)
                // Everything after the handshake goes unanswered, like the field stall.
                await transport.stall()
                return session
            })
        defer {
            model.cancelConnectionAttempt()
            for transport in attempts.transports { transport.close() }
            clock.releaseAll()
            NativeCameraConnectionStore.shared.forgetKnownPairing(host: Self.host)
        }

        model.connectToCamera(operatorRequested: true)
        let preparing = await Self.until {
            model.connectionPhase == .preparingLiveView && !model.debugIsEstablishingConnection
        }
        try #require(preparing, "the real connect must reach live view with its latch released")
        try #require(model.debugHasCameraSession)
        #expect(NikonConnectFlow(model: model).phase == .preparingLiveView)
        let copy = CameraConnectionTimeout.timeoutMessage(
            phase: .preparingLiveView, deviceName: model.connectionProgressDeviceName)

        // Run the watchdog past the 40 s preparing-live-view budget, one 0.5 s tick at a time.
        for _ in 0..<84 {
            guard await Self.until({ clock.pendingSleeps > 0 }) else { break }
            clock.advance(by: .milliseconds(500))
        }
        _ = await Self.until { model.connectionPhase == .failed }

        #expect(model.connectionPhase == .failed)
        #expect(model.resolvedConnectionPhase == .failed)
        #expect(NikonConnectFlow(model: model).phase == .failed)
        // The failed card shows the detail; the resumed discovery loop owns `connectionMessage`.
        #expect(model.connectionFailureDetail == copy)
        #expect(!model.debugHasCameraSession, "the stalled session is released")

        // The failed card's Try again runs a fresh connection all the way to a new session.
        try #require(attempts.transports.count == 1)
        // A real link bounds the stalled session's CloseSession with a deadline; this fake has no
        // timer, so end that teardown the way its deadline would before the retry awaits it.
        attempts.transports[0].close()
        let generation = model.debugConnectionGeneration
        model.retryConnectionAttempt()
        #expect(model.debugConnectionGeneration > generation)
        // The retry settles before its fresh Init (a reconnect); step simulated time past it.
        func reopened() -> Bool {
            attempts.transports.count == 2 && model.debugHasCameraSession
                && model.connectionPhase == .preparingLiveView
        }
        // The watchdog always has a tick parked; the settle is the second sleeper.
        for _ in 0..<6 {
            guard await Self.until({ reopened() || clock.pendingSleeps >= 2 }), !reopened() else {
                break
            }
            clock.advance(by: .milliseconds(500))
        }
        let retried = await Self.until { reopened() }
        #expect(
            retried,
            """
            the retry reaches establishment again and opens a new session: \
            links \(attempts.transports.count) session \(model.debugHasCameraSession) \
            phase \(model.connectionPhase) establishing \(model.debugIsEstablishingConnection)
            """)
    }

    /// Yields until `condition` holds; the simulated work needs only main-actor and actor hops.
    private static func until(
        _ condition: @MainActor () -> Bool, yields: Int = 20_000
    ) async -> Bool {
        for _ in 0..<yields {
            if condition() { return true }
            await Task.yield()
        }
        return condition()
    }
}

/// The simulated camera links the connection opened, one per establishment.
@MainActor
private final class StalledAttempts {
    var transports: [StallAfterHandshakeTransport] = []
}

/// A manual `HostClock`: sleeps end only when the test advances time past them.
private final class WatchdogClock: @unchecked Sendable {
    private struct Sleeper {
        let id: Int
        let deadline: Duration
        let continuation: CheckedContinuation<Void, Error>
    }
    private let lock = NSLock()
    private var elapsed: Duration = .zero
    private var sleepers: [Sleeper] = []
    private var nextID = 0

    var clock: HostClock {
        HostClock(
            now: { [self] in MonotonicInstant(lock.withLock { elapsed }) },
            date: { Date(timeIntervalSinceReferenceDate: 0) },
            sleep: { [self] duration in try await sleep(for: duration) })
    }

    var pendingSleeps: Int { lock.withLock { sleepers.count } }

    func advance(by duration: Duration) {
        let due: [Sleeper] = lock.withLock {
            elapsed += duration
            let due = sleepers.filter { $0.deadline <= elapsed }
            sleepers.removeAll { $0.deadline <= elapsed }
            return due
        }
        for sleeper in due { sleeper.continuation.resume() }
    }

    func releaseAll() {
        let all = lock.withLock {
            let all = sleepers
            sleepers = []
            return all
        }
        for sleeper in all { sleeper.continuation.resume(throwing: CancellationError()) }
    }

    private func sleep(for duration: Duration) async throws {
        let id = lock.withLock {
            nextID += 1
            return nextID
        }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let cancelled = lock.withLock {
                    if Task.isCancelled { return true }
                    sleepers.append(
                        .init(id: id, deadline: elapsed + duration, continuation: continuation))
                    return false
                }
                if cancelled { continuation.resume(throwing: CancellationError()) }
            }
        } onCancel: {
            let sleeper = lock.withLock {
                let index = sleepers.firstIndex { $0.id == id }
                return index.map { sleepers.remove(at: $0) }
            }
            sleeper?.continuation.resume(throwing: CancellationError())
        }
    }
}

/// SIMULATED camera that completes the handshake, then leaves every later transaction and
/// event read unanswered until it is closed.
private actor StallAfterHandshakeTransport: CameraTransport {
    nonisolated let kind: CameraTransportKind = .usb
    private var stalled = false
    private var closed = false
    private var parked: [CheckedContinuation<Void, Never>] = []
    private let operations: [PTPOperationCode] = [
        .getDevicePropValue, .setDevicePropValue, .startLiveView, .endLiveView,
        .getLiveViewImageEx, .deviceReady,
    ]

    func stall() { stalled = true }

    func executeTransaction(
        operationCode: PTPOperationCode, transactionID: UInt32?, parameters: [UInt32],
        dataPhase: PTPDataPhase, dataOut: Data?, deadline: Duration?
    ) async throws -> PTPIPTransactionResult {
        if stalled { try await park() }
        let data = operationCode == .getDeviceInfo ? deviceInfo() : Data()
        let bytes =
            ByteCoding.uint16LE(PTPResponseCode.ok.rawValue)
            + ByteCoding.uint32LE(transactionID ?? 1)
        return PTPIPTransactionResult(
            operationResponse: try PTPOperationResponse(payloadBytes: bytes), data: data)
    }

    func nextEvent() async throws -> PTPEvent {
        try await park()
        throw NativeCameraSessionError.connectionClosed
    }

    nonisolated func close() { Task { await self.release() } }

    private func park() async throws {
        if !closed { await withCheckedContinuation { parked.append($0) } }
        throw NativeCameraSessionError.connectionClosed
    }

    private func release() {
        closed = true
        let waiting = parked
        parked = []
        for continuation in waiting { continuation.resume() }
    }

    private func string(_ value: String) -> [UInt8] {
        [UInt8(value.utf16.count + 1)] + value.utf16.flatMap { ByteCoding.uint16LE($0) } + [0, 0]
    }

    private func deviceInfo() -> Data {
        var bytes: [UInt8] = [100, 0, 10, 0, 0, 0, 100, 0, 0, 0, 0]
        bytes += ByteCoding.uint32LE(UInt32(operations.count))
        for operation in operations { bytes += ByteCoding.uint16LE(operation.rawValue) }
        for _ in 0..<4 { bytes += ByteCoding.uint32LE(0) }
        for value in ["SIMULATED", "SIMULATED ZR", "1.0", "SIMULATED-stall"] {
            bytes += string(value)
        }
        return Data(bytes)
    }
}
