import Testing

@testable import Runner

/// Who answers the Record Confirmation prompt, when a second device is driving the camera.
///
/// The field report behind this: a watcher was granted control, its record button was live, and
/// pressing it did nothing at all. The preference is on by default, so this is what every pair of
/// devices hit on the first take.
@Suite("Relayed record control")
struct RelayRecordControlTests {

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
