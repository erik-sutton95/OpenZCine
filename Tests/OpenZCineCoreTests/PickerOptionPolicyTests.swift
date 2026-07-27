// The picker option lists must mirror the connected body, not a hard-coded union of the Nikon Z
// lineup (#274, #276).
//
// Two field reports, one defect. A Zf was offered U1/U2/U3 it does not have; a Z6III's drive wheel
// read Single/CH/CL/CH+ where the body reads Single/CL/CH/CH+; "3D tracking" showed as "Subject",
// which is a different Nikon setting; and the H.265 row collapsed the body's 8-bit and 10-bit
// values into one option, so returning to H.265 silently wrote 8-bit.
//
// Erik has a Z6III, a Z5II and a ZR to test against — but NO Zf, so the Zf case is proven here at
// the descriptor level rather than deferred to hardware.

import Foundation
import Testing

@testable import OpenZCineCore

// MARK: - #276 · codec identity is the raw value, never the label

/// The Z6III's `MovFileType` enum: both H.265 depths plus a single-variant family.
/// codec byte << 16 | depth << 8 | container.
private let z6iiiFileTypeEnum: [UInt32] = [
    0x0000_0801,  // H.264  8-bit MP4
    0x0001_0800,  // H.265  8-bit MOV
    0x0001_0A00,  // H.265 10-bit MOV
]

@Test func bothAdvertisedHEVCDepthsSurviveAsDistinctOptions() {
    let modes = PTPCameraPropertyDecoders.fileTypeModes(fromEnum: z6iiiFileTypeEnum)

    // Three advertised values, three rows. The old dedupe-by-label kept two.
    #expect(modes.count == 3)
    #expect(modes.map(\.raw) == z6iiiFileTypeEnum)
    // Distinct raws never share a row, and the colliding family carries its bit depth.
    #expect(Set(modes.map(\.label)).count == modes.count)
    #expect(modes.map(\.label) == ["H.264", "H.265 8-bit", "H.265 10-bit"])
}

@Test func aSingleVariantFamilyKeepsItsShortBarLabel() {
    // Widening only happens on collision, so the ZR's codecs read the way the bar reads them.
    let modes = PTPCameraPropertyDecoders.fileTypeModes(
        fromEnum: [0x0031_0A03, 0x0002_0C02, 0x0001_0A01])
    #expect(modes.map(\.label) == ["R3D NE", "N-RAW", "H.265"])
}

@Test func selectingTenBitWritesTheAdvertisedTenBitValueNotTheEightBitOne() {
    let modes = PTPCameraPropertyDecoders.fileTypeModes(fromEnum: z6iiiFileTypeEnum)

    // The label the operator picked resolves to exactly one advertised value — the shells'
    // write path is this lookup.
    let picked = try! #require(modes.first { $0.label == "H.265 10-bit" })
    #expect(picked.raw == 0x0001_0A00)
    let write = PTPCameraPropertyWrite.fileType(raw: picked.raw)
    #expect(write.property == .movieFileType)
    #expect(write.data == Data(ByteCoding.uint32LE(0x0001_0A00)))

    // Round trip: the body echoes that value back, the snapshot decodes it, and reopening the
    // picker resolves the readback to the SAME row. This is the #276 cycle end to end.
    let readback = PTPCameraPropertySnapshot().applying(
        property: .movieFileType, data: write.data)
    #expect(readback.fileType == "H.265 10-bit MOV")
    let reopened = PTPCameraPropertyDecoders.fileTypeMode(
        forFileType: readback.fileType, in: modes)
    #expect(reopened?.raw == 0x0001_0A00)
    #expect(reopened?.label == "H.265 10-bit")
}

@Test func leavingHEVCAndReturningLandsBackOnTenBit() {
    // The exact reported sequence: H.265 10-bit -> H.264 -> H.265 10-bit.
    let modes = PTPCameraPropertyDecoders.fileTypeModes(fromEnum: z6iiiFileTypeEnum)
    var snapshot = PTPCameraPropertySnapshot()

    for label in ["H.265 10-bit", "H.264", "H.265 10-bit"] {
        let mode = try! #require(modes.first { $0.label == label })
        snapshot = snapshot.applying(
            property: .movieFileType, data: PTPCameraPropertyWrite.fileType(raw: mode.raw).data)
    }
    // 10-bit, not the 8-bit value that used to own the single "H.265" row.
    #expect(snapshot.fileType == "H.265 10-bit MOV")
    #expect(
        PTPCameraPropertyDecoders.fileTypeMode(forFileType: snapshot.fileType, in: modes)?.raw
            == 0x0001_0A00)
}

