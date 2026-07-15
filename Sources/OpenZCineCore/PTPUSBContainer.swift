import Foundation

/// PIMA 15740 generic-container type codes used on the USB bulk pipe.
///
/// Provenance: the generic container layout is standard PTP (PIMA 15740 §Generic Container /
/// libgphoto2 `PTP_USB_CONTAINER_*` in `camlibs/ptp2/ptp.h`).
public enum PTPUSBContainerType: UInt16, Equatable, Sendable {
    case command = 1
    case data = 2
    case response = 3
    case event = 4
}

/// Errors that can occur while parsing a PIMA 15740 generic container.
public enum PTPUSBContainerError: LocalizedError, Equatable, Sendable {
    /// The container was shorter than the 12-byte header.
    case shortHeader(actualLength: Int)
    /// The declared container length was invalid or exceeded the buffer.
    case invalidLength(declaredLength: Int, actualLength: Int)
    /// A streaming endpoint declared a container above its allocation bound.
    case exceedsMaximumLength(declaredLength: Int, maximumLength: Int)
    /// The container type code was not a known PIMA 15740 type.
    case unknownType(rawType: UInt16)

    public var errorDescription: String? {
        switch self {
        case .shortHeader(let actualLength):
            "PTP USB container header was incomplete (\(actualLength) bytes)."
        case .invalidLength(let declaredLength, let actualLength):
            "PTP USB container declared \(declaredLength) bytes but \(actualLength) were available."
        case .exceedsMaximumLength(let declaredLength, let maximumLength):
            "PTP USB container declared \(declaredLength) bytes, above the \(maximumLength)-byte limit."
        case .unknownType(let rawType):
            "PTP USB container type \(rawType) is not a known PIMA 15740 container type."
        }
    }
}

/// A PIMA 15740 generic container:
/// `Length(4 LE) + Type(2 LE) + Code(2 LE) + TransactionID(4 LE) + payload`.
///
/// This is the USB-side sibling of `PTPIPPacket`: the same inner PTP operations, properties, and
/// datasets ride in these containers on the USB bulk pipe. Note the layout difference from PTP-IP —
/// the USB command container has **no DataPhaseInfo field** (that field is PTP-IP-specific), and
/// the operation/response/event code lives in the container header itself.
public struct PTPUSBContainer: Equatable, Sendable {
    public init(type: PTPUSBContainerType, code: UInt16, transactionID: UInt32, payload: Data) {
        self.type = type
        self.code = code
        self.transactionID = transactionID
        self.payload = payload
    }

    /// Parses a serialized container, validating the declared length against the buffer.
    public init(serializedBytes bytes: [UInt8]) throws {
        guard bytes.count >= 12 else {
            throw PTPUSBContainerError.shortHeader(actualLength: bytes.count)
        }
        let declaredLength = Int(ByteCoding.readUInt32LE(bytes, at: 0))
        guard declaredLength >= 12, declaredLength <= bytes.count else {
            throw PTPUSBContainerError.invalidLength(
                declaredLength: declaredLength,
                actualLength: bytes.count
            )
        }
        let rawType = ByteCoding.readUInt16LE(bytes, at: 4)
        guard let parsedType = PTPUSBContainerType(rawValue: rawType) else {
            throw PTPUSBContainerError.unknownType(rawType: rawType)
        }
        type = parsedType
        code = ByteCoding.readUInt16LE(bytes, at: 6)
        transactionID = ByteCoding.readUInt32LE(bytes, at: 8)
        payload = Data(bytes[12..<declaredLength])
    }

    /// Container type (command / data / response / event).
    public let type: PTPUSBContainerType
    /// Operation, response, or event code, depending on `type`.
    public let code: UInt16
    /// Transaction ID (0 for `OpenSession` and camera-initiated events that carry none).
    public let transactionID: UInt32
    /// Parameters (command/response/event) or dataset bytes (data).
    public let payload: Data

    /// Serialized on-the-wire bytes.
    public var serializedBytes: [UInt8] {
        ByteCoding.uint32LE(UInt32(12 + payload.count))
            + ByteCoding.uint16LE(type.rawValue)
            + ByteCoding.uint16LE(code)
            + ByteCoding.uint32LE(transactionID)
            + Array(payload)
    }
}

/// Incremental PTP USB container framing for a byte-stream bulk endpoint.
///
/// USB bulk transfers are not message boundaries: one PIMA container may be
/// fragmented across reads, and one read may carry several containers. This
/// buffer retains incomplete bytes and vends exactly one validated container
/// at a time so platform adapters never need to interpret PTP fields.
public struct PTPUSBReadBuffer: Sendable {
    /// Creates an empty buffer with a hard per-container allocation bound.
    public init(maximumContainerLength: Int = 128 * 1024 * 1024) {
        self.maximumContainerLength = maximumContainerLength
    }

    /// Appends raw bytes received from the USB bulk or interrupt endpoint.
    public mutating func append(_ bytes: [UInt8]) {
        bufferedBytes.append(contentsOf: bytes)
    }

