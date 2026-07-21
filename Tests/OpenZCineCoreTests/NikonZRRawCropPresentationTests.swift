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
