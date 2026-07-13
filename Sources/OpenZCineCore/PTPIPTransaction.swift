import Foundation

/// Result of draining packets for a single PTP operation.
public struct PTPIPTransactionResult: Equatable, Sendable {
    public init(operationResponse: PTPOperationResponse, data: Data) {
        self.operationResponse = operationResponse
        self.data = data
    }

    public let operationResponse: PTPOperationResponse
    public let data: Data
}

/// Collects data-phase packets until the matching `Operation_Response` appears.
public struct PTPIPTransactionCollector: Sendable {
    /// Creates a transaction collector.
    public init() {}

    /// Collects a transaction result from a sequence of packets.
    public func collect(from packets: [PTPIPPacket]) throws -> PTPIPTransactionResult {
        var data = Data()

        for packet in packets {
            switch packet.type {
            case .startData:
                continue
            case .data, .endData:
                guard packet.payload.count >= 4 else {
                    throw PTPIPTransactionCollectorError.shortDataPayload(
                        type: packet.type,
                        actualLength: packet.payload.count
                    )
                }
                data.append(packet.payload.dropFirst(4))
            case .operationResponse:
                let response = try PTPOperationResponse(payloadBytes: Array(packet.payload))
                return PTPIPTransactionResult(operationResponse: response, data: data)
            default:
                throw PTPIPTransactionCollectorError.unexpectedPacketType(packet.type)
            }
        }

        throw PTPIPTransactionCollectorError.missingOperationResponse
    }
}

/// Errors that can occur while collecting transaction packets.
public enum PTPIPTransactionCollectorError: LocalizedError, Equatable, Sendable {
    /// A data packet payload was shorter than expected.
    case shortDataPayload(type: PTPIPPacketType, actualLength: Int)
    /// An unexpected packet type was encountered.
    case unexpectedPacketType(PTPIPPacketType)
    /// No Operation_Response packet was found.
    case missingOperationResponse

    public var errorDescription: String? {
        switch self {
        case .shortDataPayload(let type, let actualLength):
            "PTP-IP \(type) data payload was too short (\(actualLength) bytes)."
        case .unexpectedPacketType(let type):
            "Unexpected PTP-IP packet type \(type) while collecting a transaction."
        case .missingOperationResponse:
            "Transaction completed without an Operation_Response packet."
        }
    }
}
