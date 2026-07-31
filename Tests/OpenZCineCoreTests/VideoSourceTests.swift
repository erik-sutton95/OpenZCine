import Foundation
import Testing

@testable import OpenZCineCore

/// The picture source is independent of the control link, and the two combine into what the
/// monitor is allowed to claim. These are the combinations that reach an operator.
@Suite("Video source")
struct VideoSourceTests {

    /// The whole degradation story reduces to this one fact: only the camera's own stream carries
    /// the metadata header. Everything else in `MonitorDataAvailability` follows from it.
    @Test("Only the camera's own stream carries the frame header")
    func headerCarriage() {
        #expect(VideoSourceKind.cameraLiveView.carriesCameraFrameHeader)
        #expect(!VideoSourceKind.hdmiCapture.carriesCameraFrameHeader)
        // A relayed picture carries no header either — the host sends those readings separately,
        // which is why metadata availability is tracked apart from the picture source.
        #expect(!VideoSourceKind.relay.carriesCameraFrameHeader)
        #expect(VideoSourceKind.allCases.count == 3)
    }

    /// The hybrid case, and the reason the feature exists: the picture moves to HDMI and the
    /// camera stays fully controllable, because exposure arrives as PTP properties rather than in
    /// the frame header.
    @Test("HDMI keeps every control that PTP properties feed")
    func hybridKeepsControl() {
        let hybrid = MonitorDataAvailability(
            source: .hdmiCapture, ownsCameraSession: true, receivesCameraMetadata: true)
        #expect(hybrid.cameraControls)
        #expect(hybrid.recordControl)
        #expect(hybrid.mediaBrowser)
        #expect(hybrid.offersSourceSwitch)
    }

    /// The correction that matters most, and it was found by an operator rather than by me: the
    /// frame header is a PTP payload, so it follows the CONTROL link and not the picture. With a
    /// session up the app keeps pulling it (smallest frame the body offers, purely as a carrier)
    /// whatever is on screen, so switching the picture to HDMI costs NOTHING.
    ///
    /// Getting this wrong shipped an app-drawn rectangle standing in for the AF box: it looked
    /// real, tracked nothing, never went green, and no subject or eye detection ever appeared.
    @Test("A control session keeps every header-fed reading, on either picture source")
    func headerFollowsTheControlLinkNotThePicture() {
        for source in VideoSourceKind.allCases {
            let available = MonitorDataAvailability(
                source: source, ownsCameraSession: true, receivesCameraMetadata: true)
            #expect(available.focusBoxes)
            #expect(available.focusConfirmation)
            #expect(available.subjectDetectionBoxes)
            #expect(available.audioMeters)
            #expect(available.cameraTimecode)
            #expect(available.cameraLevel)
        }
    }

    /// A capture device with no camera behind it is the only case that truly loses the header —
    /// there is no PTP session to pull it from.
    @Test("With no session there is no header to pull, and nothing claims otherwise")
    func captureOnlyMonitorHasNoHeader() {
        let monitorOnly = MonitorDataAvailability(
            source: .hdmiCapture, ownsCameraSession: false, receivesCameraMetadata: false)
        #expect(!monitorOnly.focusBoxes)
        #expect(!monitorOnly.focusConfirmation)
        #expect(!monitorOnly.subjectDetectionBoxes)
        #expect(!monitorOnly.audioMeters)
        #expect(!monitorOnly.cameraTimecode)
        #expect(!monitorOnly.cameraLevel)
    }

    /// A capture device with no camera behind it: a monitor, and nothing that implies a camera is
    /// listening. Nothing here may be true, because there is no camera to make it true.
    @Test("A capture source with no session claims nothing about a camera")
    func monitorOnly() {
        let monitorOnly = MonitorDataAvailability(
            source: .hdmiCapture, ownsCameraSession: false, receivesCameraMetadata: false)
        #expect(!monitorOnly.cameraControls)
        #expect(!monitorOnly.recordControl)
        #expect(!monitorOnly.mediaBrowser)
        #expect(!monitorOnly.focusBoxes)
        #expect(!monitorOnly.audioMeters)
        #expect(!monitorOnly.cameraTimecode)
        #expect(!monitorOnly.cameraLevel)
        // Nothing to switch back to, so the source picker stays away.
        #expect(!monitorOnly.offersSourceSwitch)
    }

    /// Losing the control link must never leave control chrome behind, whichever source is up —
    /// the failure this guards is a live-looking ISO picker over a camera that cannot hear it.
    @Test("No control session means no control, on either source")
    func controlAlwaysFollowsTheSession() {
        for source in VideoSourceKind.allCases {
            let availability = MonitorDataAvailability(
                source: source, ownsCameraSession: false, receivesCameraMetadata: false)
            #expect(!availability.cameraControls)
            #expect(!availability.recordControl)
            #expect(!availability.focusBoxes)
        }
    }

    /// The bug this pins, found on hardware: HDMI streamed perfectly and not one camera control
    /// worked. The camera's frame loop hosts every control operation in its per-frame safe point —
    /// queued property writes, AF taps, record, still release, property polls — so standing it down
    /// for another picture source silently stands all of that down too. The chrome stays live and
    /// the writes queue forever.
    @Test("A source that stands the frame loop down must pump control itself")
    func controlPumpIsRequiredOffTheCameraStream() {
        let hybrid = MonitorDataAvailability(
            source: .hdmiCapture, ownsCameraSession: true, receivesCameraMetadata: true)
        #expect(hybrid.cameraControls)
        #expect(!hybrid.runsCameraFrameLoop)
        #expect(hybrid.requiresControlPump)

        // On the camera's own stream the loop is the pump, so a second one would double every
        // write and poll.
        let live = MonitorDataAvailability(
            source: .cameraLiveView, ownsCameraSession: true, receivesCameraMetadata: true)
        #expect(live.runsCameraFrameLoop)
        #expect(!live.requiresControlPump)
    }

