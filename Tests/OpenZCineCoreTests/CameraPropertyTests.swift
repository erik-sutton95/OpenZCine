import Foundation
import Testing

@testable import OpenZCineCore

@Test func cameraPropertyDecodersFormatOverlayValues() {
    #expect(PTPCameraPropertyDecoders.fNumber(UInt16(280)) == "f/2.8")
    #expect(PTPCameraPropertyDecoders.fNumber(UInt16(400)) == "f/4")
    // IRIS readings always carry one decimal so the value never reads as `f/2` or jumps width.
    #expect(PTPCameraPropertyDecoders.irisFNumber(UInt16(280)) == "f/2.8")
    #expect(PTPCameraPropertyDecoders.irisFNumber(UInt16(400)) == "f/4.0")
    #expect(PTPCameraPropertyDecoders.irisFNumber(UInt16(1_100)) == "f/11.0")
    #expect(PTPCameraPropertyDecoders.shutterAngle(Int32(18_000)) == "180°")
    #expect(PTPCameraPropertyDecoders.shutterSpeed(UInt32(0x0001_0032)) == "1/50")
    #expect(PTPCameraPropertyDecoders.focalLengthMillimeters(UInt32(2_400)) == "24 mm")
    #expect(PTPCameraPropertyDecoders.whiteBalanceMode(UInt16(0x8012)) == "Color temp")
    #expect(PTPCameraPropertyDecoders.baseISO(UInt8(2)) == "High")
    #expect(PTPCameraPropertyDecoders.shutterMode(1) == .speed)
    #expect(PTPCameraPropertyDecoders.shutterMode(2) == .angle)
    #expect(PTPCameraPropertyDecoders.shutterModeCode(.speed) == 1)
    #expect(PTPCameraPropertyDecoders.shutterModeCode(.angle) == 2)
}

@Test func cameraPropertyDecodersUnpackScreenSizeAndFileType() {
    let screen = PTPCameraPropertyDecoders.screenSize(
        UInt64(6_048) << 48 | UInt64(4_032) << 32 | UInt64(25) << 16
    )

    #expect(screen.label == "6048x4032")
    #expect(screen.fps == 25)
    #expect(PTPCameraPropertyDecoders.fileType(UInt32(0x0031_0A03)) == "R3D NE 10-bit R3D")
}

@Test func cameraPropertyDecodersBuildLensDescriptor() {
    #expect(
        PTPCameraPropertyDecoders.lens(
            focalMinX100: UInt32(2_400),
            focalMaxX100: UInt32(7_000),
            apertureMinX100: UInt16(280)
        ) == "24-70mm f/2.8"
    )
    #expect(
        PTPCameraPropertyDecoders.lens(
            focalMinX100: UInt32(5_000),
            focalMaxX100: UInt32(5_000),
            apertureMinX100: UInt16(180)
        ) == "50mm f/1.8"
    )
}

@Test func availableAperturesRestrictToMountedLens() {
    let f28 = PTPCameraPropertyDecoders.availableApertures(forLens: "24-70mm f/2.8")
    // An f/2.8 zoom can't open wider than f/2.8 — f/1.4 / f/2.0 drop off; third stops stay.
    #expect(f28.first == "f/2.8")
    #expect(f28.contains("f/3.2"))
    #expect(f28.contains("f/3.5"))
    #expect(!f28.contains("f/2.0"))
    #expect(!f28.contains("f/2.5"))
    // A fast prime's marked aperture leads the list even when it falls between stops.
    #expect(PTPCameraPropertyDecoders.availableApertures(forLens: "50mm f/1.8").first == "f/1.8")
    #expect(
        !PTPCameraPropertyDecoders.availableApertures(forLens: "50mm f/1.8").contains("f/1.4"))
    // Unknown / aperture-less lens falls back to the full ladder.
    #expect(PTPCameraPropertyDecoders.availableApertures(forLens: nil).first == "f/1.4")
    #expect(PTPCameraPropertyDecoders.availableApertures(forLens: "Manual lens").first == "f/1.4")
}

@Test func apertureListDecodesCameraEnumeration() {
    // Raw ×100 f-numbers as the camera enumerates them → IRIS strings, third stops intact.
    #expect(
        PTPCameraPropertyDecoders.apertureList(fromEnum: [280, 320, 350, 400])
            == ["f/2.8", "f/3.2", "f/3.5", "f/4.0"])
    // The "no value" sentinel (0xFFFF) is dropped, not rendered as "—".
    #expect(
        PTPCameraPropertyDecoders.apertureList(fromEnum: [280, 0xFFFF, 400]) == ["f/2.8", "f/4.0"])
}

