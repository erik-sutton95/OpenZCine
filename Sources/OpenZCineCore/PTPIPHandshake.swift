import Foundation

/// Default PTP-IP TCP port used by Nikon Z cameras.
public let ptpIPPort = 15_740

/// Canonical PTP-IP protocol version: UINT32 `0x00010000`.
public let ptpIPProtocolVersion: UInt32 = 0x0001_0000

/// Stable PTP-IP initiator identity used for Nikon camera connection profiles.
public enum PTPIPInitiator {
    /// Nikon cameras can reject an unrecognized per-install/random initiator GUID.
    public static var appGUID: Data {
        Data([
            0x4F, 0x70, 0x65, 0x6E, 0x5A, 0x43, 0x69, 0x6E,
            0x65, 0x00, 0x11, 0x22, 0x33, 0x44, 0x55, 0x66,
        ])
    }

    /// This string is part of the paired initiator identity; keep it stable.
    public static let friendlyName = "WTU-iPhone"
}

/// Human-confirmed pairing challenge returned by Nikon's pairing-info operation.
public struct PTPIPPairingChallenge: Equatable, Sendable {
    public init(data: Data, cameraName: String? = nil) {
        rawBytes = data
        pin = Self.extractPin(from: Array(data))
        self.cameraName = cameraName
    }

    public let rawBytes: Data
    public let pin: String?  // extracted 4-digit PIN, if one was found
    public let cameraName: String?

    public var rawHex: String {
        rawBytes.map { String(format: "%02x", $0) }.joined(separator: " ")
    }

    private static func extractPin(from bytes: [UInt8]) -> String? {
        pinFromASCII(bytes)
            ?? pinFromUTF16(bytes, littleEndian: true)
            ?? pinFromUTF16(bytes, littleEndian: false)
            ?? pinFromLengthPrefixedByteDigits(bytes)
            ?? pinFromLengthPrefixedBCD(bytes)
            ?? pinFromLengthPrefixedNumber(bytes)
            ?? pinFromStandaloneNumber(bytes)
            ?? pinFromBCD(bytes)
    }

    private static func pinFromASCII(_ bytes: [UInt8]) -> String? {
        var text = ""
        for byte in bytes {
            if (0x30...0x39).contains(byte), let scalar = UnicodeScalar(Int(byte)) {
                text.append(Character(scalar))
            } else {
                text.append(" ")
            }
        }
        return firstFourDigitToken(in: text)
    }

    private static func pinFromUTF16(_ bytes: [UInt8], littleEndian: Bool) -> String? {
        guard bytes.count >= 8 else { return nil }
        for start in 0..<2 {
            var text = ""
            var index = start
            while index + 1 < bytes.count {
                let unit =
                    littleEndian
                    ? UInt16(bytes[index]) | (UInt16(bytes[index + 1]) << 8)
                    : (UInt16(bytes[index]) << 8) | UInt16(bytes[index + 1])
                if (0x30...0x39).contains(unit), let scalar = UnicodeScalar(Int(unit)) {
                    text.append(Character(scalar))
                } else {
                    text.append(" ")
                }
                index += 2
            }
            if let pin = firstFourDigitToken(in: text) { return pin }
        }
        return nil
    }

    private static func pinFromLengthPrefixedByteDigits(_ bytes: [UInt8]) -> String? {
        for start in lengthPrefixedStarts(bytes) where start + 3 < bytes.count {
            let digits = bytes[start..<(start + 4)]
            if digits.allSatisfy({ $0 <= 9 }) {
                return digits.map(String.init).joined()
            }
        }
        return nil
    }

    private static func pinFromLengthPrefixedBCD(_ bytes: [UInt8]) -> String? {
        for start in lengthPrefixedStarts(bytes) {
            if let pin = bcdPin(bytes, at: start) { return pin }
        }
        return nil
    }

    private static func pinFromLengthPrefixedNumber(_ bytes: [UInt8]) -> String? {
        for start in lengthPrefixedStarts(bytes) {
            if let pin = numberPin(bytes, at: start) { return pin }
        }
        return nil
    }

    private static func pinFromStandaloneNumber(_ bytes: [UInt8]) -> String? {
        guard bytes.count == 2 || bytes.count == 4 else { return nil }
        return numberPin(bytes, at: 0)
    }

    private static func pinFromBCD(_ bytes: [UInt8]) -> String? {
        guard bytes.count >= 2 else { return nil }
        for index in 0..<(bytes.count - 1) {
            if let pin = bcdPin(bytes, at: index) { return pin }
        }
        return nil
    }