@Test func aCodecTheBodyNeverAdvertisedResolvesToNothingRatherThanTheWrongDepth() {
    let modes = PTPCameraPropertyDecoders.fileTypeModes(fromEnum: z6iiiFileTypeEnum)
    // A stale ambiguous label must not silently match a depth. No write beats a wrong write.
    #expect(modes.first { $0.label == "H.265" } == nil)
    #expect(
        PTPCameraPropertyDecoders.fileTypeMode(forFileType: "ProRes 422 HQ 10-bit MOV", in: modes)
            == nil)
    #expect(PTPCameraPropertyDecoders.fileTypeMode(forFileType: nil, in: modes) == nil)
}

@Test func unrecognisedCodecBytesAreNeverOfferedAsAWriteTarget() {
    // We cannot name it, so we must not offer to write it.
    let modes = PTPCameraPropertyDecoders.fileTypeModes(fromEnum: [0x0001_0A00, 0x00FE_0A00])
    #expect(modes.map(\.raw) == [0x0001_0A00])
}

@Test func aRepeatedAdvertisedValueStillYieldsOneRow() {
    // Duplicate raws are the body repeating itself, not two options.
    let modes = PTPCameraPropertyDecoders.fileTypeModes(
        fromEnum: [0x0001_0A00, 0x0001_0A00, 0x0001_0800])
    #expect(modes.map(\.raw) == [0x0001_0A00, 0x0001_0800])
    #expect(modes.map(\.label) == ["H.265 10-bit", "H.265 8-bit"])
}

// MARK: - #276 follow-up · one codec row, the advertised depths beside it

@Test func aFamilyAdvertisedAtTwoDepthsBecomesOneRowCarryingBoth() {
    let families = PTPCameraPropertyDecoders.codecFamilies(
        PTPCameraPropertyDecoders.fileTypeModes(fromEnum: z6iiiFileTypeEnum))

    // H.264 keeps a plain row; the two H.265 values collapse into one row with a depth choice.
    #expect(families.map(\.label) == ["H.264", "H.265"])
    #expect(families.map(\.offersBitDepthChoice) == [false, true])
    let hevc = try! #require(families.last)
    // Lower depth first: the picker puts 8-bit on the left, 10-bit on the right.
    #expect(hevc.depths.map(\.bitDepth) == [8, 10])
    #expect(hevc.depths.map(\.bitDepthLabel) == ["8-bit", "10-bit"])
    #expect(hevc.depths.map(\.raw) == [0x0001_0800, 0x0001_0A00])
}

@Test func aSingleVariantFamilyGetsNoDepthButtonsAndKeepsItsOwnRow() {
    // Never show a depth button the body cannot honour — a one-variant family is a plain row,
    // and its row label is still the exact label its write resolves through.
    let modes = PTPCameraPropertyDecoders.fileTypeModes(
        fromEnum: [0x0031_0A03, 0x0002_0C02, 0x0001_0A01])
    let families = PTPCameraPropertyDecoders.codecFamilies(modes)
    #expect(families.map(\.label) == ["R3D NE", "N-RAW", "H.265"])
    #expect(families.allSatisfy { !$0.offersBitDepthChoice })
    #expect(families.flatMap { $0.depths.map(\.raw) } == modes.map(\.raw))
}

