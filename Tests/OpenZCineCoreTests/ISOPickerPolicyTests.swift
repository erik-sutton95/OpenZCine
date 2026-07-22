import Testing

@testable import OpenZCineCore

@Test func isoPickerPolicyDetectsR3DNECodec() {
    #expect(ISOPickerPolicy.isR3DNECodec("R3D NE"))
    #expect(ISOPickerPolicy.isR3DNECodec("R3D NE 10-bit R3D"))
    #expect(!ISOPickerPolicy.isR3DNECodec("N-RAW"))
    #expect(!ISOPickerPolicy.isR3DNECodec("ProRes RAW HQ"))
    #expect(!ISOPickerPolicy.showsAutoISOControl(codec: ""))
    #expect(ISOPickerPolicy.showsAutoISOControl(codec: "N-RAW"))
    #expect(!ISOPickerPolicy.showsAutoISOControl(codec: "R3D NE"))
}

@Test func isoPickerPolicyUsesDualBaseOnlyForR3DNE() {
    #expect(ISOPickerPolicy.showsDualBaseCircuits(codec: "R3D NE"))
    #expect(!ISOPickerPolicy.showsDualBaseCircuits(codec: "N-RAW 12-bit NEV"))
    #expect(ISOPickerPolicy.pickerModes(codec: "R3D NE").count == 2)
    // Auto Off only when exposure mode is M.
    #expect(ISOPickerPolicy.pickerModes(codec: "N-RAW", exposureMode: "M").count == 2)
    #expect(ISOPickerPolicy.pickerModes(codec: "N-RAW", exposureMode: "M")[0].title == "Auto On")
    #expect(ISOPickerPolicy.pickerModes(codec: "N-RAW", exposureMode: "M")[1].title == "Auto Off")
    #expect(ISOPickerPolicy.pickerModes(codec: "N-RAW", exposureMode: "A").count == 1)
    #expect(ISOPickerPolicy.pickerModes(codec: "N-RAW", exposureMode: "A")[0].title == "Auto On")
    #expect(ISOPickerPolicy.pickerModes(codec: "N-RAW", exposureMode: nil).count == 1)
}

@Test func isoPickerPolicyDetectsMovieISOAutoControl() {
    // Movie ISO auto is MovISOAutoControl (0xD0AD), not exposure program P/A/S/M/Auto.
    #expect(ISOPickerPolicy.isAutoISOActive(isoAuto: true))
    #expect(!ISOPickerPolicy.isAutoISOActive(isoAuto: false))
    #expect(!ISOPickerPolicy.isAutoISOActive(isoAuto: nil))
    #expect(
        ISOPickerPolicy.autoISOModeIndex(codec: "N-RAW", isoAuto: true, exposureMode: "M") == 0)
    #expect(
        ISOPickerPolicy.autoISOModeIndex(codec: "N-RAW", isoAuto: false, exposureMode: "M") == 1)
    #expect(
        ISOPickerPolicy.autoISOModeIndex(codec: "N-RAW", isoAuto: nil, exposureMode: "M") == 1)
    // Non-M on non-R3D: only Auto On tab, always index 0.
    #expect(
        ISOPickerPolicy.autoISOModeIndex(codec: "N-RAW", isoAuto: false, exposureMode: "A") == 0)
    #expect(ISOPickerPolicy.autoISOOnLabel == "ON")
    #expect(ISOPickerPolicy.autoISOOffLabel == "OFF")
}