@Test func movieAFDecodersAndEncodersRoundTrip() {
    // AF mode (UINT8): MovieFocusMode values from the ZR command reference.
    #expect(PTPCameraPropertyDecoders.movieFocusMode(0) == "AF-S")
    #expect(PTPCameraPropertyDecoders.movieFocusMode(1) == "AF-C")
    #expect(PTPCameraPropertyDecoders.movieFocusMode(2) == "AF-F")
    #expect(PTPCameraPropertyDecoders.movieFocusMode(3) == "MF")
    #expect(PTPCameraPropertyDecoders.movieFocusMode(4) == "MF")
    #expect(PTPCameraPropertyDecoders.movieFocusModeCode(for: "AF-C") == 1)
    #expect(PTPCameraPropertyDecoders.movieFocusModeCode(for: "MF") == 4)
    #expect(
        PTPCameraPropertyDecoders.mergedMovieFocusModeOptions(advertised: ["MF"])
            == ["AF-S", "AF-C", "AF-F", "MF"])
    // AF-area mode (UINT16): MovieFocusMeteringMode.
    #expect(PTPCameraPropertyDecoders.movieFocusArea(0x8010) == "Single")
    #expect(PTPCameraPropertyDecoders.movieFocusArea(0x8011) == "Auto")
    #expect(PTPCameraPropertyDecoders.movieFocusArea(0x8033) == "Subject")
    #expect(PTPCameraPropertyDecoders.movieFocusAreaCode(for: "Wide-L") == 0x8019)
    #expect(PTPCameraPropertyDecoders.movieFocusAreaCode(for: "Subject") == 0x8033)
    // Subject detection (UINT8): MovieAFSubjectDetection.
    #expect(PTPCameraPropertyDecoders.movieAFSubject(2) == "People")
    #expect(PTPCameraPropertyDecoders.movieAFSubject(5) == "Bird")
    #expect(PTPCameraPropertyDecoders.movieAFSubjectCode(for: "Airplane") == 6)
}

@Test func movieAFWritesEncodeToTheRightProperty() {
    #expect(
        PTPCameraPropertyWrite.request(control: .focusMode, label: "AF-C")
            == PTPCameraPropertyWrite(property: .movieFocusMode, data: Data([0x01])))
    // UINT16 little-endian: 0x8033 → [0x33, 0x80].
    #expect(
        PTPCameraPropertyWrite.request(control: .focusArea, label: "Subject")
            == PTPCameraPropertyWrite(
                property: .movieFocusMeteringMode, data: Data([0x33, 0x80])))
    #expect(
        PTPCameraPropertyWrite.request(control: .focusSubject, label: "People")
            == PTPCameraPropertyWrite(property: .movieAFSubjectDetection, data: Data([0x02])))
}

@Test func snapshotDecodesCommandMonitorProperties() {
    let snapshot = PTPCameraPropertySnapshot()
        .applying(property: .movMicrophone, data: Data([0x02]))
        .applying(property: .movRecordMicrophoneLevelValue, data: Data([15]))
        .applying(property: .movWindNoiseReduction, data: Data([1]))
        .applying(property: .movieAttenuator, data: Data([1]))
        .applying(property: .electronicVR, data: Data([1]))
    #expect(snapshot.microphoneSensitivity == "Medium")
    #expect(snapshot.microphoneLevel == "15")
    #expect(snapshot.windNoiseReduction == "ON")
    #expect(snapshot.inputAttenuator == "ON")
    #expect(snapshot.electronicVR == "ON")
}

@Test func snapshotDecodesZRSoundProperties() {
    // ZR sound properties: input selection (1 Mic / 2 Line), INT8 sensitivity (0xFF Auto, 0–20),
    // 32-bit float on/off.
    let snapshot = PTPCameraPropertySnapshot()
        .applying(property: .audioInputSelection, data: Data([2]))
        .applying(property: .movieAudioInputSensitivity, data: Data([0xFF]))
        .applying(property: .movie32BitFloatAudioRecording, data: Data([1]))
    #expect(snapshot.audioInput == "Line")
    #expect(snapshot.audioSensitivity == "Auto")
    #expect(snapshot.audio32BitFloat == "ON")

    let manual = snapshot.applying(property: .movieAudioInputSensitivity, data: Data([12]))
    #expect(manual.audioSensitivity == "12")
}

