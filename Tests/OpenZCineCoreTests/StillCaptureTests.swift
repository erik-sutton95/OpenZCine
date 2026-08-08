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

    @Test("Picture-control bands decode built-ins, creatives, customs, and cloud slots")
    func pictureControlBands() {
        #expect(PTPCameraPropertyDecoders.pictureControl(8) == "Auto")
        #expect(PTPCameraPropertyDecoders.pictureControl(120) == "Carbon")
        #expect(PTPCameraPropertyDecoders.pictureControl(201) == "Custom 1")
        // Downloaded profiles occupy the cloud band — 0x131 is slot 5, not a hex fallback.
        #expect(PTPCameraPropertyDecoders.pictureControl(305) == "Cloud 5")
        #expect(PTPCameraPropertyDecoders.pictureControlCode(for: "Cloud 5") == 305)
        #expect(PTPCameraPropertyDecoders.pictureControl(310) == "0x136")
    }

    @Test("Stills tone mode fills the snapshot and defaults to SDR")
    func stillToneModeDecode() {
        var snap = PTPCameraPropertySnapshot()
        #expect(snap.stillToneMode == nil)
        snap = snap.applying(property: .stillToneMode, data: Data([2]))
        #expect(snap.stillToneMode == "HLG")
        snap = snap.applying(property: .stillToneMode, data: Data([0]))
        #expect(snap.stillToneMode == "SDR")
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
        // Spot-check the ladder: RAW+Normal★ and JPEG Fine.
        #expect(
            StillQualityConfiguration(rawEnabled: true, tier: .normal, starred: true)
                .compressionLabel == "RAW+JPEG Normal★")
        #expect(
            StillQualityConfiguration(rawEnabled: false, tier: .fine, starred: false)
                .compressionLabel == "JPEG Fine")
    }

    @Test func ratingStepsMapStarsBothWays() {
        #expect(StillCapturePolicy.ratingValue(forStars: 0) == 0)
        #expect(StillCapturePolicy.ratingValue(forStars: 1) == 1)
        #expect(StillCapturePolicy.ratingValue(forStars: 3) == 50)
        #expect(StillCapturePolicy.ratingValue(forStars: 5) == 100)
        #expect(StillCapturePolicy.ratingValue(forStars: 9) == 100)  // clamps
        for stars in 0...5 {
            #expect(
                StillCapturePolicy.stars(
                    fromRatingValue: StillCapturePolicy.ratingValue(forStars: stars)) == stars)
        }
        // Off-step values round down, like the body.
        #expect(StillCapturePolicy.stars(fromRatingValue: 60) == 3)
        #expect(StillCapturePolicy.stars(fromRatingValue: 24) == 1)
    }

    @Test func afSVideoTapDrivesAutofocusButContinuousDoesNot() {
        // #272: a video AF-S body has no continuous loop, so moving the box must be followed by
        // a one-shot drive. AF-C/AF-F chase the box themselves and must not be driven.
        #expect(
            StillCapturePolicy.focusPointNeedsAutofocusDrive(
                focusMode: "AF-S", photography: false))
        #expect(
            !StillCapturePolicy.focusPointNeedsAutofocusDrive(
                focusMode: "AF-C", photography: false))
        #expect(
            !StillCapturePolicy.focusPointNeedsAutofocusDrive(
                focusMode: "AF-F", photography: false))
    }

    @Test func photographyDrivesEveryAutofocusModeAndManualDrivesNone() {
        // A stills live view runs no continuous AF until half-press, so even AF-C needs the drive.
        for mode in ["AF-S", "AF-C", "AF-A", "AF-F"] {
            #expect(
                StillCapturePolicy.focusPointNeedsAutofocusDrive(
                    focusMode: mode, photography: true))
        }
        // Manual focus has nothing to acquire, in either chrome.
        #expect(
            !StillCapturePolicy.focusPointNeedsAutofocusDrive(focusMode: "MF", photography: true))
        #expect(
            !StillCapturePolicy.focusPointNeedsAutofocusDrive(focusMode: "MF", photography: false))
    }

    @Test func unknownFocusModeKeepsThePhotographyOnlyBehaviour() {
        #expect(StillCapturePolicy.focusPointNeedsAutofocusDrive(focusMode: nil, photography: true))
        #expect(
            !StillCapturePolicy.focusPointNeedsAutofocusDrive(focusMode: nil, photography: false))
        #expect(
            !StillCapturePolicy.focusPointNeedsAutofocusDrive(focusMode: "", photography: false))
    }

    @Test func batteryGaugeMapsTheDocumentedStepsToBars() {
        // #303: BatteryLevel (0x5001) only ever carries 1/20/40/60/80/100, mapping to 1/5..5/5
        // bars. Rendering the raw number as a percentage is what made the app claim 60% while
        // the body was at 39%.
        #expect(CameraBatteryGauge.gauge(rawBatteryLevel: 100) == .bars(5))
        #expect(CameraBatteryGauge.gauge(rawBatteryLevel: 80) == .bars(4))
        #expect(CameraBatteryGauge.gauge(rawBatteryLevel: 60) == .bars(3))
        #expect(CameraBatteryGauge.gauge(rawBatteryLevel: 40) == .bars(2))
        #expect(CameraBatteryGauge.gauge(rawBatteryLevel: 20) == .bars(1))
        // 1 is the blinking, shutter-disabled step — not "1%".
        #expect(CameraBatteryGauge.gauge(rawBatteryLevel: 1) == .critical)
        #expect(CameraBatteryGauge.gauge(rawBatteryLevel: 1).filledBars == 1)
        #expect(CameraBatteryGauge.gauge(rawBatteryLevel: 1).isCritical)
    }

    @Test func batteryGaugeNeverOverstatesAnOffStepValue() {
        // A body reporting finer than the ZR spec must round UP to the step it sits under, so the
        // gauge can read low but never high.
        #expect(CameraBatteryGauge.gauge(rawBatteryLevel: 39) == .bars(2))
        #expect(CameraBatteryGauge.gauge(rawBatteryLevel: 58) == .bars(3))
        #expect(CameraBatteryGauge.gauge(rawBatteryLevel: 14) == .bars(1))
        #expect(CameraBatteryGauge.gauge(rawBatteryLevel: 99) == .bars(5))
    }

    @Test func batteryGaugeReportsUnknownWithoutAReading() {
        #expect(CameraBatteryGauge.gauge(rawBatteryLevel: 0) == .unknown)
        #expect(CameraBatteryGauge.gauge(rawBatteryLevel: -1) == .unknown)
        #expect(CameraBatteryGauge.gauge(rawBatteryLevel: 0).filledBars == 0)
    }
}
