import Testing

@testable import OpenZCineCore

// MARK: - Resolution label

@Test func resolutionLabelDerivesClassFromPixelWidth() {
    #expect(
        MonitorTextFormat.resolutionLabel(pixelWidth: 6048, pixelHeight: 3402, frameRate: 23.976)
            == "6K · 24p")
    #expect(
        MonitorTextFormat.resolutionLabel(pixelWidth: 3840, pixelHeight: 2160, frameRate: 25.0)
            == "4K · 25p")
    #expect(
        MonitorTextFormat.resolutionLabel(pixelWidth: 7680, pixelHeight: 4320, frameRate: 30)
            == "8K · 30p")
}

@Test func resolutionLabelRoundsFractionalFrameRate() {
    #expect(
        MonitorTextFormat.resolutionLabel(pixelWidth: 6048, pixelHeight: 3402, frameRate: 29.97)
            == "6K · 30p")
    #expect(
        MonitorTextFormat.resolutionLabel(pixelWidth: 3840, pixelHeight: 2160, frameRate: 59.94)
            == "4K · 60p")
}

@Test func resolutionLabelFallsBackToWidthPixelsForUnknownClass() {
    // Sub-4K widths use the raw horizontal pixel count so the readout stays honest.
    #expect(
        MonitorTextFormat.resolutionLabel(pixelWidth: 1920, pixelHeight: 1080, frameRate: 24)
            == "1920 · 24p")
}

// MARK: - Media status

@Test func mediaCapacityLabelCombinesGigabytesAndPercent() {
    let status = MediaStatus(gigabytesFree: 521, percentFree: 47, minutesRemaining: 47)
    #expect(status.capacityLabel == "521 GB · 47%")
}

@Test func mediaDurationLabelUsesMinutes() {
    let status = MediaStatus(gigabytesFree: 521, percentFree: 47, minutesRemaining: 47)
    #expect(status.durationLabel == "47 Min")
}

// MARK: - Resolution label from camera property string

@Test func resolutionLabelParsesCameraPropertyDimensions() {
    // The PTP property arrives as a raw "WxH" string; the top bar shows the compact class.
    #expect(
        MonitorTextFormat.resolutionLabel(fromProperty: "6048x3402", frameRate: 25) == "6K · 25p")
    #expect(
        MonitorTextFormat.resolutionLabel(fromProperty: "3840x2160", frameRate: 30) == "4K · 30p")
}

@Test func resolutionLabelFallsBackWhenPropertyUnparsable() {
    #expect(
        MonitorTextFormat.resolutionLabel(fromProperty: nil, frameRate: 25, fallback: "6K · 25p")
            == "6K · 25p")
    #expect(
        MonitorTextFormat.resolutionLabel(fromProperty: "unexpected", frameRate: 25, fallback: "6K")
            == "6K")
}

// MARK: - Codec short label

@Test func codecShortLabelCollapsesRedundantSuffix() {
    // Camera reports "R3D NE 10-bit R3D"; the top bar shows the short family name.
    #expect(MonitorTextFormat.codecShortLabel("R3D NE 10-bit R3D") == "R3D NE")
    #expect(MonitorTextFormat.codecShortLabel("N-RAW 12-bit N-RAW") == "N-RAW")
}

@Test func codecShortLabelKeepsAlreadyShortNames() {
    #expect(MonitorTextFormat.codecShortLabel("ProRes RAW HQ") == "ProRes RAW HQ")
    #expect(MonitorTextFormat.codecShortLabel("R3D NE") == "R3D NE")
}

@Test func codecCompactLabelAbbreviatesFamiliesForTightReadouts() {
    #expect(MonitorTextFormat.codecCompactLabel("ProRes RAW HQ") == "PR RAW HQ")
    #expect(MonitorTextFormat.codecCompactLabel("ProRes 422 HQ") == "PR 422 HQ")
    #expect(MonitorTextFormat.codecCompactLabel("H.265 10-bit") == "H.265")
    #expect(MonitorTextFormat.codecCompactLabel("R3D NE") == "R3D NE")
    #expect(MonitorTextFormat.codecCompactLabel("N-RAW") == "N-RAW")
}

@Test func isRawCodecClassifiesRawFamilies() {
    #expect(MonitorTextFormat.isRawCodec("R3D NE"))
    #expect(MonitorTextFormat.isRawCodec("R3D NE 10-bit R3D"))
    #expect(MonitorTextFormat.isRawCodec("N-RAW"))
    #expect(MonitorTextFormat.isRawCodec("ProRes RAW HQ"))
    #expect(!MonitorTextFormat.isRawCodec("ProRes 422 HQ"))
    #expect(!MonitorTextFormat.isRawCodec("H.265"))
    #expect(!MonitorTextFormat.isRawCodec("H.264"))
    #expect(!MonitorTextFormat.isRawCodec(""))
}
