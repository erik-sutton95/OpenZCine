import Foundation

/// Nikon vendor PTP event codes the app reacts to on the async event channel.
///
/// Provenance: libgphoto2 `PTP_EC_NIKON_*` in `camlibs/ptp2/ptp.h`
/// (<https://github.com/gphoto/libgphoto2>).
public enum PTPEventCode: UInt16, Sendable {
    case movieRecordInterrupted = 0xC105
    case movieRecordComplete = 0xC108
    case movieRecordStarted = 0xC10A
    case unknown = 0xFFFF
}

/// A PTP event container from a PTP-IP `Event` packet payload.
///
/// Layout mirrors `PTPOperationResponse`: `EventCode(2 LE) + TransactionID(4 LE) + UINT32 params…`
public struct PTPEvent: Equatable, Sendable {
    public init(payloadBytes bytes: [UInt8]) throws {
        guard bytes.count >= 6 else {
            throw PTPEventError.shortPayload(actualLength: bytes.count)
        }
        eventCode = PTPEventCode(rawValue: ByteCoding.readUInt16LE(bytes, at: 0)) ?? .unknown
        transactionID = ByteCoding.readUInt32LE(bytes, at: 2)

        var parsedParameters: [UInt32] = []
        var offset = 6
        while offset + 4 <= bytes.count {
            parsedParameters.append(ByteCoding.readUInt32LE(bytes, at: offset))
            offset += 4
        }
        parameters = parsedParameters
    }

    /// Parses a PTP-IP transport packet whose type is `.event`.
    public init(from packet: PTPIPPacket) throws {
        guard packet.type == .event else {
            throw PTPEventError.notAnEventPacket
        }
        try self.init(payloadBytes: Array(packet.payload))
    }

    public let eventCode: PTPEventCode
    public let transactionID: UInt32
    public let parameters: [UInt32]

    /// The camera's raw error code from `MovieRecordInterrupted` (`0xC105`) parameter `e1`.
    /// Nikon does not publish the value table, so callers must surface or log it rather than guess
    /// that a particular value means thermal, card, or buffer failure.
    public var recordingInterruptionErrorCode: UInt32? {
        guard eventCode == .movieRecordInterrupted else { return nil }
        return parameters.first
    }

    /// Infers movie record state from Nikon record lifecycle events (`0xC10A` started,
    /// `0xC108` complete, `0xC105` interrupted). Returns nil for unrelated events.
    public var inferredRecordState: RecordState? {
        switch eventCode {
        case .movieRecordStarted:
            return .recording
        case .movieRecordComplete, .movieRecordInterrupted:
            return .standby
        case .unknown:
            return nil
        }
    }
}

/// Errors that can occur while parsing a PTP event container.
public enum PTPEventError: LocalizedError, Equatable, Sendable {
    case shortPayload(actualLength: Int)
    case notAnEventPacket

    public var errorDescription: String? {
        switch self {
        case .shortPayload(let actualLength):
            "PTP event payload was too short (\(actualLength) bytes)."
        case .notAnEventPacket:
            "Packet was not a PTP-IP Event packet."
        }
    }
}
