import Foundation
import OpenCineCore
import OpenCineRelay
import OpenZCineCore
import Testing

@testable import Runner

/// Who answers the Record Confirmation prompt, when a second device is driving the camera.
///
/// The field report behind this: a watcher was granted control, its record button was live, and
/// pressing it did nothing at all. The preference is on by default, so this is what every pair of
/// devices hit on the first take.
@Suite("Relayed record control")
struct RelayRecordControlTests {

    /// SIMULATED real app Watch entry and actual Nikon common-session queue, not a recording pin.
    @MainActor
    @Test func watchAcceptsActualRecordSubmissionBeforeAnyRecordingObservation() async throws {
        let model = NativeAppModel()
        let transport = LargeTransferTransport(operations: [])
        let native = try await NativeCameraSession.establish(
            transport: transport,
            host: "usb:SIMULATED-watch", cameraName: "SIMULATED", requestPairing: false)
        defer {
            model.shell.close()
            model.debugAdoptEstablishedMediaSession(nil)
            native.close()
        }
        model.debugAdoptEstablishedMediaSession(native)
        model.isMonitorPresented = true
        let driver = WatchRecordDriver(recording: false)
        let common = NikonCameraSession(driver: driver, serialNumber: "SIMULATED-WATCH")
        model.shell.control.bind(common)
        for _ in 0..<2_000 {
            if model.shell.control.recordEditor() != nil { break }
            await Task.yield()
        }
        #expect(model.shell.control.recordEditor() != nil)
        let answer = model.watchToggleRecord()
        #expect(answer.accepted && !answer.isRecording)
        for _ in 0..<2_000 {
            if !driver.records.isEmpty { break }
            await Task.yield()
        }
        #expect(
            driver.records == [true], "The actual integration queue must receive the explicit start"
        )
        #expect(!model.isRecording, "Acceptance must not depend on an optimistic lamp change")
    }

    /// SIMULATED identical displayed facts retain two distinct actual native owners.
    @MainActor
    @Test func watchShownOwnerRefusesReplacementBeforePublication() async throws {
        let model = NativeAppModel()
        let first = try await NativeCameraSession.establish(
            transport: LargeTransferTransport(operations: [.initiateCapture]),
            host: "usb:SIMULATED-watch-first", cameraName: "SIMULATED", requestPairing: false)
        let replacement = try await NativeCameraSession.establish(
            transport: LargeTransferTransport(operations: [.initiateCapture]),
            host: "usb:SIMULATED-watch-replacement", cameraName: "SIMULATED", requestPairing: false)
        defer {
            model.shell.close()
            model.debugAdoptEstablishedMediaSession(nil)
            first.close()
            replacement.close()
        }
        model.debugAdoptEstablishedMediaSession(first)
        model.applyDemoProperty(.liveViewSelector, data: Data([0]))
        model.isMonitorPresented = true
        model.activateWatchRelay()
        let shownState = model.currentWatchRelayState()
        let (phone, receipt) = try watchReceipt()
        defer { phone.close() }
        model.debugAdoptEstablishedMediaSession(replacement)
        #expect(
            model.currentWatchRelayState() == shownState,
            "Names and displayed facts must not substitute for owner identity")
        #expect(
            receipt.isCurrent && first.commandOwner?.isActive == true
                && replacement.commandOwner?.isActive == true)
        let refused = try #require(model.watchRelay.onAdmittedCapture?(receipt))
        #expect(
            !refused.accepted, "A late press must not borrow the replacement before publication")
        #expect(!model.isStillCapturing, "No replacement still operation may be queued")
        model.publishWatchState()
        let (replacementPhone, replacementReceipt) = try watchReceipt()
        defer { replacementPhone.close() }
        let accepted = try #require(model.watchRelay.onAdmittedCapture?(replacementReceipt))
        #expect(
            accepted.accepted && model.isStillCapturing,
            "The newly published active owner admits its own actual still queue")
    }

    /// SIMULATED actual native still queue; acceptance does not claim a camera ACK.
    @MainActor
    @Test func watchAcceptsAStillQueuedThroughTheActualAppCapturePath() async throws {
        let model = NativeAppModel()
        let transport = LargeTransferTransport(operations: [.initiateCapture])
        let native = try await NativeCameraSession.establish(
            transport: transport,
            host: "usb:SIMULATED-watch-photo", cameraName: "SIMULATED", requestPairing: false)
        defer {
            model.shell.close()
            model.debugAdoptEstablishedMediaSession(nil)
            native.close()
        }
        model.debugAdoptEstablishedMediaSession(native)
        model.applyDemoProperty(.liveViewSelector, data: Data([0]))
        model.isMonitorPresented = true
        model.activateWatchRelay()
        let (phone, receipt) = try watchReceipt()
        defer { phone.close() }
        let answer = try #require(model.watchRelay.onAdmittedCapture?(receipt))
        #expect(answer.accepted && model.isStillCapturing)
        #expect(
            !model.watchCapture().accepted, "An existing still operation refuses another release")
    }

    @MainActor
    @Test func watchRefusesNilRecordCommandAndRetiredNativeOrWatchAuthority() async throws {
        let model = NativeAppModel()
        let transport = LargeTransferTransport(operations: [])
        let native = try await NativeCameraSession.establish(
            transport: transport,
            host: "usb:SIMULATED-watch-nil", cameraName: "SIMULATED", requestPairing: false)
        defer {
            model.shell.close()
            model.debugAdoptEstablishedMediaSession(nil)
            native.close()
        }
        model.debugAdoptEstablishedMediaSession(native)
        model.isMonitorPresented = true
        let driver = WatchRecordDriver(recording: nil)
        let common = NikonCameraSession(driver: driver, serialNumber: "SIMULATED-WATCH-NIL")
        model.shell.control.bind(common)
        for _ in 0..<2_000 {
            if model.shell.control.snapshot?.session == common.id { break }
            await Task.yield()
        }
        #expect(model.shell.control.recordEditor() == nil)
        #expect(!model.watchToggleRecord().accepted)
        model.activateWatchRelay()
        let (phone, receipt) = try watchReceipt()
        defer { phone.close() }
        phone.retireSource()
        #expect(model.watchRelay.onAdmittedToggleRecord?(receipt).accepted == false)
        native.commandOwner?.retire()
        let (otherPhone, otherReceipt) = try watchReceipt()
        defer { otherPhone.close() }
        #expect(model.watchRelay.onAdmittedCapture?(otherReceipt).accepted == false)
        #expect(driver.records.isEmpty)
    }

    @MainActor
    @Test func watchRefusesDisconnectedUnsupportedLockedOrSurrenderedShutters() {
        let model = NativeAppModel()
        model.applyDemoProperty(.liveViewSelector, data: Data([0]))
        #expect(
            !model.watchCapture().accepted,
            "A photo selector is not a live camera or a dispatched still")
        model.isDemoSession = true
        model.isMonitorPresented = true
        #expect(!model.watchToggleRecord().accepted, "Photo mode must refuse video recording")
        model.applyDemoProperty(.liveViewSelector, data: Data([1]))
        #expect(!model.watchCapture().accepted)
        model.interfaceLocked = true
        #expect(!model.watchToggleRecord().accepted)
        model.interfaceLocked = false
        model.isRelayBroadcasting = true
        model.relayControlHeldBy = "SIMULATED-WATCHER"
        #expect(!model.watchToggleRecord().accepted)
        #expect(!model.isRecording && !model.isStillCapturing)
        model.isMonitorPresented = false
    }

    @MainActor
    private func watchReceipt() throws -> (
        RelayWatchPhoneOwner<WatchRelayCodec, Int>, RelayWatchCommandAdmission
    ) {
        let phone = RelayWatchPhoneOwner<WatchRelayCodec, Int>(
            codec: WatchRelayCodec(),
            policy: .init(
                pacing: .init(
                    profiles: [.init(maximumWidth: 256, qualityPercent: 24)],
                    roundTripThresholds: [], initialIndex: 0), stateDelivery: .reachableMessage,
                releasesOutstandingOnRetirement: true), now: { 0 }, send: { _, _, _ in },
            encode: { _, _ in nil })
        var captured: RelayWatchCommandAdmission?
        phone.onAdmittedCommand = { _, receipt in
            captured = receipt
            return OpenCineRelay.WatchCommandResult(accepted: true, isRecording: false, error: nil)
        }
        phone.acceptLink(activated: true, reachable: true)
        _ = phone.receiveCommand(
            try RelayWatchEnvelope.encode(OpenCineRelay.WatchRelayCommand.capture, kind: .command),
            source: phone.source)
        return (phone, try #require(captured))
    }

    /// The watcher's own press must reach the relay send. It has no camera session by design — it
    /// drives the camera by asking the host to — so the owned-session pre-flight is not its gate.
    /// Refusing there swallowed the press before the send, with a message the watcher never shows.
    @MainActor
    @Test("A watcher holding control confirms its own record press instead of being refused")
    func watcherRecordPressRaisesItsOwnConfirmation() {
        let model = NativeAppModel()
        // Set rather than trust: `NativeAppModel()` loads the persisted preferences, so a stored
        // value from a previous run would decide the outcome instead of the default.
        model.preferences = OperatorPreferences.defaults
        #expect(model.preferences.recordConfirmationEnabled, "the default this bug rides on")
        model.videoSource = .relay
        model.relayHoldsControl = true
        #expect(
            model.monitorAvailability.recordControl, "a control holder mounts the record button")

        model.toggleRecording()

        // The prompt the watcher answers is the alert mounted on that record button.
        #expect(model.pendingRecordConfirmation == true)

        model.confirmRecordToggle()
        #expect(model.pendingRecordConfirmation == nil, "the answer is consumed, not left pending")
    }

    /// The answer runs the target the prompt asked about. It used to recompute `!isRecording` on
    /// confirm, so a take the camera started while "Start recording?" was up was stopped by the
    /// operator's "Start" (and the reverse for "Stop").
    @MainActor
    @Test("Confirming runs the asked target even when the camera changed state meanwhile")
    func confirmedTargetIsHonored() {
        let model = NativeAppModel()
        model.preferences = OperatorPreferences.defaults
        model.isDemoSession = true

        model.toggleRecording()
        #expect(model.pendingRecordConfirmation == true)
        // The take starts on the body while the prompt is still up.
        model.isRecording = true
        model.confirmRecordToggle()

        #expect(model.isRecording, "the confirmed start must not become a stop")
        #expect(model.pendingRecordConfirmation == nil)
    }

    /// The other half of the same rule, from the local side: a press on a device that would have to
    /// drive its OWN camera is still refused without a session. Nothing here loosens that.
    @MainActor
    @Test("A local press with no camera session is still refused")
    func localRecordPressWithoutASessionIsStillRefused() {
        let model = NativeAppModel()
        model.preferences = OperatorPreferences.defaults

        model.toggleRecording()

        #expect(model.pendingRecordConfirmation == nil)
        #expect(!model.isRecording)
    }
}

/// SIMULATED safe-point queue implementing the actual Nikon integration driver contract.
@MainActor private final class WatchRecordDriver: NikonControlDriver {
    var nikonControlFacts: NikonControlFacts
    var records: [Bool] = []
    init(recording: Bool?) {
        nikonControlFacts = .init(
            liveViewReady: true,
            reported: PTPCameraPropertySnapshot(captureSelector: .video), recording: recording)
    }
    func queueSettingWrites(
        _ label: String, for setting: NikonControlSetting, operation: OperationID?
    ) -> Int { 0 }
    func queueRecord(start: Bool, operation: OperationID) { records.append(start) }
}
