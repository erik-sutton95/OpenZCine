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

@Test func parsesLocalizedNonZRCameraScreenWithoutKnowingTheLabelLanguage() {
    let creds = CameraWiFiScreenParser.parse(lines: [
        "Verbindingswizard",
        "SSID: NIKONZ_8_X12345",
        "Sleutel: b4c5d6e7",
    ])

    #expect(
        creds
            == CameraWiFiScreenParser.Credentials(
                ssid: "NIKONZ_8_X12345",
                key: "b4c5d6e7"
            )
    )
}

@Test func preservesUnfamiliarNikonZModelSegmentsInsteadOfRebuildingTheSSID() {
    let creds = CameraWiFiScreenParser.parse(lines: [
        "SSID nikonz_9_pro123",
        "Password 12ab34cd",
    ])

    #expect(creds?.ssid == "NIKONZ_9_PRO123")

    let z8 = CameraWiFiScreenParser.parse(lines: [
        "SSID NIKON_Z8_12345",
        "Password 12ab34cd",
    ])
    #expect(z8?.ssid == "NIKON_Z8_12345")
}

@Test func reportsWhenAValidNikonSSIDStillNeedsItsKey() {
    #expect(
        CameraWiFiScreenParser.result(lines: ["SSID: NIKONZ_8_X12345"])
            == .needsKey
    )
}

@Test func reportsUnsupportedNikonSSIDShapeForManualFallback() {
    #expect(
        CameraWiFiScreenParser.result(lines: ["SSID: NIKONZ@MODEL42", "Key: b4c5d6e7"])
            == .unsupportedSSID
    )
}

@Test func manualCredentialsAcceptFutureSSIDLayoutsAndStandardWPAPassphrases() {
    let creds = CameraWiFiScreenParser.manualCredentials(
        ssid: "NIKON-Z-FUTURE-42",
        key: " camera-passphrase "
    )

    #expect(creds?.ssid == "NIKON-Z-FUTURE-42")
    #expect(creds?.key == " camera-passphrase ")
}

@Test func manualCredentialsRejectInvalidSSIDAndPassphraseLengths() {
    #expect(CameraWiFiScreenParser.manualCredentials(ssid: "", key: "12345678") == nil)
    #expect(CameraWiFiScreenParser.manualCredentials(ssid: "NIKONZ_8_X12345", key: "short") == nil)
    #expect(
        CameraWiFiScreenParser.manualCredentials(
            ssid: String(repeating: "N", count: 33),
            key: "12345678"
        ) == nil
    )
}