@Test func theDepthButtonWritesTheAdvertisedRawAndSurvivesAReopen() {
    let modes = PTPCameraPropertyDecoders.fileTypeModes(fromEnum: z6iiiFileTypeEnum)
    let families = PTPCameraPropertyDecoders.codecFamilies(modes)
    let hevc = try! #require(families.first { $0.label == "H.265" })

    // Tapping "10-bit" writes the advertised 10-bit value, byte for byte.
    let tenBit = try! #require(hevc.depths.last)
    let write = PTPCameraPropertyWrite.fileType(raw: tenBit.raw)
    #expect(write.data == Data(ByteCoding.uint32LE(0x0001_0A00)))

    // The body echoes it; closing and reopening the picker lands on the same row AND the same
    // depth, because both are resolved from the readback rather than remembered.
    let readback = PTPCameraPropertySnapshot().applying(
        property: .movieFileType, data: write.data)
    let reopened = PTPCameraPropertyDecoders.codecFamily(
        forFileType: readback.fileType, in: families)
    #expect(reopened?.label == "H.265")
    #expect(
        PTPCameraPropertyDecoders.fileTypeMode(forFileType: readback.fileType, in: modes)?.bitDepth
            == 10)
}

@Test func aFamilySplitByContainerRatherThanDepthStaysSeparateRows() {
    // Two H.265 10-bit values differing only by container: a depth button could not name either
    // of them unambiguously, so the row must not collapse.
    let families = PTPCameraPropertyDecoders.codecFamilies(
        PTPCameraPropertyDecoders.fileTypeModes(fromEnum: [0x0001_0A00, 0x0001_0A01]))
    #expect(families.count == 2)
    #expect(families.allSatisfy { !$0.offersBitDepthChoice })
    // Each row keeps the label `fileTypeModes` widened it to, which is already distinct.
    #expect(families.map(\.label) == ["H.265 10-bit", "H.265 10-bit MP4"])
    #expect(families.flatMap { $0.depths.map(\.raw) } == [0x0001_0A00, 0x0001_0A01])
}

@Test func aThreeDepthFamilyDegradesToPlainRowsRatherThanHidingOne() {
    // The affordance is a pair; three depths would leave one unreachable. Falling back to the
    // widened per-value rows keeps every advertised depth selectable.
    let families = PTPCameraPropertyDecoders.codecFamilies(
        PTPCameraPropertyDecoders.fileTypeModes(
            fromEnum: [0x0001_0800, 0x0001_0A00, 0x0001_0C00]))
    #expect(families.map(\.label) == ["H.265 8-bit", "H.265 10-bit", "H.265 12-bit"])
    #expect(families.allSatisfy { !$0.offersBitDepthChoice })
}

@Test func aCodecTheBodyNeverAdvertisedResolvesToNoRow() {
    let families = PTPCameraPropertyDecoders.codecFamilies(
        PTPCameraPropertyDecoders.fileTypeModes(fromEnum: z6iiiFileTypeEnum))
    #expect(
        PTPCameraPropertyDecoders.codecFamily(forFileType: "N-RAW 12-bit NEV", in: families) == nil)
    #expect(PTPCameraPropertyDecoders.codecFamily(forFileType: nil, in: families) == nil)
}

// MARK: - #274 · the body's values, in the body's order

@Test func zfIsNeverOfferedUserBanksItDoesNotHave() {
    // A Zf's `ExposureProgramMode` enum: no U banks anywhere in it.
    let zf: [UInt32] = [0x8010, 0x0002, 0x0004, 0x0003, 0x0001]
    let options = PTPCameraPropertyDecoders.optionLabels(
        for: .exposureProgramMode, rawValues: zf)

    #expect(options == ["Auto", "P", "S", "A", "M"])
    #expect(!options.contains { $0.hasPrefix("U") })
    // And the fallback a body without a descriptor gets is equally bank-free.
    #expect(
        !PTPCameraPropertyDecoders.exposureProgramFallbackOptions.contains { $0.hasPrefix("U") })
}

@Test func aBodyThatAdvertisesUserBanksStillGetsThem() {
    // The rule is "only what the body advertises", not "never user banks".
    let withBanks: [UInt32] = [0x0002, 0x0004, 0x0003, 0x0001, 0x8050, 0x8051, 0x8052]
    #expect(
        PTPCameraPropertyDecoders.optionLabels(for: .exposureProgramMode, rawValues: withBanks)
            == ["P", "S", "A", "M", "U1", "U2", "U3"])
}

@Test func sceneOnlyProgramsStayOutOfTheModeDrum() {
    // Decodable but not writable through this control — offering them would be a lie.
    let withScenes: [UInt32] = [0x0001, 0x8011, 0x8014, 0x8018]
    #expect(
        PTPCameraPropertyDecoders.optionLabels(for: .exposureProgramMode, rawValues: withScenes)
            == ["M"])
}