    private static func lengthPrefixedStarts(_ bytes: [UInt8]) -> [Int] {
        if bytes.count > 4, ByteCoding.readUInt32LE(bytes, at: 0) == 4 {
            return [4]
        }
        if bytes.count > 2, ByteCoding.readUInt16LE(bytes, at: 0) == 4 {
            return [2]
        }
        return []
    }

    private static func bcdPin(_ bytes: [UInt8], at start: Int) -> String? {
        guard start + 1 < bytes.count else { return nil }
        let first = bytes[start]
        let second = bytes[start + 1]
        let digits = [first >> 4, first & 0x0F, second >> 4, second & 0x0F]
        guard digits.allSatisfy({ $0 <= 9 }) else { return nil }
        return digits.map(String.init).joined()
    }

    private static func numberPin(_ bytes: [UInt8], at start: Int) -> String? {
        if start + 1 < bytes.count {
            let pin = decimalPin(from: UInt32(ByteCoding.readUInt16LE(bytes, at: start)))
            if pin != nil { return pin }
        }
        if start + 3 < bytes.count {
            let pin = decimalPin(from: ByteCoding.readUInt32LE(bytes, at: start))
            if pin != nil { return pin }
        }
        return nil
    }

    private static func decimalPin(from value: UInt32) -> String? {
        guard (1_000...9_999).contains(value) else { return nil }
        return String(value)
    }

    private static func firstFourDigitToken(in text: String) -> String? {
        var current = ""
        for character in text {
            if character.isNumber {
                current.append(character)
            } else {
                if current.count == 4 { return current }
                current = ""
            }
        }
        return current.count == 4 ? current : nil
    }
}

/// Encodes PTP-IP friendly names as raw UTF-16LE plus a trailing NUL code unit.
public enum PTPIPFriendlyName {
    public static func encode(_ name: String) -> [UInt8] {
        var bytes: [UInt8] = []
        for codeUnit in name.utf16 {
            bytes += ByteCoding.uint16LE(codeUnit)
        }
        bytes += [0x00, 0x00]
        return bytes
    }

    public static func decode(_ bytes: ArraySlice<UInt8>) -> String? {
        var codeUnits: [UInt16] = []
        var offset = bytes.startIndex
        while offset + 1 < bytes.endIndex {
            let codeUnit = UInt16(bytes[offset]) | (UInt16(bytes[offset + 1]) << 8)
            if codeUnit == 0 { break }
            codeUnits.append(codeUnit)
            offset += 2
        }
        return String(decoding: codeUnits, as: UTF16.self)
    }
}

/// PTP-IP `Init_Command_Request` payload builder.
public struct PTPIPInitCommandRequest: Equatable, Sendable {
    public init(guid: Data, friendlyName: String) throws {
        guard guid.count == 16 else {
            throw PTPIPInitCommandError.invalidGUIDLength(actualLength: guid.count)
        }
        self.guid = guid
        self.friendlyName = friendlyName
    }

    public let guid: Data
    public let friendlyName: String

    public var payloadBytes: [UInt8] {
        Array(guid) + PTPIPFriendlyName.encode(friendlyName)
            + ByteCoding.uint32LE(ptpIPProtocolVersion)
    }
}

/// Errors that can occur while building an Init_Command_Request.
public enum PTPIPInitCommandError: LocalizedError, Equatable, Sendable {
    case invalidGUIDLength(actualLength: Int)

    public var errorDescription: String? {
        switch self {
        case .invalidGUIDLength(let actualLength):
            "Initiator GUID must be 16 bytes (got \(actualLength))."
        }
    }
}

/// Parsed PTP-IP `Init_Command_Ack` payload.
public struct PTPIPInitCommandAck: Equatable, Sendable {
    public init(payloadBytes bytes: [UInt8]) throws {
        guard bytes.count >= 4 else {
            throw PTPIPInitCommandAckError.shortPayload(actualLength: bytes.count)
        }
        connectionNumber = ByteCoding.readUInt32LE(bytes, at: 0)
        cameraName = bytes.count >= 22 ? PTPIPFriendlyName.decode(bytes[20..<bytes.count]) : nil
    }

    public let connectionNumber: UInt32  // assigned by the camera
    public let cameraName: String?
}

/// Errors that can occur while parsing an Init_Command_Ack.
public enum PTPIPInitCommandAckError: LocalizedError, Equatable, Sendable {
    case shortPayload(actualLength: Int)

    public var errorDescription: String? {
        switch self {
        case .shortPayload(let actualLength):
            "Init_Command_Ack payload was too short (\(actualLength) bytes)."
        }
    }
}

