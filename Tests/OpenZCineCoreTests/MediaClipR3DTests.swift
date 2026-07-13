import Foundation
import Testing

@testable import OpenZCineCore

@Test func filenameStemMatchesCaseInsensitiveExtensions() {
    #expect(
        MediaClipFilename.stem(of: "A002_C046_0630SB.R3D")
            == MediaClipFilename.stem(of: "a002_c046_0630sb.MP4"))
    #expect(MediaClipFilename.stem(of: "C0001.MOV") == "C0001")
}

@Test func filenameHelpersClassifyR3DAndProxies() {
    #expect(MediaClipFilename.isR3D("TAKE_01.R3D"))
    #expect(MediaClipFilename.isR3D("take.r3d"))
    #expect(!MediaClipFilename.isR3D("TAKE_01.MP4"))
    #expect(MediaClipFilename.isPlayableProxy("clip.MP4"))
    #expect(MediaClipFilename.isPlayableProxy("clip.mov"))
    #expect(!MediaClipFilename.isPlayableProxy("clip.R3D"))
    #expect(MediaClipFilename.isPhoto("DSC_0001.JPG"))
    #expect(MediaClipFilename.isPhoto("still.heic"))
    #expect(!MediaClipFilename.isPhoto("clip.MP4"))
}

@Test func cameraMediaBasenameAcceptsOrdinaryUnicodeNames() {
    #expect(MediaClipFilename.safeCameraBasename("A002_C046_0630SB.MP4") != nil)
    #expect(MediaClipFilename.safeCameraBasename("Scene 12 – Göteborg.MOV") != nil)
}

@Test func cameraMediaBasenameRejectsTraversalAndPathSeparators() {
    for filename in [
        "../outside.mp4",
        "folder/clip.mp4",
        "folder\\clip.mp4",
        ".",
        "..",
    ] {
        #expect(MediaClipFilename.safeCameraBasename(filename) == nil)
    }
}

@Test func cameraMediaBasenameRejectsControlCharacters() {
    for filename in ["clip\n.mp4", "clip\r.mp4", "clip\t.mp4", "clip\0.mp4"] {
        #expect(MediaClipFilename.safeCameraBasename(filename) == nil)
    }
}

@Test func r3dIndexPairsProxyWithSiblingByStem() {
    var index = R3DClipIndex()
    index.registerR3D(filename: "A002_C046_0630SB.R3D", width: 6048, height: 3402)
    index.noteProxy("A002_C046_0630SB.MP4")

    let sibling = index.siblingForProxy("a002_c046_0630sb.mp4")
    #expect(sibling?.filename == "A002_C046_0630SB.R3D")
    #expect(sibling?.width == 6048)
    #expect(sibling?.height == 3402)
    #expect(index.hasProxy(forR3DFilename: "A002_C046_0630SB.R3D"))
}

@Test func playableProxyStemsHideLinkedR3DMasters() {
    let filenames = ["A002.MP4", "A002.R3D", "B003.R3D"]
    let stems = MediaClipFilename.playableProxyStems(in: filenames)
    #expect(stems.contains("A002"))
    #expect(
        !MediaClipFilename.shouldShowInMediaBrowser(
            filename: "A002.R3D", playableProxyStems: stems))
    #expect(
        MediaClipFilename.shouldShowInMediaBrowser(
            filename: "B003.R3D", playableProxyStems: stems))
}

@Test func standaloneR3DRemainsVisibleWithoutProxy() {
    let stems = MediaClipFilename.playableProxyStems(in: ["B003.R3D"])
    #expect(stems.isEmpty)
    #expect(
        MediaClipFilename.shouldShowInMediaBrowser(filename: "B003.R3D", playableProxyStems: stems))
}

@Test func resolutionBucketUsesSourceDimensionsForProxies() {
    // 1080p proxy linked to 6K R3D should bucket as 6K, not HD.
    let bucket = MediaResolutionBucket.classify(
        filename: "A002.MP4",
        pixelWidth: 1920,
        sourcePixelWidth: 6048)
    #expect(bucket == .sixK)
}

@Test func resolutionBucketFallsBackToProxyPixelsThenFilename() {
    #expect(
        MediaResolutionBucket.classify(
            filename: "clip.MP4", pixelWidth: 3840, sourcePixelWidth: nil) == .fourK)
    #expect(
        MediaResolutionBucket.classify(
            filename: "SHOT_6K.MP4", pixelWidth: nil, sourcePixelWidth: nil) == .sixK)
}

@Test func resolutionBucketWidthThresholds() {
    #expect(MediaResolutionBucket.from(pixelWidth: 1920) == .hd)
    #expect(MediaResolutionBucket.from(pixelWidth: 3840) == .fourK)
    #expect(MediaResolutionBucket.from(pixelWidth: 5456) == .fiveFourK)
    #expect(MediaResolutionBucket.from(pixelWidth: 6048) == .sixK)
}

@Test func r3dHeaderParserReadsRED1Dimensions() throws {
    var bytes = [UInt8](repeating: 0, count: 60)
    bytes[4] = 0x52
    bytes[5] = 0x45
    bytes[6] = 0x44
    bytes[7] = 0x31  // "RED1"
    bytes[52] = 0x00
    bytes[53] = 0x00
    bytes[54] = 0x17
    bytes[55] = 0xA0  // 6048
    bytes[56] = 0x00
    bytes[57] = 0x00
    bytes[58] = 0x0D
    bytes[59] = 0x4A  // 3402

    let parsed = R3DHeaderParser.parseRED1Dimensions(from: Data(bytes))
    #expect(parsed?.width == 6048)
    #expect(parsed?.height == 3402)
}

@Test func objectInfoClassifiesR3DForMediaLibrary() throws {
    let r3d = try PTPObjectInfo(
        Data(objectInfoFixture(format: 0x0000, filename: "A002_C046_0630SB.R3D")))
    #expect(r3d.isR3D)
    #expect(r3d.isMediaLibraryObject)
    #expect(!r3d.isMovie)
}

// MARK: - Fixture helpers

private func objectInfoFixture(format: UInt16, filename: String) -> [UInt8] {
    var bytes = [UInt8](repeating: 0, count: 52)
    bytes.replaceSubrange(4..<6, with: ByteCoding.uint16LE(format))
    bytes += ptpString(filename)
    bytes += ptpString("")
    bytes += ptpString("")
    bytes += ptpString("")
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