@Test func audioControlWritesEncodeToTheRightProperties() {
    #expect(
        PTPCameraPropertyWrite.request(control: .audioSensitivity, label: "Auto")
            == PTPCameraPropertyWrite(
                property: .movieAudioInputSensitivity, data: Data([0xFF])))
    #expect(
        PTPCameraPropertyWrite.request(control: .audioSensitivity, label: "12")
            == PTPCameraPropertyWrite(property: .movieAudioInputSensitivity, data: Data([12])))
    // The body refuses zero; the encoder never produces it.
    #expect(PTPCameraPropertyWrite.request(control: .audioSensitivity, label: "0") == nil)
    #expect(PTPCameraPropertyWrite.request(control: .audioSensitivity, label: "21") == nil)
    #expect(
        PTPCameraPropertyWrite.request(control: .audioInput, label: "Line")
            == PTPCameraPropertyWrite(property: .audioInputSelection, data: Data([2])))
    #expect(
        PTPCameraPropertyWrite.request(control: .windFilter, label: "ON")
            == PTPCameraPropertyWrite(property: .movWindNoiseReduction, data: Data([1])))
    #expect(
        PTPCameraPropertyWrite.request(control: .attenuator, label: "OFF")
            == PTPCameraPropertyWrite(property: .movieAttenuator, data: Data([0])))
    #expect(
        PTPCameraPropertyWrite.request(control: .audio32BitFloat, label: "ON")
            == PTPCameraPropertyWrite(
                property: .movie32BitFloatAudioRecording, data: Data([1])))
}

@Test func stabilizationSummaryComposesVRAndElectronicVR() {
    #expect(
        PTPCameraPropertyDecoders.stabilizationSummary(
            vibrationReduction: "ON", electronicVR: "OFF") == "ON/OFF")
    #expect(
        PTPCameraPropertyDecoders.stabilizationSummary(
            vibrationReduction: "ON", electronicVR: "ON") == "ON")
    #expect(
        PTPCameraPropertyDecoders.stabilizationSummary(
            vibrationReduction: nil, electronicVR: "ON") == "ON")
    #expect(
        PTPCameraPropertyDecoders.stabilizationSummary(
            vibrationReduction: nil, electronicVR: nil) == nil)
}

@Test func snapshotStabilizationSummaryPrefersVR() {
    let snapshot = PTPCameraPropertySnapshot()
        .applying(property: .movieVibrationReduction, data: Data([2]))
        .applying(property: .electronicVR, data: Data([0]))
    #expect(snapshot.stabilizationSummary == "SPORT/OFF")
}

@Test func commandMonitorDecoderHelpers() {
    #expect(PTPCameraPropertyDecoders.baseISOCircuitShort("Low") == "L")
    #expect(PTPCameraPropertyDecoders.baseISOCircuitShort("High") == "H")
    #expect(PTPCameraPropertyDecoders.toneLabel(fromCodec: "R3D NE") == "Log3G10")
    #expect(PTPCameraPropertyDecoders.toneLabel(fromCodec: "N-RAW") == "N-Log")
    #expect(PTPCameraPropertyDecoders.toneLabel(fromCodec: "ProRes RAW HQ") == "N-Log")
    #expect(PTPCameraPropertyDecoders.toneLabel(fromCodec: "H.265 10-bit") == "N-Log")
    #expect(PTPCameraPropertyDecoders.toneLabel(fromCodec: "") == nil)
    #expect(PTPCameraPropertyDecoders.movMicrophone(0) == "Auto")
    #expect(PTPCameraPropertyDecoders.onOffLabel(1) == "ON")
}

@Test func controlLockEnabled() {
    #expect(PTPCameraPropertyDecoders.controlLockEnabled(0) == false)
    #expect(PTPCameraPropertyDecoders.controlLockEnabled(1) == true)
}

@Test func snapshotDecodesMovieShutterLock() {
    let locked = PTPCameraPropertySnapshot()
        .applying(property: .movieTVLockSetting, data: Data([1]))
    #expect(locked.shutterLocked == true)
    let unlocked = PTPCameraPropertySnapshot()
        .applying(property: .movieTVLockSetting, data: Data([0]))
    #expect(unlocked.shutterLocked == false)
}

@Test func snapshotDecodesMovieShutterMode() {
    let speed = PTPCameraPropertySnapshot()
        .applying(property: .movieShutterMode, data: Data([1]))
    #expect(speed.shutterMode == .speed)
    let angle = PTPCameraPropertySnapshot()
        .applying(property: .movieShutterMode, data: Data([2]))
    #expect(angle.shutterMode == .angle)
}