/// PTP-IP `Init_Fail` reason codes.
public enum PTPIPInitFailReason: UInt32, Sendable {
    case rejectedInitiator = 1
    case busy = 2
    case unspecified = 3
    case unknown = 0xFFFF_FFFF
}

/// Parsed PTP-IP `Init_Fail` payload.
public struct PTPIPInitFail: Equatable, Sendable {
    public init(payloadBytes bytes: [UInt8]) throws {
        guard bytes.count >= 4 else {
            throw PTPIPInitFailError.shortPayload(actualLength: bytes.count)
        }
        rawReason = ByteCoding.readUInt32LE(bytes, at: 0)
        reason = PTPIPInitFailReason(rawValue: rawReason) ?? .unknown
    }

    public let rawReason: UInt32
    public let reason: PTPIPInitFailReason
}

/// Errors that can occur while parsing an Init_Fail.
public enum PTPIPInitFailError: LocalizedError, Equatable, Sendable {
    case shortPayload(actualLength: Int)

    public var errorDescription: String? {
        switch self {
        case .shortPayload(let actualLength):
            "Init_Fail payload was too short (\(actualLength) bytes)."
        }
    }
}

/// Outcome of a quiet saved-profile probe.
public enum PTPIPSavedProfileProbeResult: Equatable, Sendable {
    /// The camera accepted app-control operations without a fresh pairing step.
    case accepted
    /// The camera did not open the app-control gate, so first-time pairing is required.
    case requiresPairing
}

/// Interprets the Nikon app-control gate during a quiet saved-profile probe.
public enum PTPIPSavedProfileProbePolicy {
    public static func resolve(
        applicationModeResponse: PTPResponseCode
    ) -> PTPIPSavedProfileProbeResult {
        applicationModeResponse == .ok ? .accepted : .requiresPairing
    }
}

/// Outcome of a first-time pairing-info query.
public enum PTPIPPairingInfoResult: Equatable, Sendable {
    /// Pairing-info returned challenge bytes and the user must confirm the code.
    case promptUser
    /// Pairing-info has not produced a challenge yet.
    case waitForChallenge
}

/// Interprets Nikon pairing-info responses during first-time pairing.
public enum PTPIPPairingInfoPolicy {
    public static func resolve(
        response: PTPResponseCode,
        byteCount: Int
    ) -> PTPIPPairingInfoResult {
        response == .ok && byteCount > 0 ? .promptUser : .waitForChallenge
    }
}

/// PTP-IP `Init_Event_Request` payload builder.
public struct PTPIPInitEventRequest: Equatable, Sendable {
    public init(connectionNumber: UInt32) {
        self.connectionNumber = connectionNumber
    }

    public let connectionNumber: UInt32  // from Init_Command_Ack

    public var payloadBytes: [UInt8] {
        ByteCoding.uint32LE(connectionNumber)
    }
}

/// A deterministic sequence of core PTP operations for opening an app-control session.
public struct PTPIPSessionScript: Equatable, Sendable {
    /// Standard pairing confirmation parameter value.
    public static let pairingConfirmValue: UInt32 = 0x2001

    public init(requestPairing: Bool) {
        var transactionID: UInt32 = 0
        var builtRequests: [PTPOperationRequest] = [
            PTPOperationRequest(
                dataPhase: .noDataOrDataIn,
                operationCode: .openSession,
                transactionID: transactionID,
                parameters: [1]
            )
        ]
        transactionID = 1

        if requestPairing {
            builtRequests.append(
                PTPOperationRequest(
                    dataPhase: .dataIn,
                    operationCode: .getPairingInfo,
                    transactionID: transactionID
                )
            )
            transactionID += 1
            builtRequests.append(
                PTPOperationRequest(
                    dataPhase: .noDataOrDataIn,
                    operationCode: .confirmPairing,
                    transactionID: transactionID,
                    parameters: [Self.pairingConfirmValue]
                )
            )
            transactionID += 1
        }

        builtRequests.append(
            PTPOperationRequest(
                dataPhase: .noDataOrDataIn,
                operationCode: .changeApplicationMode,
                transactionID: transactionID,
                parameters: [1]
            )
        )
        transactionID += 1
        builtRequests.append(
            PTPOperationRequest(
                dataPhase: .dataIn,
                operationCode: .getDevicePropValueEx,
                transactionID: transactionID,
                parameters: [PTPPropertyCode.movieRecProhibitionCondition.rawValue]
            )
        )
        transactionID += 1
        builtRequests.append(
            PTPOperationRequest(
                dataPhase: .dataIn,
                operationCode: .getDeviceInfo,
                transactionID: transactionID
            )
        )

        requests = builtRequests
    }

    public let requests: [PTPOperationRequest]
}
