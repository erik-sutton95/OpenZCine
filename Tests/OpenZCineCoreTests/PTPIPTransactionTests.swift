import Foundation
import Testing

@testable import OpenZCineCore

@Test func transactionCollectorStripsDataPrefixesAndReturnsResponse() throws {
    let collector = PTPIPTransactionCollector()

    let response = try collector.collect(from: [
        PTPIPPacket(
            type: .startData,
            payload: Data([
                0x02, 0x00, 0x00, 0x00,
                0x05, 0x00, 0x00, 0x00,
                0x00, 0x00, 0x00, 0x00,
            ])),
        PTPIPPacket(
            type: .data,
            payload: Data([
                0x02, 0x00, 0x00, 0x00,
                0xAA, 0xBB,
            ])),
        PTPIPPacket(
            type: .endData,
            payload: Data([
                0x02, 0x00, 0x00, 0x00,
                0xCC,
            ])),
        PTPIPPacket(
            type: .operationResponse,
            payload: Data([
                0x01, 0x20,
                0x02, 0x00, 0x00, 0x00,
            ])),
    ])

    #expect(response.operationResponse.responseCode == .ok)
    #expect(response.operationResponse.transactionID == 2)
    #expect(response.data == Data([0xAA, 0xBB, 0xCC]))
}

@Test func transactionCollectorRejectsDataPacketsWithoutTransactionPrefix() {
    let collector = PTPIPTransactionCollector()

    #expect(throws: PTPIPTransactionCollectorError.shortDataPayload(type: .data, actualLength: 3)) {
        _ = try collector.collect(from: [
            PTPIPPacket(type: .data, payload: Data([1, 2, 3]))
        ])
    }
}

@Test func transactionCollectorRejectsUnexpectedPacketType() {
    let collector = PTPIPTransactionCollector()

    #expect(throws: PTPIPTransactionCollectorError.unexpectedPacketType(.event)) {
        _ = try collector.collect(from: [
            PTPIPPacket(type: .event, payload: Data())
        ])
    }
}

@Test func transactionCollectorRequiresOperationResponse() {
    let collector = PTPIPTransactionCollector()

    #expect(throws: PTPIPTransactionCollectorError.missingOperationResponse) {
        _ = try collector.collect(from: [
            PTPIPPacket(type: .startData, payload: Data(repeating: 0, count: 12))
        ])
    }
}
