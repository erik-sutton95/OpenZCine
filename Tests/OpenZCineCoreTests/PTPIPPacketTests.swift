import Foundation
import Testing

@testable import OpenZCineCore

@Test func packetSerializesLengthTypeAndPayloadLittleEndian() throws {
    let packet = PTPIPPacket(type: .initCommandRequest, payload: Data([0xAA, 0xBB]))

    #expect(
        packet.serializedBytes == [
            10, 0, 0, 0,
            1, 0, 0, 0,
            0xAA, 0xBB,
        ])
}

@Test func packetParsesTypeAndPayload() throws {
    let parsed = try PTPIPPacket(serializedBytes: [
        12, 0, 0, 0,
        5, 0, 0, 0,
        1, 0, 0, 0,
    ])

    #expect(parsed.type == .initFail)
    #expect(parsed.payload == Data([1, 0, 0, 0]))
}

@Test func packetParsesLivenessProbeAndBuildsItsAnswer() throws {
    // A header-only ProbeRequest must parse as itself, NOT `.unknown` — swallowed probes are
    // what let the body conclude the initiator died and close the session.
    let probe = try PTPIPPacket(serializedBytes: [
        8, 0, 0, 0,
        0x0D, 0, 0, 0,
    ])
    #expect(probe.type == .probeRequest)
    #expect(probe.payload.isEmpty)

    let answer = PTPIPPacket(type: .probeResponse, payload: probe.payload)
    #expect(
        answer.serializedBytes == [
            8, 0, 0, 0,
            0x0E, 0, 0, 0,
        ])
}

@Test func packetRejectsShortHeader() {
    #expect(throws: PTPIPPacketError.shortHeader) {
        _ = try PTPIPPacket(serializedBytes: [1, 2, 3, 4])
    }
}

@Test func packetRejectsTruncatedPayload() {
    #expect(throws: PTPIPPacketError.truncatedPayload(expectedLength: 12, actualLength: 10)) {
        _ = try PTPIPPacket(serializedBytes: [
            12, 0, 0, 0,
            5, 0, 0, 0,
            1, 0,
        ])
    }
}