@Test func driveModesKeepTheBodysReleaseOrder() {
    // The Z6III advertises Single, CL, CH, CH+ — in that order. The app used to render its own.
    let z6iii: [UInt32] = [0x0001, 0x8010, 0x0002, 0x8019]
    #expect(
        PTPCameraPropertyDecoders.optionLabels(for: .stillCaptureMode, rawValues: z6iii)
            == ["Single", "Continuous L", "Continuous H", "Continuous H+"])
}

@Test func theDriveFallbackAlsoReadsInNikonOrder() {
    // No descriptor: the fallback must not reintroduce the CH-before-CL ordering (#274).
    let fallback = StillDriveMode.allCases
        .filter { $0 != .quickSetting && $0 != .selfTimer }
        .map(\.label)
    #expect(
        fallback == [
            "Single", "Continuous L", "Continuous H", "Continuous H+",
            "C15", "C30", "C60", "C120",
        ])
}

@Test func aBodyWithHighSpeedCaptureGetsItAfterTheContinuousPositions() {
    let z8: [UInt32] = [0x0001, 0x8010, 0x0002, 0x8019, 0x810F, 0x811E, 0x813C, 0x8178]
    #expect(
        PTPCameraPropertyDecoders.optionLabels(for: .stillCaptureMode, rawValues: z8)
            == [
                "Single", "Continuous L", "Continuous H", "Continuous H+",
                "C15", "C30", "C60", "C120",
            ])
}

@Test func driveValuesTheLineupDoesNotDefineAreDropped() {
    #expect(
        PTPCameraPropertyDecoders.optionLabels(
            for: .stillCaptureMode, rawValues: [0x0001, 0xBEEF])
            == ["Single"])
}

@Test func focusAreaAndSubjectDetectionStayDistinctControls() {
    // Two Nikon settings that share nothing but a word. Neither list may name the other's rows.
    let areas = PTPCameraPropertyDecoders.optionLabels(
        for: .stillFocusMeteringMode,
        rawValues: [0x8017, 0x8010, 0x0002, 0x8013, 0x8014, 0x8012, 0x8033, 0x8011])
    let subjects = PTPCameraPropertyDecoders.optionLabels(
        for: .afSubjectDetection, rawValues: [0, 1, 2, 3, 4, 5, 6])

    #expect(areas.contains("3D tracking"))
    #expect(areas.contains("Subject tracking"))
    #expect(!areas.contains("Subject"))
    #expect(subjects == ["Off", "Auto", "People", "Animal", "Vehicle", "Bird", "Airplane"])
    #expect(
        Set(areas).isDisjoint(with: Set(subjects)) || Set(areas).intersection(subjects) == ["Auto"])
    // Every area label round-trips to its own raw, so a rename cannot cross the two spaces.
    #expect(PTPCameraPropertyDecoders.stillFocusAreaCode(for: "3D tracking") == 0x8012)
    #expect(PTPCameraPropertyDecoders.stillFocusAreaCode(for: "Subject tracking") == 0x8033)
    #expect(PTPCameraPropertyDecoders.stillFocusAreaCode(for: "Subject") == nil)
}

@Test func subjectTrackingReleaseSurvivesTheLabelRename() {
    // The focus-reset release used to compare against the literal "Subject"; going through the
    // decoder means a future rename cannot silently disarm it.
    #expect(PTPCameraPropertyDecoders.isSubjectTrackingArea("Subject tracking"))
    #expect(!PTPCameraPropertyDecoders.isSubjectTrackingArea("Single"))
    #expect(!PTPCameraPropertyDecoders.isSubjectTrackingArea(nil))
    #expect(
        FocusResetReleasePolicy.shouldDemoteSubjectArea(
            focusArea: PTPCameraPropertyDecoders.movieFocusArea(0x8033), liveViewFocus: nil))
}