@Test func movieTVLockWriteEncodesUnlock() {
    #expect(
        PTPCameraPropertyWrite.movieTVLock(unlocked: true)
            == PTPCameraPropertyWrite(property: .movieTVLockSetting, data: Data([0])))
    #expect(
        PTPCameraPropertyWrite.movieTVLock(unlocked: false)
            == PTPCameraPropertyWrite(property: .movieTVLockSetting, data: Data([1])))
}

@Test func snapshotDecodesMovieAFProperties() {
    let snapshot = PTPCameraPropertySnapshot()
        .applying(property: .movieFocusMode, data: Data([0x01]))
        .applying(property: .movieFocusMeteringMode, data: Data([0x33, 0x80]))
        .applying(property: .movieAFSubjectDetection, data: Data([0x03]))
    #expect(snapshot.focusMode == "AF-C")
    #expect(snapshot.focusArea == "Subject")
    #expect(snapshot.focusSubject == "Animal")
    // The FOCUS bar readout reflects the camera's AF mode.
    let state = CameraDisplayState.preview.applyingCameraProperties(snapshot)
    #expect(state.values.first(where: { $0.label == "FOCUS" })?.value == "AF-C")
}

@Test func cameraPropertyWriteRequestsEncodePickerValues() {
    #expect(
        PTPCameraPropertyWrite.request(control: .iso, label: "800")
            == PTPCameraPropertyWrite(
                property: .movieISOSensitivity,
                data: Data([0x20, 0x03, 0x00, 0x00])
            )
    )
    #expect(
        PTPCameraPropertyWrite.request(control: .shutter, label: "180.0°")
            == PTPCameraPropertyWrite(
                property: .movieShutterAngle,
                data: Data([0x50, 0x46, 0x00, 0x00])
            )
    )
    #expect(
        PTPCameraPropertyWrite.request(control: .shutter, label: "1/50")
            == PTPCameraPropertyWrite(
                property: .movieShutterSpeed,
                data: Data([0x32, 0x00, 0x01, 0x00])
            )
    )
    #expect(
        PTPCameraPropertyWrite.shutterMode(.angle)
            == PTPCameraPropertyWrite(property: .movieShutterMode, data: Data([2])))
    #expect(
        PTPCameraPropertyWrite.shutterMode(.speed)
            == PTPCameraPropertyWrite(property: .movieShutterMode, data: Data([1])))
    #expect(
        PTPCameraPropertyWrite.request(control: .iris, label: "f/2.8")
            == PTPCameraPropertyWrite(
                property: .movieFNumber,
                data: Data([0x18, 0x01])
            )
    )
    #expect(
        PTPCameraPropertyWrite.request(control: .whiteBalanceKelvin, label: "5600K")
            == PTPCameraPropertyWrite(
                property: .movieWBColorTemp,
                data: Data([0xE0, 0x15])
            )
    )
}

@Test func advertisedModeWritesUseExactRawValues() {
    let size = PTPCameraPropertyWrite.screenSize(raw: 0x1770_0D08_1900_0000)
    #expect(size.property == .movieRecordScreenSize)
    #expect(size.data == Data(ByteCoding.uint64LE(0x1770_0D08_1900_0000)))
    let codec = PTPCameraPropertyWrite.fileType(raw: 0x0031_0C03)
    #expect(codec.property == .movieFileType)
    #expect(codec.data == Data(ByteCoding.uint32LE(0x0031_0C03)))
}

@Test func whiteBalanceKelvinSelectionSwitchesModeThenSetsTemperature() {
    // Two writes: switch the camera into Color-temp mode (0x8012) first, then set the temp (5600).
    let writes = PTPCameraPropertyWrite.requests(
        control: .whiteBalanceKelvin, label: "5600K", snapshot: PTPCameraPropertySnapshot())
    #expect(
        writes == [
            PTPCameraPropertyWrite(property: .movieWhiteBalance, data: Data([0x12, 0x80])),
            PTPCameraPropertyWrite(property: .movieWBColorTemp, data: Data([0xE0, 0x15])),
        ])
}

@Test func whiteBalancePresetSelectionWritesModeOnly() {
    // A named preset is a single mode write (Cloudy = 0x8010).
    let writes = PTPCameraPropertyWrite.requests(
        control: .whiteBalanceKelvin, label: "Cloudy", snapshot: PTPCameraPropertySnapshot())
    #expect(
        writes == [PTPCameraPropertyWrite(property: .movieWhiteBalance, data: Data([0x10, 0x80]))])
}

