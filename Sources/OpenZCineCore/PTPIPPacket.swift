import Foundation

/// PTP-IP packet type codes from CIPA DC-005.
public enum PTPIPPacketType: UInt32, Equatable, Sendable {
    case initCommandRequest = 1
    case initCommandAck = 2
    case initEventRequest = 3
    case initEventAck = 4
    case initFail = 5
    case operationRequest = 6
    case operationResponse = 7
    case event = 8
    case startData = 9
    case data = 0x0A
    case cancel = 0x0B
    case endData = 0x0C
    case unknown = 0xFFFF_FFFF
}

/// Errors that can occur while parsing a length-prefixed PTP-IP packet.
public enum PTPIPPacketError: LocalizedError, Equatable, Sendable {
    case shortHeader
    case truncatedPayload(expectedLength: Int, actualLength: Int)
    case invalidLength(length: Int)

    public var errorDescription: String? {
        switch self {
        case .shortHeader:
            "PTP-IP packet header was incomplete (fewer than 8 bytes)."
        case .truncatedPayload(let expectedLength, let actualLength):
            "PTP-IP packet payload was truncated: expected \(expectedLength) bytes, got \(actualLength)."
        case .invalidLength(let length):
            "PTP-IP packet declared an invalid length of \(length) bytes."
        }
    }
}

/// A PTP-IP packet: `Length(4 LE) + Type(4 LE) + payload`.
public struct PTPIPPacket: Equatable, Sendable {
    public init(type: PTPIPPacketType, payload: Data) {
        self.type = type
        self.payload = payload
    }

    public init(serializedBytes bytes: [UInt8]) throws {
        guard bytes.count >= 8 else {
            throw PTPIPPacketError.shortHeader
        }
        let length = Int(ByteCoding.readUInt32LE(bytes, at: 0))
        guard length >= 8 else {
            throw PTPIPPacketError.invalidLength(length: length)
        }
        guard bytes.count >= length else {
            throw PTPIPPacketError.truncatedPayload(
                expectedLength: length,
                actualLength: bytes.count
            )
        }
        self.type = PTPIPPacketType(rawValue: ByteCoding.readUInt32LE(bytes, at: 4)) ?? .unknown
        self.payload = Data(bytes[8..<length])
    }

    public let type: PTPIPPacketType
    public let payload: Data

    public var serializedBytes: [UInt8] {
        ByteCoding.uint32LE(UInt32(8 + payload.count))
            + ByteCoding.uint32LE(type.rawValue)
            + Array(payload)
    }
}
