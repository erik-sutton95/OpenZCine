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
                sleep: { [unowned self] in try await pause($0) })
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