@Test func cameraPropertySnapshotAppliesMovieBaseISO() {
    let low = PTPCameraPropertySnapshot().applying(
        property: .movieBaseISO, data: Data([0x01]))
    let high = PTPCameraPropertySnapshot().applying(
        property: .movieBaseISO, data: Data([0x02]))

    #expect(low.baseISO == "Low")
    #expect(high.baseISO == "High")
}

@Test func cameraPropertySnapshotDecodesExposureProgramMode() {
    // UINT16, little-endian: 0x8050 → [0x50, 0x80] = U1; 0x0003 → A; 0x8010 → Auto.
    func mode(_ raw: UInt16) -> String? {
        PTPCameraPropertySnapshot()
            .applying(
                property: .exposureProgramMode,
                data: Data([UInt8(raw & 0xFF), UInt8(raw >> 8)])
            ).exposureMode
    }
    #expect(mode(0x0001) == "M")
    #expect(mode(0x0002) == "P")
    #expect(mode(0x0003) == "A")
    #expect(mode(0x0004) == "S")
    #expect(mode(0x8010) == "Auto")
    #expect(mode(0x8050) == "U1")
    #expect(mode(0x8052) == "U3")
    // Undocumented value falls back to hex, never the wrong "L".
    #expect(mode(0x00FF) == "0xff")
    // A short payload leaves the field untouched (defensive against a truncated read).
    #expect(
        PTPCameraPropertySnapshot()
            .applying(property: .exposureProgramMode, data: Data([0x03])).exposureMode == nil)
}

@Test func cameraPropertySnapshotAppliesRawPropertyValues() {
    let snapshot = PTPCameraPropertySnapshot()
        .applying(property: .movieISOSensitivity, data: Data([0x20, 0x03, 0x00, 0x00]))
        .applying(property: .movieShutterAngle, data: Data([0x50, 0x46, 0x00, 0x00]))
        .applying(property: .movieFNumber, data: Data([0x18, 0x01]))
        .applying(property: .movieWBColorTemp, data: Data([0xE0, 0x15]))
        .applying(
            property: .movieRecordScreenSize,
            data: Data(
                ByteCoding.uint64LE(
                    UInt64(6_048) << 48 | UInt64(4_032) << 32 | UInt64(25) << 16
                ))
        )

    #expect(snapshot.iso == UInt32(800))
    #expect(snapshot.shutterAngle == "180°")
    #expect(snapshot.fNumber == "f/2.8")
    #expect(snapshot.wbKelvin == UInt16(5_600))
    #expect(snapshot.resolution == "6048x4032")
    #expect(snapshot.fps == 25)
}

@Test func devicePropDescEnumParserReadsTrailingEnumValues() {
    let data = Data([
        0x34, 0x12,
        0x02,
        0x03, 0x00,
        0x20, 0x03, 0x00, 0x00,
        0x80, 0x0C, 0x00, 0x00,
        0x00, 0x19, 0x00, 0x00,
    ])

    #expect(
        PTPCameraPropertyDecoders.devicePropDescEnumValues(data: data, valueByteCount: 4)
            == [800, 3_200, 6_400])
}

@Test func displayStateRespectsShutterDisplayMode() {
    let a = CameraDisplayState.preview.applyingCameraProperties(
        PTPCameraPropertySnapshot(shutterMode: .angle, shutterSpeed: "1/50", shutterAngle: "180°"))
    #expect(a.values.first(where: { $0.label == "SHUTTER" })?.value == "180°")
    let s = CameraDisplayState.preview.applyingCameraProperties(
        PTPCameraPropertySnapshot(shutterMode: .speed, shutterSpeed: "1/50", shutterAngle: "180°"))
    #expect(s.values.first(where: { $0.label == "SHUTTER" })?.value == "1/50")
}

@Test func displayStateAppliesCameraPropertySnapshot() {
    let state = CameraDisplayState.preview.applyingCameraProperties(
        PTPCameraPropertySnapshot(
            iso: 800,
            shutterAngle: "180°",
            fNumber: "f/2.8",
            wbKelvin: 5_600,
            resolution: "6048x4032",
            fps: 25,
            fileType: "R3D NE 10-bit R3D",
            focalMinX100: 2_400,
            focalMaxX100: 7_000,
            apertureMinX100: 280
        )
    )

    #expect(state.resolutionFrameRate == "6K · 25p")
    #expect(state.codec == "R3D NE")
    #expect(state.lens == "24-70mm f/2.8")
    #expect(state.values.first(where: { $0.label == "ISO" })?.value == "800")
    #expect(state.values.first(where: { $0.label == "SHUTTER" })?.value == "180°")
    #expect(state.values.first(where: { $0.label == "IRIS" })?.value == "f/2.8")
    #expect(state.values.first(where: { $0.label == "WB" })?.value == "5600K")
}

