import Foundation
import Testing

@testable import OpenZCineCore

@Test func openSessionOperationRequestMatchesPTPWireBytes() {
    let payload = PTPOperationRequest(
        dataPhase: .noDataOrDataIn,
        operationCode: .openSession,
        transactionID: 0,
        parameters: [1]
    ).payloadBytes

    #expect(
        payload == [
            0x01, 0x00, 0x00, 0x00,
            0x02, 0x10,
            0x00, 0x00, 0x00, 0x00,
            0x01, 0x00, 0x00, 0x00,
        ])
}

@Test func operationResponseParsesCodeTransactionAndParameters() throws {
    let response = try PTPOperationResponse(payloadBytes: [
        0x01, 0x20,
        0x05, 0x00, 0x00, 0x00,
        0x09, 0x00, 0x00, 0x00,
    ])

    #expect(response.responseCode == .ok)
    #expect(response.transactionID == 5)
    #expect(response.parameters == [9])
}

@Test func startDataPayloadMatchesPTPIPWireBytes() {
    #expect(
        PTPDataPayloads.startData(transactionID: 5, totalLength: 1) == [
            0x05, 0x00, 0x00, 0x00,
            0x01, 0x00, 0x00, 0x00,
            0x00, 0x00, 0x00, 0x00,
        ])
}

@Test func endDataPayloadMatchesPTPIPWireBytes() {
    #expect(
        PTPDataPayloads.endData(transactionID: 5, data: Data([0x02])) == [
            0x05, 0x00, 0x00, 0x00,
            0x02,
        ])
}

@Test func setPropertyOperationRequestUsesDataOutAndPropertyParameter() {
    let payload = PTPOperationRequest(
        dataPhase: .dataOut,
        operationCode: .setDevicePropValueEx,
        transactionID: 7,
        parameters: [PTPPropertyCode.liveViewImageSize.rawValue]
    ).payloadBytes

    #expect(
        payload == [
            0x02, 0x00, 0x00, 0x00,
            0x3C, 0x94,
            0x07, 0x00, 0x00, 0x00,
            0xAC, 0xD1, 0x00, 0x00,
        ])
}

@Test func storageInfoDecodesCapacityAndFreeSpace() {
    func le64(_ value: UInt64) -> [UInt8] { (0..<8).map { UInt8((value >> ($0 * 8)) & 0xFF) } }
    // storageType + filesystemType + accessCapability (3 × u16), then maxCapacity + freeSpace (u64).
    let bytes: [UInt8] = [1, 0, 2, 0, 3, 0] + le64(1_000_000_000_000) + le64(500_000_000_000)
    let info = PTPStorageInfo(bytes)
    #expect(info?.gigabytesFree == 500)
    #expect(info?.gigabytesTotal == 1_000)
    #expect(info?.gigabytesUsed == 500)
    #expect(info?.percentFree == 50)
}

@Test func storageInfoDecodesOneTerabyteCardUsedAndFree() {
    func le64(_ value: UInt64) -> [UInt8] { (0..<8).map { UInt8((value >> ($0 * 8)) & 0xFF) } }
    // ~1 TB card: 1023 GB total, 429 GB free, 594 GB used (decimal GB).
    let totalBytes: UInt64 = 1_023_000_000_000
    let freeBytes: UInt64 = 429_000_000_000
    let bytes: [UInt8] = [4, 0, 3, 0, 1, 0] + le64(totalBytes) + le64(freeBytes)
    let info = PTPStorageInfo(bytes)
    #expect(info?.gigabytesTotal == 1_023)
    #expect(info?.gigabytesFree == 429)
    #expect(info?.gigabytesUsed == 594)
    #expect(info?.percentFree == 41)
}

@Test func storageInfoTreatsUnknownMaxCapacityAsZeroTotal() {
    func le64(_ value: UInt64) -> [UInt8] { (0..<8).map { UInt8((value >> ($0 * 8)) & 0xFF) } }
    let bytes: [UInt8] =
        [1, 0, 2, 0, 3, 0] + le64(PTPStorageInfo.unknownCapacityBytes) + le64(200_000_000_000)
    let info = PTPStorageInfo(bytes)
    #expect(info?.gigabytesTotal == 0)
    #expect(info?.gigabytesFree == 200)
    #expect(info?.percentFree == 0)
}

@Test func storageInfoRejectsShortPayload() {
    #expect(PTPStorageInfo([0, 0, 0, 0]) == nil)
}

@Test func storageIDsParsesCountThenIDs() {
    func le32(_ value: UInt32) -> [UInt8] { (0..<4).map { UInt8((value >> ($0 * 8)) & 0xFF) } }
    let bytes = le32(2) + le32(0x0001_0001) + le32(0x0002_0001)
    #expect(PTPStorageIDs.parse(bytes) == [0x0001_0001, 0x0002_0001])
    // Too short to hold the count.
    #expect(PTPStorageIDs.parse([1, 0]).isEmpty)
    // Count claims 3 but only one ID is present — return what's readable.
    #expect(PTPStorageIDs.parse(le32(3) + le32(0x0001_0001)) == [0x0001_0001])
}

@Test func storageIDsClampOversizedDeclaredCount() {
    func le32(_ value: UInt32) -> [UInt8] { (0..<4).map { UInt8((value >> ($0 * 8)) & 0xFF) } }
    // A malformed payload declaring billions of IDs must not drive a huge reserveCapacity; the
    // parser clamps to what the bytes can hold and returns only those.
    #expect(PTPStorageIDs.parse(le32(0xFFFF_FFFF) + le32(0x0001_0001)) == [0x0001_0001])
}
