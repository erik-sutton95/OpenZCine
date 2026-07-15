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

@Test func androidCameraWiFiWireHasExactlyTwoSecretFields() {
    let payload = AndroidCameraWiFiScreenParserWire.parse(
        "SSID: NIKON_ZR_01234\nKey: a1b2c3d4")
    let separator = Character(AndroidCameraWiFiScreenParserWire.fieldSeparator)
    let fields = payload?.split(separator: separator)

    #expect(fields?.map(String.init) == ["NIKON_ZR_01234", "a1b2c3d4"])
}