@Test func screenSizeModesParsesAdvertisedDescriptorEnum() {
    func u64le(_ value: UInt64) -> [UInt8] { (0..<8).map { UInt8((value >> ($0 * 8)) & 0xFF) } }
    let mode25: UInt64 = 0x17A0_0D4A_0019_0000  // 6048x3402 @ 25
    let mode50: UInt64 = 0x17A0_0D4A_0032_0000  // 6048x3402 @ 50
    // DevicePropDesc: code, datatype(UINT64), getset, factory-default, current, then the enum form.
    var desc: [UInt8] = [0xA0, 0xD0, 0x08, 0x00, 0x01]
    desc += u64le(mode25) + u64le(mode25)
    desc += [0x02, 0x02, 0x00]  // FormFlag = enumeration, count = 2
    desc += u64le(mode25) + u64le(mode50)

    let modes = PTPCameraPropertyDecoders.screenSizeModes(fromDescriptor: Data(desc))
    #expect(modes.map(\.raw) == [mode25, mode50])
    #expect(modes[0].label.hasSuffix("25p"))
    #expect(modes[1].label.hasSuffix("50p"))
}

@Test func fileTypeModesMapAdvertisedEnumToShortCodecLabels() {
    let h265: UInt32 = 0x0001_0A00  // H.265 10-bit MOV
    let h264: UInt32 = 0x0000_0801  // H.264 8-bit MP4
    let r3dNe: UInt32 = 0x0031_0C03  // R3D NE 12-bit R3D
    let modes = PTPCameraPropertyDecoders.fileTypeModes(fromEnum: [h265, h264, r3dNe])
    #expect(
        modes == [
            PTPCameraFileTypeMode(raw: h265, label: "H.265"),
            PTPCameraFileTypeMode(raw: h264, label: "H.264"),
            PTPCameraFileTypeMode(raw: r3dNe, label: "R3D NE"),
        ])
}

@Test func devicePropDescEnumValuesReadsSingleByteForms() {
    // Two pad bytes, then FormFlag 0x02, UINT16 count = 3 (LE), then three UINT8 values flush to end.
    let data = Data([0xFF, 0xFF, 0x02, 0x03, 0x00, 0x00, 0x01, 0x04])
    #expect(
        PTPCameraPropertyDecoders.devicePropDescEnumValues(data: data, valueByteCount: 1)
            == [0x00, 0x01, 0x04])
}

@Test func optionLabelsMapAdvertisedEnumsThroughSharedDecoders() {
    // Focus mode (UINT8) round-trips to the picker's AF-mode labels; an unknown raw (0x09) drops.
    #expect(
        PTPCameraPropertyDecoders.optionLabels(for: .movieFocusMode, rawValues: [0, 1, 3, 4, 0x09])
            == ["AF-S", "AF-C", "MF"])
    // AF-area (UINT16) and subject detection (UINT8) map to their picker labels.
    #expect(
        PTPCameraPropertyDecoders.optionLabels(
            for: .movieFocusMeteringMode, rawValues: [0x8010, 0x8019, 0x8033])
            == ["Single", "Wide-L", "Subject"])
    #expect(
        PTPCameraPropertyDecoders.optionLabels(
            for: .movieAFSubjectDetection, rawValues: [1, 2, 3]) == ["Auto", "People", "Animal"])
    // WB presets exclude nothing here, but the colour-temp mode (0x8012) is a valid preset label
    // that the *model* filters into the Kelvin tab; the decoder still surfaces it.
    #expect(
        PTPCameraPropertyDecoders.optionLabels(
            for: .movieWhiteBalance, rawValues: [0x0002, 0x8010, 0x8012])
            == ["Auto", "Cloudy", "Color temp"])
    // Shutter angle/speed produce labels the `shutterWrite` encoder parses back; duplicates collapse.
    #expect(
        PTPCameraPropertyDecoders.optionLabels(
            for: .movieShutterAngle, rawValues: [18_000, 9_000, 18_000]) == ["180°", "90°"])
    #expect(
        PTPCameraPropertyDecoders.optionLabels(
            for: .movieShutterSpeed, rawValues: [0x0001_0032, 0x0001_0064]) == ["1/50", "1/100"])
}