@Test func isoPickerPolicyManualISOOnlyInMModeForNonR3D() {
    // Non-R3D: manual / Auto Off only in M.
    #expect(ISOPickerPolicy.allowsManualISO(codec: "N-RAW", exposureMode: "M"))
    #expect(!ISOPickerPolicy.allowsManualISO(codec: "N-RAW", exposureMode: "A"))
    #expect(!ISOPickerPolicy.allowsManualISO(codec: "ProRes 422 HQ", exposureMode: "S"))
    #expect(!ISOPickerPolicy.allowsManualISO(codec: "H.265", exposureMode: "P"))
    #expect(!ISOPickerPolicy.allowsManualISO(codec: "N-RAW", exposureMode: "Auto"))
    #expect(!ISOPickerPolicy.allowsManualISO(codec: "N-RAW", exposureMode: nil))
    #expect(
        ISOPickerPolicy.isISOValueCameraOwned(
            codec: "N-RAW", isoAuto: true, exposureMode: "M"))
    #expect(
        !ISOPickerPolicy.isISOValueCameraOwned(
            codec: "N-RAW", isoAuto: false, exposureMode: "M"))
    #expect(
        ISOPickerPolicy.isISOValueCameraOwned(
            codec: "N-RAW", isoAuto: false, exposureMode: "A"))
}

@Test func isoPickerPolicyR3DNEAlwaysAllowsManualISO() {
    // R3D NE forces dual-base manual ISO in every exposure program (incl. A).
    #expect(ISOPickerPolicy.allowsManualISO(codec: "R3D NE", exposureMode: "A"))
    #expect(ISOPickerPolicy.allowsManualISO(codec: "R3D NE", exposureMode: "S"))
    #expect(ISOPickerPolicy.allowsManualISO(codec: "R3D NE", exposureMode: "P"))
    #expect(ISOPickerPolicy.allowsManualISO(codec: "R3D NE", exposureMode: nil))
    #expect(ISOPickerPolicy.allowsManualISO(codec: "R3D NE 12-bit R3D", exposureMode: "A"))
    #expect(
        !ISOPickerPolicy.isISOValueCameraOwned(
            codec: "R3D NE", isoAuto: nil, exposureMode: "A"))
    #expect(
        ISOPickerPolicy.pickerSubtitle(codec: "R3D NE", exposureMode: "A")
            == "Sensitivity · dual base")
}

@Test func isoPickerPolicyInjectsLiveAutoISOOutsideLadder() {
    let opts = ISOPickerPolicy.options(
        codec: "N-RAW", modeIndex: 0, includingLiveISO: "51200")
    #expect(opts.contains("51200"))
    #expect(opts.last == "51200" || opts.contains("51200"))
    // Already on ladder — no duplicate.
    #expect(
        ISOPickerPolicy.options(codec: "N-RAW", modeIndex: 0, includingLiveISO: "800")
            .filter { $0 == "800" }.count == 1)
}

@Test func isoPickerPolicyUnifiedDrumMarksBothNativeBases() {
    let marked = ISOPickerPolicy.markedValues(codec: "N-RAW", modeIndex: 0)
    #expect(marked == ["800", "6400"])
    #expect(ISOPickerPolicy.options(codec: "N-RAW", modeIndex: 0).contains("800"))
    #expect(ISOPickerPolicy.options(codec: "N-RAW", modeIndex: 0).contains("6400"))
    #expect(ISOPickerPolicy.options(codec: "N-RAW", modeIndex: 0).first == "200")
    #expect(ISOPickerPolicy.options(codec: "N-RAW", modeIndex: 0).last == "25600")
}

@Test func isoPickerPolicyDualBaseMarksOneNativeBasePerCircuit() {
    #expect(ISOPickerPolicy.markedValues(codec: "R3D NE", modeIndex: 0) == ["800"])
    #expect(ISOPickerPolicy.markedValues(codec: "R3D NE", modeIndex: 1) == ["6400"])
}

@Test func isoPickerPolicyBlocksISOOnlyWhileRecordingR3DNE() {
    #expect(ISOPickerPolicy.blocksISOChangeWhileRecording(codec: "R3D NE", isRecording: true))
    #expect(!ISOPickerPolicy.blocksISOChangeWhileRecording(codec: "R3D NE", isRecording: false))
    #expect(!ISOPickerPolicy.blocksISOChangeWhileRecording(codec: "N-RAW", isRecording: true))
}
