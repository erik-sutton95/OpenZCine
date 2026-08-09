import Testing

@testable import OpenZCineCore

@Test func zrRawCropLabelsDocumentedFXAndDXModesOnlyForRAWCodecs() {
    let fx6k = PTPCameraScreenSizeMode(
        raw: UInt64(6_048) << 48 | UInt64(3_402) << 32 | UInt64(25) << 16,
        label: "6K · 25p")
    let dx4k = PTPCameraScreenSizeMode(
        raw: UInt64(3_984) << 48 | UInt64(2_240) << 32 | UInt64(100) << 16,
        label: "4K · 100p")
    let bare4k = PTPCameraScreenSizeMode(
        raw: UInt64(3_840) << 48 | UInt64(2_160) << 32 | UInt64(25) << 16,
        label: "4K · 25p")

    #expect(
        NikonZRRawCropPresentation.label(
            for: fx6k, currentCodec: "R3D NE", isNikonZR: true) == "[FX] 6K · 25p")
    #expect(
        NikonZRRawCropPresentation.label(
            for: dx4k, currentCodec: "N-RAW 12-bit N-RAW", isNikonZR: true) == "[DX] 4K · 100p")
    // Undocumented pixel sizes stay generic even on ZR RAW.
    #expect(
        NikonZRRawCropPresentation.label(
            for: bare4k, currentCodec: "R3D NE", isNikonZR: true) == "4K · 25p")
    // Non-RAW and non-ZR keep generic labels.
    #expect(
        NikonZRRawCropPresentation.label(
            for: fx6k, currentCodec: "H.265", isNikonZR: true) == "6K · 25p")
    #expect(
        NikonZRRawCropPresentation.label(
            for: fx6k, currentCodec: "R3D NE", isNikonZR: false) == "6K · 25p")
}

@Test func bareLabelStripsCropPrefixAndNormalizesSpacing() {
    #expect(NikonZRRawCropPresentation.bareLabel("[FX] 6K · 25p") == "6K·25p")
    #expect(NikonZRRawCropPresentation.bareLabel("  6K  ·  25p ") == "6K·25p")
    #expect(NikonZRRawCropPresentation.bareLabel("[DX]4K · 100p") == "4K·100p")
}

@Test func liveReadoutLabelUsesPackedRawWhenPresent() {
    let raw = UInt64(6_048) << 48 | UInt64(3_402) << 32 | UInt64(25) << 16
    #expect(
        NikonZRRawCropPresentation.label(
            baseLabel: "6K · 25p",
            rawScreenSize: raw,
            currentCodec: "R3D NE",
            isNikonZR: true) == "[FX] 6K · 25p")
    #expect(
        NikonZRRawCropPresentation.label(
            baseLabel: "6K · 25p",
            rawScreenSize: nil,
            currentCodec: "R3D NE",
            isNikonZR: true) == "6K · 25p")
}

/// The DX crop is the ONLY thing separating two modes whose bare labels are identical, so a match
/// that strips the tag picks whichever is listed first — which is how tapping `[DX] 4K · 25p` set
/// the body to FX 4K·25p on hardware.
@Test func pickingADXModeNeverLandsOnTheFXOneAboveIt() {
    let presentation = ["[FX] 6K · 25p", "[FX] 4K · 25p", "[DX] 4K · 25p"]
    let camera = ["6K · 25p", "4K · 25p", "4K · 25p"]

    #expect(
        NikonZRRawCropPresentation.pickedModeIndex(
            for: "[DX] 4K · 25p", presentationLabels: presentation, modeLabels: camera) == 2)
    #expect(
        NikonZRRawCropPresentation.pickedModeIndex(
            for: "[FX] 4K · 25p", presentationLabels: presentation, modeLabels: camera) == 1)
}

/// A label with no crop tag still matches loosely — that fallback is what carries non-RAW codecs,
/// where the camera advertises no image area and the picker shows a bare label.
@Test func anUntaggedPickStillMatchesOnTheBareLabel() {
    let presentation = ["6K · 25p", "4K · 25p"]
    let camera = ["6K · 25p", "4K · 25p"]

    #expect(
        NikonZRRawCropPresentation.pickedModeIndex(
            for: "4K·25p", presentationLabels: presentation, modeLabels: camera) == 1)
}

/// A TAGGED pick that matches nothing is unanswerable rather than approximated: dropping the tag
/// to find "something close" is exactly the behaviour that wrote the wrong crop to the camera.
@Test func aTaggedPickWithNoExactMatchIsRefused() {
    let presentation = ["[FX] 4K · 25p"]
    let camera = ["4K · 25p"]

    #expect(
        NikonZRRawCropPresentation.pickedModeIndex(
            for: "[DX] 4K · 25p", presentationLabels: presentation, modeLabels: camera) == nil)
}

/// Mismatched inputs are a programming error, not something to guess through.
@Test func mismatchedLabelCountsMatchNothing() {
    #expect(
        NikonZRRawCropPresentation.pickedModeIndex(
            for: "4K · 25p", presentationLabels: ["4K · 25p"], modeLabels: []) == nil)
}