@Test func whiteBalanceTintMapsModesAndEncodesGrid() {
    // Every decoder WB label with a movie tune property maps; Preset/Flash stay unmapped.
    #expect(WhiteBalanceTint.tuneProperty(forWBModeLabel: "Auto") == .movieWbTuneAuto)
    #expect(WhiteBalanceTint.tuneProperty(forWBModeLabel: "Natural auto") == .movieWbTuneNatural)
    #expect(WhiteBalanceTint.tuneProperty(forWBModeLabel: "Color temp") == .movieWbTuneColorTemp)
    #expect(WhiteBalanceTint.tuneProperty(forWBModeLabel: "Preset") == nil)
    #expect(WhiteBalanceTint.tuneProperty(forWBModeLabel: "Flash") == nil)

    // 13×13 grid encoding `row·100 + column·2`: neutral centre 612; B/A run the columns,
    // G/M the rows (G = row 0). Out-of-range cells clamp onto the grid.
    #expect(WhiteBalanceTint.propertyValue(amberBlueCell: 0, greenMagentaCell: 0) == 612)
    #expect(WhiteBalanceTint.propertyValue(amberBlueCell: 6, greenMagentaCell: 0) == 624)
    #expect(WhiteBalanceTint.propertyValue(amberBlueCell: -6, greenMagentaCell: 0) == 600)
    #expect(WhiteBalanceTint.propertyValue(amberBlueCell: 0, greenMagentaCell: 6) == 12)
    #expect(WhiteBalanceTint.propertyValue(amberBlueCell: 0, greenMagentaCell: -6) == 1212)
    #expect(WhiteBalanceTint.propertyValue(amberBlueCell: 9, greenMagentaCell: -9) == 1224)

    // Wire round-trip, and rejection of values off the sparse grid.
    let neutral = WhiteBalanceTint.cells(fromPropertyValue: 612)
    #expect(neutral?.amberBlue == 0)
    #expect(neutral?.greenMagenta == 0)
    let offset = WhiteBalanceTint.cells(fromPropertyValue: 104)
    #expect(offset?.amberBlue == -4)
    #expect(offset?.greenMagenta == 5)
    #expect(WhiteBalanceTint.cells(fromPropertyValue: 613) == nil)
    #expect(WhiteBalanceTint.cells(fromPropertyValue: 1250) == nil)

    let write = WhiteBalanceTint.write(
        wbModeLabel: "Sunny", amberBlueCell: -2, greenMagentaCell: 4)
    #expect(write?.property == .movieWbTuneSunny)
    #expect(write?.data == Data([0xD0, 0x00]))  // row 2, col 4 → 208 little-endian
    #expect(
        WhiteBalanceTint.write(wbModeLabel: "Preset", amberBlueCell: 1, greenMagentaCell: 0)
            == nil)

    // Readout uses the body's units: 0.5 per A–B cell, 0.25 per G–M cell.
    #expect(WhiteBalanceTint.label(amberBlueCell: 0, greenMagentaCell: 0) == "Neutral")
    #expect(WhiteBalanceTint.label(amberBlueCell: 2, greenMagentaCell: -1) == "A1 · M0.25")
    #expect(WhiteBalanceTint.label(amberBlueCell: -3, greenMagentaCell: 3) == "B1.5 · G0.75")
}

@Test func movieVibrationReductionDecodesKnownValues() {
    #expect(PTPCameraPropertyDecoders.movieVibrationReduction(0) == "OFF")
    #expect(PTPCameraPropertyDecoders.movieVibrationReduction(1) == "ON")
    #expect(PTPCameraPropertyDecoders.movieVibrationReduction(2) == "SPORT")
    #expect(PTPCameraPropertyDecoders.movieVibrationReduction(9) == "0x9")
}

@Test func movieVibrationReductionCodeRoundTrips() {
    for raw: UInt8 in [0, 1, 2] {
        let label = PTPCameraPropertyDecoders.movieVibrationReduction(raw)
        #expect(PTPCameraPropertyDecoders.movieVibrationReductionCode(for: label) == raw)
    }
    #expect(PTPCameraPropertyDecoders.movieVibrationReductionCode(for: "0x9") == nil)
}

@Test func snapshotDecodesVibrationReduction() {
    let snapshot = PTPCameraPropertySnapshot()
        .applying(property: .movieVibrationReduction, data: Data([1]))
    #expect(snapshot.vibrationReduction == "ON")
}

