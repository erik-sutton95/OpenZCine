import Foundation
import Testing

@testable import OpenZCineCore

/// The ObjectInfo wire ops can't be exercised without a ZR, so the byte-layout parse is what we lock
/// down here: a hand-built dataset matching the standard PTP ObjectInfo layout (52-byte fixed prefix
/// then PTP-string filename + capture/modification dates + keywords).
@Test func objectInfoParsesFixedFieldsAndStrings() throws {
    var bytes: [UInt8] = []
    bytes += le32(0x0001_0001)  // @0  StorageID
    bytes += le16(0x300D)  // @4  ObjectFormat (QT/movie-ish)
    bytes += le16(0)  // @6  ProtectionStatus
    bytes += le32(12_345_678)  // @8  ObjectCompressedSize
    bytes += le16(0x3801)  // @12 ThumbFormat
    bytes += le32(4096)  // @14 ThumbCompressedSize
    bytes += le32(160)  // @18 ThumbPixWidth
    bytes += le32(120)  // @22 ThumbPixHeight
    bytes += le32(1920)  // @26 ImagePixWidth
    bytes += le32(1080)  // @30 ImagePixHeight
    bytes += le32(24)  // @34 ImageBitDepth
    bytes += le32(0)  // @38 ParentObject
    bytes += le16(0)  // @42 AssociationType
    bytes += le32(0)  // @44 AssociationDesc
    bytes += le32(1)  // @48 SequenceNumber
    #expect(bytes.count == 52)  // fixed prefix ends here
    bytes += ptpString("C0001.MOV")  // @52 Filename
    bytes += ptpString("20260630T101500")  // CaptureDate
    bytes += ptpString("20260630T101530")  // ModificationDate
    bytes += ptpString("")  // Keywords

    let info = try PTPObjectInfo(Data(bytes))

    #expect(info.storageID == 0x0001_0001)
    #expect(info.objectFormat == 0x300D)
    #expect(info.compressedSize == 12_345_678)
    #expect(info.imagePixWidth == 1920)
    #expect(info.imagePixHeight == 1080)
    #expect(info.filename == "C0001.MOV")
    #expect(info.captureDate == "20260630T101500")
}

@Test func objectInfoThrowsOnTruncatedDataset() {
    // Fixed prefix needs 52 bytes before the filename string even begins.
    #expect(throws: PTPObjectInfoError.truncatedDataset) {
        try PTPObjectInfo(Data([UInt8](repeating: 0, count: 40)))
    }
    // Full fixed prefix but the filename string claims more bytes than remain.
    var truncatedName = [UInt8](repeating: 0, count: 52)
    truncatedName += [10]  // PTP string declares 10 code units…
    truncatedName += le16(0x0043)  // …but only one follows.
    #expect(throws: PTPObjectInfoError.truncatedDataset) {
        try PTPObjectInfo(Data(truncatedName))
    }
}

@Test func objectInfoClassifiesMoviesBestEffort() throws {
    // A movie by both filename extension and a movie object-format code.
    let movie = try PTPObjectInfo(Data(objectInfoFixture(format: 0x300D, filename: "C0001.MOV")))
    #expect(movie.isMovie)
    // A still by a JPEG object-format code and extension.
    let still = try PTPObjectInfo(Data(objectInfoFixture(format: 0x3801, filename: "DSC_0001.JPG")))
    #expect(!still.isMovie)
    #expect(still.isStillImage)
    // An MP4 recognised by extension even if the (unknown ZR) format code isn't in our set.
    let mp4 = try PTPObjectInfo(Data(objectInfoFixture(format: 0x0000, filename: "MOV_9999.MP4")))
    #expect(mp4.isMovie)
    #expect(!mp4.isStillImage)
}

@Test func objectInfoClassifiesStillsByExtension() throws {
    let nef = try PTPObjectInfo(Data(objectInfoFixture(format: 0x0000, filename: "DSC_0001.NEF")))
    #expect(nef.isStillImage)
    #expect(nef.isMediaLibraryObject)
    let heif = try PTPObjectInfo(Data(objectInfoFixture(format: 0x0000, filename: "IMG_0001.HEIC")))
    #expect(heif.isStillImage)
}

// MARK: - Fixture helpers

/// Builds a minimal valid ObjectInfo dataset: the 52-byte fixed prefix (only format set) followed by
/// the four PTP strings, so tests can vary just the format code and filename.
private func objectInfoFixture(format: UInt16, filename: String) -> [UInt8] {
    var bytes = [UInt8](repeating: 0, count: 52)
    bytes.replaceSubrange(4..<6, with: le16(format))
    bytes += ptpString(filename)
    bytes += ptpString("")  // CaptureDate
    bytes += ptpString("")  // ModificationDate
    bytes += ptpString("")  // Keywords
    return bytes
}

private func ptpString(_ value: String) -> [UInt8] {
    guard !value.isEmpty else { return [0] }
    var bytes = [UInt8(value.utf16.count + 1)]
    for unit in value.utf16 {
        bytes += ByteCoding.uint16LE(unit)
    }
    bytes += [0, 0]
    return bytes
}

private func le16(_ value: UInt16) -> [UInt8] { ByteCoding.uint16LE(value) }
private func le32(_ value: UInt32) -> [UInt8] { ByteCoding.uint32LE(value) }
