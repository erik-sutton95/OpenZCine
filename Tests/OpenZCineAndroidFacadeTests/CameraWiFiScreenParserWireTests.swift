import Testing

@testable import OpenZCineAndroidFacade

@Test func androidCameraWiFiWireUsesSharedOCRPolicy() {
    let payload = AndroidCameraWiFiScreenParserWire.parse(
        "SSID: N1K0N_ZR_0l2S4\nKey: a1b2c3d4")

    #expect(payload == "NIKON_ZR_01254\u{001F}a1b2c3d4")
}

@Test func androidCameraWiFiWireRejectsIncompleteOrInvalidOCR() {
    #expect(AndroidCameraWiFiScreenParserWire.parse("SSID: NIKON_ZR_01234") == nil)
    #expect(AndroidCameraWiFiScreenParserWire.parse("Key: a1b2c3d4") == nil)
    #expect(AndroidCameraWiFiScreenParserWire.parse("SSID: NIKON_ZR_01234\nKey: not-a-key") == nil)
}

@Test func androidCameraWiFiManualWireMatchesTheSharedManualContract() {
    #expect(
        AndroidCameraWiFiScreenParserWire.manual(ssid: "NIKON_Z6III_00042", key: "abcd1234")
            == "NIKON_Z6III_00042\u{001F}abcd1234")
    // Wider than the OCR contract: any 8–63 printable-ASCII key is accepted.
    #expect(
        AndroidCameraWiFiScreenParserWire.manual(ssid: "MyCameraAP", key: "a longer pass!")
            == "MyCameraAP\u{001F}a longer pass!")
    #expect(AndroidCameraWiFiScreenParserWire.manual(ssid: "", key: "abcd1234") == nil)
    #expect(AndroidCameraWiFiScreenParserWire.manual(ssid: "NIKON_ZR_01234", key: "short") == nil)
    // A typed SSID is unconstrained, so the separator must not reach the payload.
    #expect(AndroidCameraWiFiScreenParserWire.manual(ssid: "AP\u{001F}X", key: "abcd1234") == nil)
}

@Test func androidCameraWiFiWireHasExactlyTwoSecretFields() {
    let payload = AndroidCameraWiFiScreenParserWire.parse(
        "SSID: NIKON_ZR_01234\nKey: a1b2c3d4")
    let separator = Character(AndroidCameraWiFiScreenParserWire.fieldSeparator)
    let fields = payload?.split(separator: separator)

    #expect(fields?.map(String.init) == ["NIKON_ZR_01234", "a1b2c3d4"])
}
