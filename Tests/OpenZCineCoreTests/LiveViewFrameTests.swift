import Foundation
import Testing

@testable import OpenZCineCore

private func liveViewObject(declaredLength: UInt32, jpeg: [UInt8]) -> Data {
    var bytes = [UInt8](repeating: 0, count: PTPLiveViewObject.headerLength + jpeg.count)
    let declaredLengthBytes = ByteCoding.uint32LE(declaredLength)
    bytes.replaceSubrange(12..<16, with: declaredLengthBytes)
    bytes.replaceSubrange(
        PTPLiveViewObject.headerLength..<(PTPLiveViewObject.headerLength + jpeg.count),
        with: jpeg
    )
    return Data(bytes)
}

@Test func liveViewObjectExtractsJPEGAfterHeader() throws {
    let object = liveViewObject(
        declaredLength: 5,
        jpeg: [0xFF, 0xD8, 0xFF, 0xD9, 0x11]
    )

    let jpeg = try PTPLiveViewObject.jpeg(from: object)

    #expect(Array(jpeg) == [0xFF, 0xD8, 0xFF, 0xD9, 0x11])
}

@Test func liveViewObjectTrimsJPEGToDeclaredImageLength() throws {
    let object = liveViewObject(
        declaredLength: 4,
        jpeg: [0xFF, 0xD8, 0xFF, 0xD9, 0xAA, 0xBB]
    )

    let jpeg = try PTPLiveViewObject.jpeg(from: object)

    #expect(Array(jpeg) == [0xFF, 0xD8, 0xFF, 0xD9])
}

@Test func liveViewObjectThrowsWhenTooShort() {
    #expect(throws: PTPLiveViewObjectError.tooShort(actualLength: 100)) {
        try PTPLiveViewObject.jpeg(from: Data(repeating: 0, count: 100))
    }
}

@Test func liveViewObjectThrowsWithoutJPEGSoiAtImageStart() {
    let object = liveViewObject(declaredLength: 0, jpeg: [0x00, 0x00, 0x00])

    #expect(throws: PTPLiveViewObjectError.missingJPEGSoi(offset: 1_024)) {
        try PTPLiveViewObject.jpeg(from: object)
    }
}

@Test func liveViewObjectParsesHeaderTimecode() {
    var object = Data(repeating: 0, count: PTPLiveViewObject.headerLength + 3)
    object[831] = 1
    object[832] = 1
    object[833] = 23
    object[834] = 45
    object[835] = 12

    let timecode = PTPLiveViewObject.timecode(from: object)

    #expect(timecode.on)
    #expect(timecode.label == "01:23:45:12")
}

@Test func liveViewObjectReturnsOffTimecodeWhenHeaderIsTooShort() {
    let timecode = PTPLiveViewObject.timecode(from: Data(repeating: 0, count: 10))

    #expect(!timecode.on)
    #expect(timecode.label == "00:00:00:00")
}

@Test func liveViewObjectParsesSoundIndicator() throws {
    // Peak L/R at 824/825, current L/R at 826/827, one byte each, 0–14 segments.
    var bytes = [UInt8](repeating: 0, count: PTPLiveViewObject.headerLength)
    bytes[824] = 11
    bytes[825] = 12
    bytes[826] = 7
    bytes[827] = 9

    let sound = try #require(PTPLiveViewObject.soundIndicator(from: Data(bytes)))
    #expect(sound.peakLeft == 11)
    #expect(sound.peakRight == 12)
    #expect(sound.currentLeft == 7)
    #expect(sound.currentRight == 9)
}

@Test func liveViewObjectClampsSoundIndicatorToDocumentedCeiling() throws {
    var bytes = [UInt8](repeating: 0, count: PTPLiveViewObject.headerLength)
    bytes[824] = 200  // a misreported byte must not inflate the meter scale
    bytes[826] = 14

    let sound = try #require(PTPLiveViewObject.soundIndicator(from: Data(bytes)))
    #expect(sound.peakLeft == 14)
    #expect(sound.currentLeft == 14)
}

@Test func liveViewObjectReturnsNilSoundIndicatorForShortHeader() {
    #expect(PTPLiveViewObject.soundIndicator(from: Data(repeating: 0, count: 500)) == nil)
}

