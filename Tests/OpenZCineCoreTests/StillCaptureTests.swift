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
        // Quick-setting dial position (bodies with a release-mode dial).
        snap = snap.applying(property: .stillCaptureMode, data: Data([0x00, 0x81]))
        #expect(snap.stillCaptureMode == "Quick")
    }

    @Test func snapshotDecodesStillsValueSpaces() {
        var snap = PTPCameraPropertySnapshot()

        // 0xD061 is UINT8 0/1/4/5 — not the 0x500A UINT16 space.
        snap = snap.applying(property: .stillFocusMode, data: Data([1]))
        #expect(snap.focusMode == "AF-C")
        snap = snap.applying(property: .stillFocusMode, data: Data([5]))
        #expect(snap.focusMode == "AF-A")
        snap = snap.applying(property: .focusMode, data: Data(ByteCoding.uint16LE(0x8010)))
        #expect(snap.focusMode == "AF-S")

        // Fraction-packed stills shutter including the mode-M open-shutter sentinels.
        snap = snap.applying(
            property: .stillShutterSpeed, data: Data(ByteCoding.uint32LE(0x0001_00C8)))
        #expect(snap.shutterSpeed == "1/200")
        snap = snap.applying(
            property: .stillShutterSpeed, data: Data(ByteCoding.uint32LE(0xFFFF_FFFF)))
        #expect(snap.shutterSpeed == "Bulb")
        snap = snap.applying(
            property: .stillShutterSpeed, data: Data(ByteCoding.uint32LE(0xFFFF_FFFD)))
        #expect(snap.shutterSpeed == "Time")

        // Flash 0x8010 is the plain fill mode; metering 0x8010 is highlight-weighted.
        snap = snap.applying(property: .flashMode, data: Data(ByteCoding.uint16LE(0x8010)))
        #expect(snap.flashMode == "Fill")
        snap = snap.applying(
            property: .exposureMeteringMode, data: Data(ByteCoding.uint16LE(0x8010)))
        #expect(snap.meteringMode == "Highlight")

        // Compression 7 is RAW; 4 is JPEG Fine.
        snap = snap.applying(property: .compressionSetting, data: Data([7]))
        #expect(snap.compression == "RAW")
        snap = snap.applying(property: .compressionSetting, data: Data([4]))
        #expect(snap.compression == "JPEG Fine")
    }

    @Test func photoPollOrderIncludesSelectorAndDrive() {
        #expect(StillCapturePolicy.photoMonitorPollOrder.contains(.liveViewSelector))
        #expect(StillCapturePolicy.photoMonitorPollOrder.contains(.stillCaptureMode))
        #expect(StillCapturePolicy.photoMonitorPollOrder.contains(.compressionSetting))
        #expect(PTPPropertyCode.liveMonitorPollOrder.contains(.liveViewSelector))
    }

    @Test func modeSelectorInterleavesEveryOtherPollTick() {
        // Even ticks force LiveViewSelector so photo/video chrome flips quickly.
        #expect(
            CameraMonitorPollPolicy.nextProperty(pollIndex: 0, isRecording: false)
                == .liveViewSelector)
        #expect(
            CameraMonitorPollPolicy.nextProperty(pollIndex: 2, isRecording: false)
                == .liveViewSelector)
        let odd0 = CameraMonitorPollPolicy.nextProperty(pollIndex: 1, isRecording: false)
        let odd1 = CameraMonitorPollPolicy.nextProperty(pollIndex: 3, isRecording: false)
        #expect(odd0 != .liveViewSelector)
        #expect(odd1 != .liveViewSelector)
        #expect(odd0 != odd1)

        // Recording keeps the compact health set only (no selector interleave).
        #expect(
            CameraMonitorPollPolicy.nextProperty(pollIndex: 0, isRecording: true) == .batteryLevel)
        #expect(
            CameraMonitorPollPolicy.nextProperty(pollIndex: 1, isRecording: true) == .acPower)

        // Photo chrome still interleaves selector while walking stills properties.
        let photoOdd = CameraMonitorPollPolicy.nextProperty(
            pollIndex: 1, isRecording: false, captureSelector: .photo)
        #expect(photoOdd != .liveViewSelector)
        #expect(
            StillCapturePolicy.photoMonitorPollOrder.filter { $0 != .liveViewSelector }
                .contains(photoOdd))
    }

    @Test func stringEnumDescriptorParsesAndRanksSizeClasses() {
        // A String-typed descriptor dataset: code, type 0xFFFF, get/set, default + current
        // strings, enum form with three resolution strings.
        var bytes: [UInt8] = [0x03, 0x50, 0xFF, 0xFF, 0x01]
        let sizes = ["6048x4032", "4528x3016", "3024x2016"]
        bytes += Array(PTPCameraPropertyDecoders.ptpStringData(sizes[0]))  // factory default
        bytes += Array(PTPCameraPropertyDecoders.ptpStringData(sizes[0]))  // current
        bytes += [0x02, 0x03, 0x00]
        for size in sizes {
            bytes += Array(PTPCameraPropertyDecoders.ptpStringData(size))
        }
        let options = PTPCameraPropertyDecoders.devicePropDescStringEnumValues(data: Data(bytes))
        #expect(options == sizes)

        // Rank order comes from pixel count, not list order.
        var snap = PTPCameraPropertySnapshot()
        snap = snap.applying(
            property: .imageSize, data: PTPCameraPropertyDecoders.ptpStringData("4528x3016"))
        #expect(snap.stillSizeClassLabel(options: sizes.shuffled()) == "M")
        snap = snap.applying(property: .captureAreaCrop, data: Data([5]))
        #expect(snap.stillSizeAreaLabel(sizeOptions: sizes) == "16:9 · M")

        // Unknown domain or off-domain value never leaks a raw resolution into the pill.
        #expect(snap.stillSizeClassLabel(options: []) == nil)
        #expect(snap.stillSizeAreaLabel(sizeOptions: []) == "16:9")
    }

    @Test func qualityConfigurationRoundTripsEveryCompressionCode() {
        // Every writable code decomposes into the drum pair and composes back to itself.
        let writable: [UInt8] = Array(0...5) + [7] + Array(8...13)
        for code in writable {
            let config = StillQualityConfiguration.decode(compressionCode: code)
            #expect(config?.compressionCode == code)
        }
        // TIFF is unrepresentable in the pair.
        #expect(StillQualityConfiguration.decode(compressionCode: 6) == nil)
        // Both halves off is unwritable.
        #expect(
            StillQualityConfiguration(rawEnabled: false, tier: .off, starred: false)
                .compressionCode == nil)
        // Spot-check the doc ladder: RAW+Normal★ and JPEG Fine.
        #expect(
            StillQualityConfiguration(rawEnabled: true, tier: .normal, starred: true)
                .compressionLabel == "RAW+JPEG Normal★")
        #expect(
            StillQualityConfiguration(rawEnabled: false, tier: .fine, starred: false)
                .compressionLabel == "JPEG Fine")
    }
}
