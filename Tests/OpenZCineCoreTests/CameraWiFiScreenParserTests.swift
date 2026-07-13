import Testing

@testable import OpenZCineCore

@Test func parsesCleanConnectionWizardText() {
    let creds = CameraWiFiScreenParser.parse(lines: [
        "Connection wizard",
        "Connect to the following access point.",
        "SSID: NIKON_ZR_01234",
        "Key: a1b2c3d4",
    ])
    #expect(creds == CameraWiFiScreenParser.Credentials(ssid: "NIKON_ZR_01234", key: "a1b2c3d4"))
}

@Test func correctsOCRCharacterConfusionInSSIDAndKey() {
    // O→0, I→1 in the serial; brand read as "N1KON"; look-alike key hex glyphs o→0, l→1.
    let creds = CameraWiFiScreenParser.parse(lines: [
        "SSID N1KON_ZR_OI234",
        "Key a1b2c3dO",  // 'O' → '0'
    ])
    #expect(creds?.ssid == "NIKON_ZR_01234")
    #expect(creds?.key == "a1b2c3d0")
}

@Test func requiresBothFields() {
    #expect(CameraWiFiScreenParser.parse(lines: ["SSID: NIKON_ZR_01234"]) == nil)
    #expect(CameraWiFiScreenParser.parse(lines: ["Key: a1b2c3d4"]) == nil)
}

@Test func rejectsUnrelatedText() {
    #expect(
        CameraWiFiScreenParser.parse(lines: [
            "Connection wizard", "Connect to the following access point.",
        ]) == nil
    )
}

@Test func ignoresKeyTokenThatIsNotHexLength() {
    // "following" is 9 chars and non-hex; must not be taken as the key.
    #expect(
        CameraWiFiScreenParser.parse(lines: ["NIKON_ZR_01234", "following"]) == nil
    )
}

@Test func parsesLabelAndValueMergedInOneToken() {
    // A recognizer that merges label + value on one line must still yield clean tokens.
    let creds = CameraWiFiScreenParser.parse(lines: ["SSID:NIKON_ZR_01234 Key:a1b2c3d4"])
    #expect(creds == CameraWiFiScreenParser.Credentials(ssid: "NIKON_ZR_01234", key: "a1b2c3d4"))
}

@Test func parsesModelMisreadAsDigitTwo() {
    // "ZR" misread as "2R" self-corrects via the model-position table.
    let creds = CameraWiFiScreenParser.parse(lines: ["NIKON_2R_01234", "a1b2c3d4"])
    #expect(creds?.ssid == "NIKON_ZR_01234")
}
