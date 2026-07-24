import OpenZCineCore
import Testing

@testable import OpenZCineAndroidFacade

struct AndroidCameraControlWireTests {
    @Test func mapsEverySupportedSemanticSelectorWithoutPropertyBytes() {
        #expect(AndroidCameraControlWire.control(selector: 0) == .iso)
        #expect(AndroidCameraControlWire.control(selector: 1) == .shutter)
        #expect(AndroidCameraControlWire.control(selector: 2) == .iris)
        #expect(AndroidCameraControlWire.control(selector: 3) == .whiteBalance)
        #expect(AndroidCameraControlWire.control(selector: 4) == .focusMode)
        #expect(AndroidCameraControlWire.control(selector: 5) == .focusArea)
        #expect(AndroidCameraControlWire.control(selector: 6) == .focusSubject)
        #expect(AndroidCameraControlWire.control(selector: 7) == .exposureMode)
        #expect(AndroidCameraControlWire.control(selector: 8) == .audioSensitivity)
        #expect(AndroidCameraControlWire.control(selector: 9) == .audioInput)
        #expect(AndroidCameraControlWire.control(selector: 10) == .windFilter)
        #expect(AndroidCameraControlWire.control(selector: 11) == .attenuator)
        #expect(AndroidCameraControlWire.control(selector: 12) == .audio32BitFloat)
        #expect(AndroidCameraControlWire.control(selector: 13) == .baseISO)
        #expect(AndroidCameraControlWire.control(selector: 14) == .shutterMode)
        #expect(AndroidCameraControlWire.control(selector: 15) == .shutterLock)
        #expect(AndroidCameraControlWire.control(selector: 16) == .whiteBalanceTint)
        #expect(AndroidCameraControlWire.control(selector: 17) == .resolutionFrameRate)
        #expect(AndroidCameraControlWire.control(selector: 18) == .codec)
        #expect(AndroidCameraControlWire.control(selector: 19) == .vibrationReduction)
        #expect(AndroidCameraControlWire.control(selector: 20) == .electronicVR)
        #expect(AndroidCameraControlWire.control(selector: 21) == .isoAuto)
        #expect(AndroidCameraControlWire.control(selector: 22) == .stillISO)
        #expect(AndroidCameraControlWire.control(selector: 23) == .stillISOAuto)
        #expect(AndroidCameraControlWire.control(selector: 24) == .stillShutter)
        #expect(AndroidCameraControlWire.control(selector: 25) == .stillIris)
        #expect(AndroidCameraControlWire.control(selector: 26) == .stillDrive)
        #expect(AndroidCameraControlWire.control(selector: 27) == .stillFocusMode)
        #expect(AndroidCameraControlWire.control(selector: 28) == .stillFocusArea)
        #expect(AndroidCameraControlWire.control(selector: 29) == .stillFocusSubject)
        #expect(AndroidCameraControlWire.control(selector: 30) == .stillMeter)
        #expect(AndroidCameraControlWire.control(selector: 31) == .stillImageArea)
        #expect(AndroidCameraControlWire.control(selector: 32) == .stillImageSize)
        #expect(AndroidCameraControlWire.control(selector: 33) == .stillQuality)
        #expect(AndroidCameraControlWire.control(selector: 34) == .stillRawCompression)
        #expect(AndroidCameraControlWire.control(selector: 35) == .stillUserModeProgram)
        #expect(AndroidCameraControlWire.control(selector: 36) == .stillPictureControl)
        #expect(AndroidCameraControlWire.control(selector: -1) == nil)
        #expect(AndroidCameraControlWire.control(selector: 37) == nil)
    }

    @Test func photoModeSeedsAndPollsTheStillsPropertySet() {
        // Connect-in-photo (and every photo flip) must burst the stills set —
        // aperture, metering, shots remaining — not the movie order the body
        // leaves empty in photo mode.
        let photoOrder = PTPIPClientSession.androidBootstrapPollOrder(captureSelector: .photo)
        #expect(photoOrder == StillCapturePolicy.photoMonitorPollOrder)
        #expect(photoOrder.contains(.fNumber))
        #expect(photoOrder.contains(.exposureMeteringMode))
        #expect(photoOrder.contains(.exposureRemaining))
        #expect(
            PTPIPClientSession.androidBootstrapPollOrder(captureSelector: .video)
                == PTPIPClientSession.androidMonitorPollOrder(isRecording: false))
    }

    @Test func photoModeDescriptorRoutingTargetsTheStillsProperties() {
        // The aperture enum for the mounted lens comes from the STANDARD
        // aperture property while the photo selector is active — the movie
        // enum is not authoritative there (iOS refreshLensApertures).
        #expect(
            PTPIPClientSession.apertureDescriptorProperty(captureSelector: .photo)
                == .fNumber)
        #expect(
            PTPIPClientSession.apertureDescriptorProperty(captureSelector: .video)
                == .movieFNumber)
        #expect(
            PTPIPClientSession.apertureDescriptorProperty(captureSelector: nil)
                == .movieFNumber)
        // The photo option enums pin to their stills properties.
        #expect(PTPIPClientSession.stillShutterOptionsProperty == .stillShutterSpeed)
        #expect(PTPIPClientSession.stillWhiteBalanceOptionsProperty == .whiteBalance)
        #expect(PTPIPClientSession.stillImageSizeOptionsProperty == .imageSize)
    }

    @Test func modeFlipBurstDrainsInBoundedChunks() {
        // The flip queue must span several ticks (frames interleave between
        // them) rather than one blocking burst: chunk < the photo set size,
        // and big enough that a few fast polls land the whole set.
        let chunk = PTPIPClientSession.androidModeFlipBurstChunk
        #expect(chunk >= 4)
        #expect(chunk < StillCapturePolicy.photoMonitorPollOrder.count)
    }

    @Test func stillControlsSkipCapabilityValidationAndMapSharedEncoders() {
        for control in [
            AndroidCameraControl.stillISO, .stillISOAuto, .stillShutter, .stillIris,
            .stillDrive, .stillFocusMode, .stillFocusArea, .stillFocusSubject, .stillMeter,
            .stillImageArea, .stillImageSize, .stillQuality, .stillRawCompression,
            .stillUserModeProgram, .stillPictureControl,
        ] {
            #expect(control.isStillControl)
            #expect(!control.requiresCapabilityValidation)
        }
        #expect(AndroidCameraControl.stillISO.sharedControl == .stillISO)
        #expect(AndroidCameraControl.stillFocusMode.sharedControl == .stillFocus)
        #expect(AndroidCameraControl.stillQuality.sharedControl == .stillQuality)
        // Session-local byte writes carry no shared label encoder.
        #expect(AndroidCameraControl.stillISOAuto.sharedControl == nil)
        #expect(AndroidCameraControl.stillImageArea.sharedControl == nil)
        // The shared-core stills model round-trips into the Android superset.
        #expect(AndroidCameraControl(PTPCameraControl.stillFocus) == .stillFocusMode)
        #expect(AndroidCameraControl(PTPCameraControl.stillPictureControl) == .stillPictureControl)
        #expect(AndroidCameraControl(PTPCameraControl.stillFlash) == nil)
    }
}