@Test func everyOfferedFunctionOptionCanBeWrittenBack() {
    // Selecting a listed option must always produce a write. A row that encodes to nothing is an
    // option the operator can pick and lose.
    let cases: [(PTPPropertyCode, [UInt32], PTPCameraControl)] = [
        (.stillCaptureMode, [0x0001, 0x8010, 0x0002, 0x8019], .stillDrive),
        (.exposureProgramMode, [0x8010, 0x0002, 0x0004, 0x0003, 0x0001], .exposureMode),
        (.exposureMeteringMode, [0x0003, 0x0002, 0x0004, 0x8010], .stillMeter),
        (.flashMode, [0x0002, 0x8010, 0x8011, 0x8012], .stillFlash),
        (.compressionSetting, [4, 7, 12], .stillQuality),
        (.rawCompressionType, [0, 3, 4], .stillRawCompression),
        (.activePicCtrlItem, [1, 7, 104, 201], .stillPictureControl),
        (.stillFocusMode, [0, 1, 5, 4], .stillFocus),
        (.stillFocusMeteringMode, [0x8017, 0x8010, 0x8012, 0x8033], .stillFocusArea),
        (.afSubjectDetection, [0, 1, 2, 5], .stillFocusSubject),
        (.userMode, [19, 20, 21, 22], .stillUserModeProgram),
    ]
    for (property, rawValues, control) in cases {
        let options = PTPCameraPropertyDecoders.optionLabels(
            for: property, rawValues: rawValues)
        #expect(options.count == rawValues.count, "\(property) dropped an advertised value")
        for option in options {
            #expect(
                PTPCameraPropertyWrite.request(control: control, label: option) != nil,
                "\(property) offers \(option) but cannot write it")
        }
    }
}

@Test func pictureControlOffersOnlyTheSlotsTheBodyRegistered() {
    // An empty custom slot is not an option; the body simply never lists it.
    #expect(
        PTPCameraPropertyDecoders.optionLabels(
            for: .activePicCtrlItem, rawValues: [1, 2, 201, 203])
            == ["Standard", "Neutral", "Custom 1", "Custom 3"])
}

// MARK: - Camera replacement rebuilds from scratch

@Test func swappingBodiesRebuildsEveryListFromTheNewDescriptors() {
    // A ZR (RAW codecs, movie AF areas) replaced by a Z6III (H.26x, stills AF areas). Nothing of
    // the first body may survive into the second body's lists.
    let zrCodecs = PTPCameraPropertyDecoders.fileTypeModes(
        fromEnum: [0x0031_0A03, 0x0002_0C02, 0x0001_0A01])
    let zrDrive = PTPCameraPropertyDecoders.optionLabels(
        for: .stillCaptureMode, rawValues: [0x0001])

    let z6Codecs = PTPCameraPropertyDecoders.fileTypeModes(fromEnum: z6iiiFileTypeEnum)
    let z6Drive = PTPCameraPropertyDecoders.optionLabels(
        for: .stillCaptureMode, rawValues: [0x0001, 0x8010, 0x0002, 0x8019])

    #expect(Set(zrCodecs.map(\.label)).isDisjoint(with: ["H.265 8-bit", "H.265 10-bit"]))
    #expect(Set(z6Codecs.map(\.label)).isDisjoint(with: ["R3D NE", "N-RAW"]))
    #expect(zrDrive == ["Single"])
    #expect(z6Drive.count == 4)
    // The mapping is a pure function of the new body's descriptor — there is nowhere for a
    // previous body's list to be retained.
    #expect(
        PTPCameraPropertyDecoders.fileTypeModes(fromEnum: z6iiiFileTypeEnum).map(\.raw)
            == z6Codecs.map(\.raw))
}

@Test func aMissingDescriptorYieldsNothingRatherThanAGuess() {
    // Conservative: an empty enum produces an empty list, and the shells then fall back to their
    // own conservative ladder — never to an invented union.
    for property: PTPPropertyCode in [
        .stillCaptureMode, .exposureProgramMode, .exposureMeteringMode, .activePicCtrlItem,
        .stillFocusMeteringMode, .afSubjectDetection,
    ] {
        #expect(PTPCameraPropertyDecoders.optionLabels(for: property, rawValues: []).isEmpty)
    }
    #expect(PTPCameraPropertyDecoders.fileTypeModes(fromEnum: []).isEmpty)
}
