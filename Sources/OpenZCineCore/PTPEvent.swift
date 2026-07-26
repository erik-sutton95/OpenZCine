import Foundation

/// Nikon vendor PTP event codes the app reacts to on the async event channel.
///
/// Provenance: libgphoto2 `PTP_EC_NIKON_*` in `camlibs/ptp2/ptp.h`
/// (<https://github.com/gphoto/libgphoto2>).
public enum PTPEventCode: UInt16, Sendable {
    /// Standard PIMA 15740 event: a new object landed on the card (one per file — a
    /// RAW+JPEG pair emits two). Fires for body-fired and remote releases alike.
    case objectAdded = 0x4002
    /// Standard PIMA 15740 event: the capture run finished writing (one per destination).
    case captureComplete = 0x400D
    /// Standard PIMA 15740 event: a device property changed ON THE CAMERA. Parameter `e1` carries
    /// the property code. This is how a body-side dial, ring, or menu edit reaches the app promptly
    /// — the round-robin poll visits any one property only every ~20 s.
    case devicePropChanged = 0x4006
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
        rawEventCode = ByteCoding.readUInt16LE(bytes, at: 0)
        eventCode = PTPEventCode(rawValue: rawEventCode) ?? .unknown
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

    /// Direct construction from a code + parameters — used by the `GetEventEx` poll, whose
    /// event-array elements carry no transaction ID (unlike the socket packet layout).
    public init(eventCode raw: UInt16, parameters: [UInt32]) {
        rawEventCode = raw
        eventCode = PTPEventCode(rawValue: raw) ?? .unknown
        transactionID = 0
        self.parameters = parameters
    }

    /// The camera-sent event code, preserved even when this build does not
    /// know its Nikon-specific meaning.
    public let rawEventCode: UInt16

    /// The subset of event codes whose semantics are established by the
    /// shared core. Inspect [rawEventCode] for all other camera events.
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

    /// The device property a `DevicePropChanged` (`0x4006`) event names, when the shared core
    /// decodes that property. Nikon puts the property code in the first event parameter.
    ///
    /// Nil for any other event, for a malformed event with no parameters, and for a property code
    /// this build does not model — an announcement alone is not evidence the app can decode it.
    public var changedPropertyCode: PTPPropertyCode? {
        guard eventCode == .devicePropChanged, let raw = parameters.first else { return nil }
        return PTPPropertyCode(rawValue: raw)
    }

    /// Infers movie record state from Nikon record lifecycle events (`0xC10A` started,
    /// `0xC108` complete, `0xC105` interrupted). Returns nil for unrelated events.
    public var inferredRecordState: RecordState? {
        switch eventCode {
        case .movieRecordStarted:
            return .recording
        case .movieRecordComplete, .movieRecordInterrupted:
            return .standby
        case .objectAdded, .captureComplete, .devicePropChanged, .unknown:
            return nil
        }
    }
}

/// Parses the event array a Nikon body returns from the `GetEventEx` (0x941C) poll — the
/// channel through which capture events (ObjectAdded, CaptureComplete) actually arrive; the
/// PTP-IP event socket does not carry them, so a shutter fired ON THE BODY only surfaces here.
///
/// Layout (little-endian): `NumberOfElements(UINT32)`, then per element `EventCode(UINT16)`,
/// `NumParameters(UINT16)`, `NumParameters × Parameter(UINT32)`. Element count is capped at 2048.
public enum PTPNikonEventList {
    public static func parse(_ bytes: [UInt8]) -> [PTPEvent] {
        guard bytes.count >= 4 else { return [] }
        let declared = ByteCoding.readUInt32LE(bytes, at: 0)
        let count = Int(min(declared, 2048))
        var events: [PTPEvent] = []
        events.reserveCapacity(count)
        var offset = 4
        for _ in 0..<count {
            guard offset + 4 <= bytes.count else { break }
            let code = ByteCoding.readUInt16LE(bytes, at: offset)
            let numParams = Int(ByteCoding.readUInt16LE(bytes, at: offset + 2))
            offset += 4
            var params: [UInt32] = []
            params.reserveCapacity(numParams)
            for _ in 0..<numParams {
                guard offset + 4 <= bytes.count else { break }
                params.append(ByteCoding.readUInt32LE(bytes, at: offset))
                offset += 4
            }
            events.append(PTPEvent(eventCode: code, parameters: params))
        }
        return events
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
