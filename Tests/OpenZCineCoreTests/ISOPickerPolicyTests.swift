import Testing

@testable import OpenZCineCore

@Test func isoPickerPolicyDetectsR3DNECodec() {
    #expect(ISOPickerPolicy.isR3DNECodec("R3D NE"))
    #expect(ISOPickerPolicy.isR3DNECodec("R3D NE 10-bit R3D"))
    #expect(!ISOPickerPolicy.isR3DNECodec("N-RAW"))
    #expect(!ISOPickerPolicy.isR3DNECodec("ProRes RAW HQ"))
}

@Test func isoPickerPolicyUsesDualBaseOnlyForR3DNE() {
    #expect(ISOPickerPolicy.showsDualBaseCircuits(codec: "R3D NE"))
    #expect(!ISOPickerPolicy.showsDualBaseCircuits(codec: "N-RAW 12-bit NEV"))
    #expect(ISOPickerPolicy.pickerModes(codec: "R3D NE").count == 2)
    #expect(ISOPickerPolicy.pickerModes(codec: "N-RAW").isEmpty)
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