@Test func audioMeterLevelsMapCameraSegmentsOntoTheDBFSScale() {
    // Segment 0 = meter floor, 14 = 0 dBFS, even dB spacing between.
    let silent = AudioMeterLevels(
        cameraIndicator: PTPLiveViewSoundIndicator(
            peakLeft: 0, peakRight: 0, currentLeft: 0, currentRight: 0))
    #expect(silent.left.levelDB == AudioMeterBallistics.floorDB)
    #expect(silent.right.peakDB == AudioMeterBallistics.floorDB)

    let hot = AudioMeterLevels(
        cameraIndicator: PTPLiveViewSoundIndicator(
            peakLeft: 14, peakRight: 7, currentLeft: 14, currentRight: 7))
    #expect(hot.left.levelDB == 0)
    #expect(abs(hot.right.levelDB - AudioMeterBallistics.floorDB / 2) < 0.001)
    #expect(hot.left.peakDB == 0)
}

@Test func liveViewObjectParsesFocusBoxes() throws {
    // Big-endian header; the box array at offset 48 holds [w, h, cx, cy] BE per box in the
    // whole-size space at 16/18. Mirrors a real ZR face-detected frame: a face box plus a small
    // square eye box, with the eye (box 1) selected.
    var bytes = [UInt8](repeating: 0, count: PTPLiveViewObject.headerLength)
    func put16BE(_ value: Int, at offset: Int) {
        bytes.replaceSubrange(offset..<(offset + 2), with: ByteCoding.uint16BE(UInt16(value)))
    }
    func putBox(_ width: Int, _ height: Int, _ centerX: Int, _ centerY: Int, at offset: Int) {
        put16BE(width, at: offset)
        put16BE(height, at: offset + 2)
        put16BE(centerX, at: offset + 4)
        put16BE(centerY, at: offset + 6)
    }
    put16BE(6048, at: 16)  // whole-size width
    put16BE(3400, at: 18)  // whole-size height
    bytes[42] = 2  // focus result: focused
    bytes[43] = 1  // subject detection active
    bytes[44] = 2  // area count
    bytes[45] = 1  // selected box: the eye
    putBox(815, 884, 3024, 1700, at: 48)  // box 0: face / AF area
    putBox(186, 186, 2835, 1491, at: 56)  // box 1: eye (small square)

    let focus = try #require(PTPLiveViewObject.focusInfo(from: Data(bytes)))
    #expect(focus.coordinateWidth == 6048)
    #expect(focus.coordinateHeight == 3400)
    #expect(focus.focusResult == .focused)
    #expect(focus.subjectDetectionActive)
    #expect(focus.selectedBoxIndex == 1)
    #expect(focus.boxes.count == 2)
    #expect(
        focus.boxes[0] == PTPLiveViewAFBox(centerX: 3024, centerY: 1700, width: 815, height: 884))
    #expect(
        focus.boxes[1] == PTPLiveViewAFBox(centerX: 2835, centerY: 1491, width: 186, height: 186))
}

@Test func liveViewObjectParsesTrackingAFStatus() throws {
    var bytes = [UInt8](repeating: 0, count: PTPLiveViewObject.headerLength)
    func put16BE(_ value: Int, at offset: Int) {
        bytes.replaceSubrange(offset..<(offset + 2), with: ByteCoding.uint16BE(UInt16(value)))
    }
    put16BE(6048, at: 16)
    put16BE(3400, at: 18)
    bytes[44] = 1
    bytes[46] = 1  // tracking-AF status byte active

    let focus = try #require(PTPLiveViewObject.focusInfo(from: Data(bytes)))
    #expect(focus.trackingAFActive)
    #expect(focus.isSubjectTrackingLatched)
}

@Test func liveViewObjectDropsEmptyAFFrames() throws {
    // areaCount claims 2 boxes but the second slot is zero-size → only the valid box survives.
    var bytes = [UInt8](repeating: 0, count: PTPLiveViewObject.headerLength)
    func put16BE(_ value: Int, at offset: Int) {
        bytes.replaceSubrange(offset..<(offset + 2), with: ByteCoding.uint16BE(UInt16(value)))
    }
    put16BE(6048, at: 16)
    put16BE(3400, at: 18)
    bytes[44] = 2  // claims 2 areas
    put16BE(815, at: 48)
    put16BE(884, at: 50)
    put16BE(2241, at: 52)
    put16BE(1984, at: 54)  // valid box 0
    // box 1 left zero-size → dropped
    let focus = try #require(PTPLiveViewObject.focusInfo(from: Data(bytes)))
    #expect(focus.boxes.count == 1)
}
