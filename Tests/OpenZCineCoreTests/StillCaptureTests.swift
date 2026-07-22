import Foundation
import OpenZCineCore
import Testing

@Suite("Still capture policy")
struct StillCaptureTests {
    @Test func liveViewSelectorDecodesPhotoAndVideo() {
        #expect(CameraCaptureSelector.decode(raw: 0) == .photo)
        #expect(CameraCaptureSelector.decode(raw: 1) == .video)
        #expect(CameraCaptureSelector.decode(raw: 2) == nil)
    }

    @Test func photographyChromeOnlyInPhotoMode() {
        #expect(StillCapturePolicy.prefersPhotographyChrome(selector: .photo))
        #expect(!StillCapturePolicy.prefersPhotographyChrome(selector: .video))
        #expect(!StillCapturePolicy.prefersPhotographyChrome(selector: nil))
    }

    @Test func driveModesLabelHighSpeedVariants() {
        #expect(StillDriveMode.single.label == "Single")
        #expect(StillDriveMode.highSpeedFrameC30.label == "C30")
        #expect(StillDriveMode.decode(raw: 0x811E) == .highSpeedFrameC30)
        #expect(StillDriveMode.decode(raw: 0xFFFF) == nil)
    }

    @Test func captureOperationMatchesDestination() {
        #expect(StillCapturePolicy.captureOperation(destination: .card) == .initiateCapture)
        #expect(
            StillCapturePolicy.captureOperation(destination: .media)
                == .initiateCaptureRecInMedia)
        #expect(
            StillCapturePolicy.captureOperation(destination: .sdram)
                == .initiateCaptureRecInSdram)
    }

    @Test func snapshotAppliesLiveViewSelectorAndDriveMode() {
        var snap = PTPCameraPropertySnapshot()
        snap = snap.applying(property: .liveViewSelector, data: Data([0]))
        #expect(snap.captureSelector == .photo)
        snap = snap.applying(property: .liveViewSelector, data: Data([1]))
        #expect(snap.captureSelector == .video)

        // StillCaptureMode Continuous L = 0x8010 little-endian
        snap = snap.applying(
            property: .stillCaptureMode,
            data: Data([0x10, 0x80]))
        #expect(snap.stillCaptureMode == "Continuous L")
    }

    @Test func photoPollOrderIncludesSelectorAndDrive() {
        #expect(StillCapturePolicy.photoMonitorPollOrder.contains(.liveViewSelector))
        #expect(StillCapturePolicy.photoMonitorPollOrder.contains(.stillCaptureMode))
        #expect(StillCapturePolicy.photoMonitorPollOrder.contains(.compressionSetting))
        #expect(PTPPropertyCode.liveMonitorPollOrder.contains(.liveViewSelector))
    }
}