    /// With no camera there is nothing to service, so neither the loop nor a pump should run —
    /// a pump against a session that doesn't exist would just spin.
    @Test("No control session means no frame loop and no pump")
    func noPumpWithoutASession() {
        for source in VideoSourceKind.allCases {
            let availability = MonitorDataAvailability(
                source: source, ownsCameraSession: false, receivesCameraMetadata: false)
            #expect(!availability.runsCameraFrameLoop)
            #expect(!availability.requiresControlPump)
        }
    }

    /// The blank state exists because `applyingCameraProperties` never falls back to a
    /// placeholder — it keeps whatever was already there. Starting from `preview` in a
    /// control-less session therefore renders a camera that isn't attached.
    /// A relay viewer is the case that forced `receivesCameraMetadata` to exist separately: the
    /// host forwards every reading it has, so the viewer's readouts, AF box, meters and horizon
    /// are all real — while it holds no session and must never offer to write to the camera.
    /// Collapsing the two would either blank a working monitor or offer it dead controls.
    @Test("A relay viewer shows every reading and offers no control")
    func relayViewer() {
        let viewer = MonitorDataAvailability(
            source: .relay, ownsCameraSession: false, receivesCameraMetadata: true)
        #expect(viewer.focusBoxes)
        #expect(viewer.focusConfirmation)
        #expect(viewer.subjectDetectionBoxes)
        #expect(viewer.audioMeters)
        #expect(viewer.cameraTimecode)
        #expect(viewer.cameraLevel)

        #expect(!viewer.cameraControls)
        #expect(!viewer.recordControl)
        #expect(!viewer.mediaBrowser)
        #expect(!viewer.offersSourceSwitch)
        // No session of its own, so nothing for a control pump to service.
        #expect(!viewer.runsCameraFrameLoop)
        #expect(!viewer.requiresControlPump)
    }

    /// Control is proxied, never transferred: the camera serves one initiator, so the host keeps
    /// the session and runs the holder's commands. A viewer holding the token therefore DRIVES the
    /// camera while owning no session at all — which is why the two are tracked apart.
    @Test("A viewer holding the token drives the camera without owning a session")
    func relayControlHolder() {
        let holder = MonitorDataAvailability(
            source: .relay, ownsCameraSession: false, receivesCameraMetadata: true,
            holdsRelayControl: true)
        #expect(holder.canDriveCamera)
        #expect(holder.cameraControls)
        #expect(holder.recordControl)
        // It still owns nothing: no frame loop, no control pump, and no media browser — card
        // operations are not proxied.
        #expect(!holder.ownsCameraSession)
        #expect(!holder.runsCameraFrameLoop)
        #expect(!holder.requiresControlPump)
        #expect(!holder.mediaBrowser)

        // The same viewer without the token watches and nothing more.
        let watcher = MonitorDataAvailability(
            source: .relay, ownsCameraSession: false, receivesCameraMetadata: true)
        #expect(!watcher.canDriveCamera)
        #expect(!watcher.cameraControls)
        #expect(!watcher.recordControl)
        // ...while still seeing everything the host forwards.
        #expect(watcher.focusBoxes)
        #expect(watcher.cameraTimecode)
    }

    @Test("The blank display state states nothing it cannot know")
    func blankDisplayState() {
        let blank = CameraDisplayState.blank
        #expect(blank.cameraName == CameraDisplayState.unavailableValue)
        #expect(blank.lens == CameraDisplayState.unavailableValue)
        #expect(blank.codec == CameraDisplayState.unavailableValue)
        #expect(blank.resolutionFrameRate == CameraDisplayState.unavailableValue)
        #expect(blank.cameraBatteryPercent == 0)
        #expect(blank.mediaStatus == nil)
        #expect(!blank.timecode.on)
        #expect(blank.recordState == .standby)

        // The strip keeps its five labels so the layout is unchanged, but no value pretends to be
        // a reading and none of them offer themselves as settable.
        #expect(blank.values.count == CameraDisplayState.preview.values.count)
        #expect(blank.values.map(\.label) == CameraDisplayState.preview.values.map(\.label))
        #expect(blank.values.allSatisfy { $0.value == CameraDisplayState.unavailableValue })
        #expect(blank.values.allSatisfy { !$0.isSettable })
    }

    /// The bug this guards: an empty snapshot applied over the fixture leaves the fixture intact,
    /// so a control-less monitor shows ISO 800 on a camera it has never spoken to.
    @Test("An empty property snapshot cannot resurrect the preview fixture")
    func blankSurvivesAnEmptySnapshot() {
        let applied = CameraDisplayState.blank.applyingCameraProperties(
            PTPCameraPropertySnapshot(), mediaStatus: nil)
        #expect(applied.values.allSatisfy { $0.value == CameraDisplayState.unavailableValue })
        #expect(applied.cameraName == CameraDisplayState.unavailableValue)

        // Contrast: the same empty snapshot over `preview` keeps every fixture value, which is
        // exactly why the blank state has to be the starting point rather than a gate.
        let fixture = CameraDisplayState.preview.applyingCameraProperties(
            PTPCameraPropertySnapshot(), mediaStatus: nil)
        #expect(fixture.values.first?.value == "800")
    }
}
