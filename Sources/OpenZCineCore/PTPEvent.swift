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

/// Ordered, deduplicated queue of properties the CAMERA announced as changed
/// (`DevicePropChanged` `0x4006`) and that a shell has not re-read yet.
///
/// The announcement carries no value, so it can only schedule an authoritative read. Order and
/// batching both matter. One detent of an aperture ring makes a body announce a burst — the
/// aperture the operator turned plus its dependents (exposure indicator, working ISO, …). Draining
/// that one entry per poll tick out of an unordered `Set` let the burst accumulate and could pass
/// over the one value the operator was watching, tick after tick: the "updates extremely slowly"
/// half of #268. Announcements drain oldest-first, in whole batches.
public struct CameraAnnouncedPropertyQueue: Equatable, Sendable {
    /// Maximum properties re-read in ONE poll tick.
    ///
    /// Each entry is a PTP round trip on the same channel that carries the live-view feed, so an
    /// unbounded batch from a chatty body would monopolise the loop and hitch the picture. Four
    /// covers a normal ring-detent burst whole; anything past it stays queued for the next tick
    /// rather than being dropped — a dropped announcement is a readout stuck until the round-robin
    /// comes back round ~20 s later.
    public static let batchLimit = 4

    /// Creates an empty queue.
    public init() {}

    /// Pending announcements, oldest first.
    public private(set) var pending: [PTPPropertyCode] = []

    /// Whether nothing is waiting to be re-read.
    public var isEmpty: Bool { pending.isEmpty }

    /// Records one announced change, ignoring properties the monitor cannot decode.
    ///
    /// A property already pending keeps its original position: a body that re-announces the same
    /// code while the operator keeps turning must not push the rest of the burst further back.
    public mutating func note(_ property: PTPPropertyCode) {
        guard PTPPropertyCode.isMonitoredChange(property), !pending.contains(property) else {
            return
        }
        pending.append(property)
    }

    /// Drops a property whose current value the shell just established another way (a confirmed
    /// write readback), so the queue does not spend a read re-confirming it.
    public mutating func cancel(_ property: PTPPropertyCode) {
        pending.removeAll { $0 == property }
    }

    /// Takes the next properties to read, oldest first, capped at `limit`.
    public mutating func nextBatch(limit: Int = batchLimit) -> [PTPPropertyCode] {
        let count = min(max(limit, 0), pending.count)
        defer { pending.removeFirst(count) }
        return Array(pending.prefix(count))
    }

    /// Forgets every pending announcement — used when a session ends and its snapshot is reset.
    public mutating func removeAll() {
        pending.removeAll()
    }
}

/// Parses the event array a Nikon body returns from the `GetEventEx` (0x941C) poll.
///
/// This queue — not the PTP-IP event socket — is the channel Nikon bodies use for the events the
/// monitor depends on: capture events (`ObjectAdded`, `CaptureComplete`) from a shutter fired ON
/// THE BODY, and `DevicePropChanged` (`0x4006`) from a body-side dial, ring, or menu edit. It is
/// how libgphoto2 reads Nikon events too — `ptp_check_event` routes a Nikon body to the vendor
/// event queue instead of the asynchronous channel. So the shells poll it in EVERY chrome: gating
/// the poll to photography (where it was introduced, for body-fired stills) left cinema mode with
/// no fast path for a body-side setting change at all (#268). Whether a given event is actionable
/// stays with each consumer, which is where the chrome test belongs.
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