    /// Returns the next complete container, or nil until more bytes arrive.
    public mutating func nextContainer() throws -> PTPUSBContainer? {
        guard bufferedBytes.count >= Self.lengthFieldByteCount else { return nil }
        let declaredLength = Int(ByteCoding.readUInt32LE(bufferedBytes, at: 0))
        guard declaredLength >= Self.minimumContainerLength else {
            throw PTPUSBContainerError.invalidLength(
                declaredLength: declaredLength,
                actualLength: bufferedBytes.count
            )
        }
        guard declaredLength <= maximumContainerLength else {
            throw PTPUSBContainerError.exceedsMaximumLength(
                declaredLength: declaredLength,
                maximumLength: maximumContainerLength
            )
        }
        guard bufferedBytes.count >= declaredLength else { return nil }
        let bytes = Array(bufferedBytes.prefix(declaredLength))
        bufferedBytes.removeFirst(declaredLength)
        return try PTPUSBContainer(serializedBytes: bytes)
    }

    /// Number of incomplete bytes retained for the next USB read.
    public var bufferedByteCount: Int { bufferedBytes.count }

    private static let lengthFieldByteCount = 4
    private static let minimumContainerLength = 12
    private let maximumContainerLength: Int
    private var bufferedBytes: [UInt8] = []
}

/// Builds and decodes the USB-container halves of one PTP transaction, for transports (such as
/// ImageCaptureCore's `requestSendPTPCommand`) that exchange whole containers per call.
public enum PTPUSBTransaction {
    /// Builds the command container for an operation request.
    public static func commandContainer(
        operationCode: PTPOperationCode,
        transactionID: UInt32,
        parameters: [UInt32] = []
    ) -> Data {
        var payload = Data()
        for parameter in parameters {
            payload.append(contentsOf: ByteCoding.uint32LE(parameter))
        }
        let container = PTPUSBContainer(
            type: .command,
            code: operationCode.rawValue,
            transactionID: transactionID,
            payload: payload
        )
        return Data(container.serializedBytes)
    }

    /// Decodes the response half of a transaction into the app's transaction result.
    ///
    /// - Parameters:
    ///   - responseBytes: The response container returned by the transport (12-byte header plus
    ///     up to five UINT32 response parameters).
    ///   - dataBytes: The data-in blob returned by the transport. ImageCaptureCore has been
    ///     observed returning this either as the raw dataset or as a full data container, so a
    ///     leading well-formed data-container header (matching length, type, code, and
    ///     transaction ID) is stripped when present. `[VERIFY-ON-HW]`
    public static func result(
        operationCode: PTPOperationCode,
        responseBytes: Data,
        dataBytes: Data
    ) throws -> PTPIPTransactionResult {
        let responseContainer = try PTPUSBContainer(serializedBytes: Array(responseBytes))
        guard responseContainer.type == .response else {
            throw PTPUSBContainerError.unknownType(rawType: responseContainer.type.rawValue)
        }
        // Rebuild the PTP-IP-shaped response payload (code + transaction ID + params) so both
        // transports share one `PTPOperationResponse` / `PTPIPTransactionResult` currency.
        let responsePayload =
            ByteCoding.uint16LE(responseContainer.code)
            + ByteCoding.uint32LE(responseContainer.transactionID)
            + Array(responseContainer.payload)
        let response = try PTPOperationResponse(payloadBytes: responsePayload)
        return PTPIPTransactionResult(
            operationResponse: response,
            data: strippedDataPayload(
                dataBytes,
                operationCode: operationCode,
                transactionID: responseContainer.transactionID
            )
        )
    }

    /// Decodes a camera-pushed event container into a `PTPEvent`.
    public static func event(from bytes: Data) throws -> PTPEvent {
        let container = try PTPUSBContainer(serializedBytes: Array(bytes))
        guard container.type == .event else {
            throw PTPEventError.notAnEventPacket
        }
        let payload =
            ByteCoding.uint16LE(container.code)
            + ByteCoding.uint32LE(container.transactionID)
            + Array(container.payload)
        return try PTPEvent(payloadBytes: payload)
    }

    /// Strips a leading data-container header when the blob is a full container rather than the
    /// raw dataset. All four header fields must corroborate (declared length equals the blob
    /// length, type is `data`, code echoes the operation, transaction ID matches) so a dataset
    /// that merely starts with plausible bytes is never truncated.
    private static func strippedDataPayload(
        _ bytes: Data,
        operationCode: PTPOperationCode,
        transactionID: UInt32
    ) -> Data {
        guard bytes.count >= 12 else { return bytes }
        let raw = Array(bytes.prefix(12))
        let declaredLength = Int(ByteCoding.readUInt32LE(raw, at: 0))
        let rawType = ByteCoding.readUInt16LE(raw, at: 4)
        let code = ByteCoding.readUInt16LE(raw, at: 6)
        let containerTransactionID = ByteCoding.readUInt32LE(raw, at: 8)
        guard declaredLength == bytes.count,
            rawType == PTPUSBContainerType.data.rawValue,
            code == operationCode.rawValue,
            containerTransactionID == transactionID
        else {
            return bytes
        }
        return bytes.dropFirst(12)
    }
}