@Test func vibrationReductionWriteEncodes() {
    let write = PTPCameraPropertyWrite.vibrationReduction(label: "SPORT")
    #expect(write?.property == .movieVibrationReduction)
    #expect(write?.data == Data([2]))
    #expect(PTPCameraPropertyWrite.vibrationReduction(label: "0x9") == nil)
}

@Test func electronicVRWriteEncodes() {
    #expect(PTPCameraPropertyWrite.electronicVR(on: true).data == Data([1]))
    #expect(PTPCameraPropertyWrite.electronicVR(on: false).data == Data([0]))
    #expect(PTPCameraPropertyWrite.electronicVR(on: true).property == .electronicVR)
}

@Test func optionLabelsDecodeVibrationReductionEnum() {
    let labels = PTPCameraPropertyDecoders.optionLabels(
        for: .movieVibrationReduction, rawValues: [0, 1, 2, 9])
    #expect(labels == ["OFF", "ON", "SPORT"])
}

@Test func exposureProgramCodeRoundTripsWithShortLabel() {
    // The 8 writable labels the MODE picker offers encode to their 0x500E values, and each decodes
    // back to the same label.
    let pairs: [(String, UInt16)] = [
        ("M", 0x0001), ("P", 0x0002), ("A", 0x0003), ("S", 0x0004),
        ("Auto", 0x8010), ("U1", 0x8050), ("U2", 0x8051), ("U3", 0x8052),
    ]
    for (label, code) in pairs {
        #expect(PTPCameraPropertyDecoders.exposureProgramCode(for: label) == code)
        #expect(PTPCameraPropertyDecoders.exposureProgramShort(code) == label)
    }
    #expect(PTPCameraPropertyDecoders.exposureProgramCode(for: "Portrait") == nil)
    #expect(PTPCameraPropertyDecoders.exposureProgramCode(for: "nonsense") == nil)
}

@Test func exposureModeWriteEncodesUInt16LE() {
    let m = PTPCameraPropertyWrite.request(control: .exposureMode, label: "M")
    #expect(m?.property == .exposureProgramMode)
    #expect(m?.data == Data([0x01, 0x00]))  // 0x0001 little-endian
    let u3 = PTPCameraPropertyWrite.request(control: .exposureMode, label: "U3")
    #expect(u3?.data == Data([0x52, 0x80]))  // 0x8052 little-endian
    #expect(PTPCameraPropertyWrite.request(control: .exposureMode, label: "Portrait") == nil)
}

@Test func gridDisplayDecodesOnOff() {
    let on = PTPCameraPropertySnapshot().applying(property: .gridDisplay, data: Data([1]))
    let off = PTPCameraPropertySnapshot().applying(property: .gridDisplay, data: Data([0]))
    #expect(on.gridDisplay == "ON")
    #expect(off.gridDisplay == "OFF")
    #expect(PTPPropertyCode.liveMonitorPollOrder.contains(.gridDisplay))
}

@Test func warningStatusDecodesAndFeedsTheRecordingPollSet() {
    let clear = PTPCameraPropertySnapshot().applying(property: .warningStatus, data: Data([0]))
    let warning = PTPCameraPropertySnapshot().applying(property: .warningStatus, data: Data([0x80]))
    #expect(clear.warningRaw == 0)
    #expect(clear.warningStatus.tileLabel == "OK")
    #expect(warning.warningStatus.isAnyWarningActive)
    #expect(warning.warningStatus.tileLabel == "CHECK")
    #expect(PTPPropertyCode.recordingMonitorPollOrder == [.batteryLevel, .acPower, .warningStatus])
    #expect(
        PTPPropertyCode.monitorPollOrder(isRecording: true)
            == PTPPropertyCode.recordingMonitorPollOrder)
}

@Test func monitorMaintenanceCadenceIsDueOnlyAfterItsInterval() {
    let now = Date(timeIntervalSinceReferenceDate: 10_000)
    #expect(
        CameraMonitorPollPolicy.isDue(
            lastRefreshAt: nil, now: now,
            interval: CameraMonitorPollPolicy.descriptorRefreshInterval))
    #expect(
        !CameraMonitorPollPolicy.isDue(
            lastRefreshAt: now.addingTimeInterval(-59), now: now,
            interval: CameraMonitorPollPolicy.descriptorRefreshInterval))
    #expect(
        CameraMonitorPollPolicy.isDue(
            lastRefreshAt: now.addingTimeInterval(-60), now: now,
            interval: CameraMonitorPollPolicy.descriptorRefreshInterval))
}
