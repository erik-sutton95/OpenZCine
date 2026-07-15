import Foundation

/// The 64-bit object size returned by Nikon `GetObjectSize` (`0x9421`).
///
/// libgphoto2's `PTP_OC_NIKON_GetObjectSize` decoder treats the operation's data-in payload as one
/// little-endian `UINT64`. The operation is not yet verified on a Nikon ZR. [VERIFY-ON-HW]
public struct PTPObjectSize: Equatable, Sendable {
    /// Decodes the first eight payload bytes as a little-endian object size.
    ///
    /// - Parameter data: The data-in payload returned by Nikon `GetObjectSize`.
    /// - Throws: ``PTPObjectTransferError/truncatedObjectSize(actualLength:)`` when fewer than eight
    ///   bytes are available.
    public init(data: Data) throws {
        guard data.count >= 8 else {
            throw PTPObjectTransferError.truncatedObjectSize(actualLength: data.count)
        }
        bytes = ByteCoding.readUInt64LE(Array(data.prefix(8)), at: 0)
    }

    /// The object's complete byte length.
    public let bytes: UInt64
}

/// One bounded PTP request for a byte range of a stored camera object.
///
/// Standard `GetPartialObject` (`0x101B`) is used for objects and ranges representable by its
/// 32-bit fields. Nikon `GetPartialObjectEx` (`0x9431`) is used for a large object or range, packing
/// the offset and maximum byte count as low/high `UINT32` words. The Nikon operation is not yet
/// verified on a Nikon ZR. [VERIFY-ON-HW]
public struct PTPPartialObjectRequest: Equatable, Sendable {
    /// Plans a request and trims its byte count to the bytes remaining in the object.
    ///
    /// - Parameters:
    ///   - objectHandle: PTP handle of the object to read.
    ///   - offset: Zero-based byte offset at which the request begins.
    ///   - maximumBytes: Maximum number of bytes to request in this transaction.
    ///   - totalBytes: Resolved complete object size.
    ///   - supportsExtendedReads: Whether Nikon `GetPartialObjectEx` may be used.
    /// - Throws: ``PTPObjectTransferError`` when the request cannot make progress, starts outside
    ///   the object, or requires an unsupported Nikon extended read.
    public init(
        objectHandle: UInt32,
        offset: UInt64,
        maximumBytes: UInt64,
        totalBytes: UInt64,
        supportsExtendedReads: Bool
    ) throws {
        guard maximumBytes > 0 else { throw PTPObjectTransferError.zeroMaximumBytes }
        guard offset < totalBytes else {
            throw PTPObjectTransferError.offsetOutsideObject(
                offset: offset,
                totalBytes: totalBytes
            )
        }

        let requestBytes = min(maximumBytes, totalBytes - offset)
        let requiresExtendedRead =
            totalBytes > UInt64(UInt32.max)
            || offset > UInt64(UInt32.max)
            || requestBytes > UInt64(UInt32.max)
        guard !requiresExtendedRead || supportsExtendedReads else {
            throw PTPObjectTransferError.extendedReadUnsupported(totalBytes: totalBytes)
        }

        self.objectHandle = objectHandle
        self.offset = offset
        byteCount = requestBytes
        if requiresExtendedRead {
            operationCode = .getPartialObjectEx
            parameters = [
                objectHandle,
                Self.lowWord(offset),
                Self.highWord(offset),
                Self.lowWord(requestBytes),
                Self.highWord(requestBytes),
            ]
        } else {
            operationCode = .getPartialObject
            parameters = [objectHandle, UInt32(offset), UInt32(requestBytes)]
        }
    }

    /// PTP handle of the object being read.
    public let objectHandle: UInt32
    /// Zero-based byte offset at which this request begins.
    public let offset: UInt64
    /// Actual requested byte count after trimming to the object's remaining bytes.
    public let byteCount: UInt64
    /// Standard or Nikon extended partial-object operation selected for this request.
    public let operationCode: PTPOperationCode
    /// Wire parameters for ``operationCode``.
    public let parameters: [UInt32]

    /// Exclusive end offset of this request.
    public var endOffset: UInt64 { offset + byteCount }

    private static func lowWord(_ value: UInt64) -> UInt32 {
        UInt32(truncatingIfNeeded: value)
    }

    private static func highWord(_ value: UInt64) -> UInt32 {
        UInt32(truncatingIfNeeded: value >> 32)
    }
}

/// Resumable state for a sequence of bounded partial-object reads.
///
/// The cursor owns no transport or storage. A platform session asks for ``nextRequest()``, executes
/// that request through its serialized transaction gate, persists the returned bytes, then calls
/// ``advance(by:)``. This keeps range selection, ≥4 GiB handling, and progress validation in the
/// portable Swift core.
public struct PTPObjectTransferCursor: Equatable, Sendable {
    /// Default transfer request size: 4 MiB, matching the existing iOS progressive-cache path.
    public static let defaultChunkSize: UInt64 = 4 * 1_024 * 1_024

    /// Creates a transfer cursor, optionally resuming from already cached bytes.
    ///
    /// - Parameters:
    ///   - objectHandle: PTP handle of the object to read.
    ///   - totalBytes: Resolved complete object size.
    ///   - resumeOffset: Number of bytes already cached and verified locally.
    ///   - chunkSize: Maximum number of bytes in each PTP request.
    ///   - supportsExtendedReads: Whether Nikon `GetPartialObjectEx` may be used.
    /// - Throws: ``PTPObjectTransferError/zeroMaximumBytes`` for a zero chunk or
    ///   ``PTPObjectTransferError/offsetOutsideObject(offset:totalBytes:)`` when the resume offset is
    ///   beyond the object.
    public init(
        objectHandle: UInt32,
        totalBytes: UInt64,
        resumeOffset: UInt64 = 0,
        chunkSize: UInt64 = PTPObjectTransferCursor.defaultChunkSize,
        supportsExtendedReads: Bool
    ) throws {
        guard chunkSize > 0 else { throw PTPObjectTransferError.zeroMaximumBytes }
        guard resumeOffset <= totalBytes else {
            throw PTPObjectTransferError.offsetOutsideObject(
                offset: resumeOffset,
                totalBytes: totalBytes
            )
        }
        if totalBytes > UInt64(UInt32.max), !supportsExtendedReads {
            throw PTPObjectTransferError.extendedReadUnsupported(totalBytes: totalBytes)
        }

        self.objectHandle = objectHandle
        self.totalBytes = totalBytes
        offset = resumeOffset
        self.chunkSize = chunkSize
        self.supportsExtendedReads = supportsExtendedReads
    }

    /// PTP handle of the object being transferred.
    public let objectHandle: UInt32
    /// Resolved complete object size.
    public let totalBytes: UInt64
    /// Current resume offset, equal to the number of successfully accepted bytes.
    public private(set) var offset: UInt64
    /// Maximum bytes requested in one transaction.
    public let chunkSize: UInt64
    /// Whether Nikon `GetPartialObjectEx` may be used for large reads.
    public let supportsExtendedReads: Bool

    /// Whether every byte in the object has been accepted.
    public var isComplete: Bool { offset == totalBytes }

    /// Plans the next request, or returns `nil` when the transfer is complete.
    public func nextRequest() throws -> PTPPartialObjectRequest? {
        guard !isComplete else { return nil }
        return try PTPPartialObjectRequest(
            objectHandle: objectHandle,
            offset: offset,
            maximumBytes: chunkSize,
            totalBytes: totalBytes,
            supportsExtendedReads: supportsExtendedReads
        )
    }

    /// Advances the resume offset after a transaction's payload has been persisted successfully.
    ///
    /// A short non-empty payload is accepted and the next request resumes immediately after it.
    /// Empty payloads before completion and payloads larger than the planned request are rejected so
    /// callers cannot silently mark missing or unsolicited bytes as cached.
    public mutating func advance(by receivedBytes: UInt64) throws {
        guard !isComplete else { throw PTPObjectTransferError.transferAlreadyComplete }
        guard receivedBytes > 0 else {
            throw PTPObjectTransferError.emptyChunkBeforeCompletion(offset: offset)
        }
        guard receivedBytes <= UInt64.max - offset else {
            throw PTPObjectTransferError.offsetOverflow(
                offset: offset,
                receivedBytes: receivedBytes
            )
        }

        let maximumBytes = min(chunkSize, totalBytes - offset)
        guard receivedBytes <= maximumBytes else {
            throw PTPObjectTransferError.chunkExceedsRequest(
                receivedBytes: receivedBytes,
                maximumBytes: maximumBytes
            )
        }
        offset += receivedBytes
    }
}

/// Validation errors produced while decoding or planning a partial-object transfer.
public enum PTPObjectTransferError: LocalizedError, Equatable, Sendable {
    /// Nikon `GetObjectSize` returned fewer than the required eight bytes.
    case truncatedObjectSize(actualLength: Int)
    /// A request or cursor was configured with a zero-byte maximum.
    case zeroMaximumBytes
    /// A request or resume position is outside the resolved object extent.
    case offsetOutsideObject(offset: UInt64, totalBytes: UInt64)
    /// A ≥4 GiB transfer requires Nikon `GetPartialObjectEx`, but it is unavailable.
    case extendedReadUnsupported(totalBytes: UInt64)
    /// Advancing by the received byte count would overflow `UInt64`.
    case offsetOverflow(offset: UInt64, receivedBytes: UInt64)
    /// The camera returned no bytes before the known end of the object.
    case emptyChunkBeforeCompletion(offset: UInt64)
    /// The camera returned more bytes than the current request allowed.
    case chunkExceedsRequest(receivedBytes: UInt64, maximumBytes: UInt64)
    /// A completed cursor cannot advance again.
    case transferAlreadyComplete

    /// Operator-facing description of the validation failure.
    public var errorDescription: String? {
        switch self {
        case .truncatedObjectSize(let actualLength):
            "Nikon GetObjectSize returned only \(actualLength) byte(s); eight are required."
        case .zeroMaximumBytes:
            "A partial-object request must allow at least one byte."
        case .offsetOutsideObject(let offset, let totalBytes):
            "Object offset \(offset) is outside the \(totalBytes)-byte object."
        case .extendedReadUnsupported(let totalBytes):
            "The \(totalBytes)-byte object requires Nikon extended partial-object reads."
        case .offsetOverflow(let offset, let receivedBytes):
            "Advancing object offset \(offset) by \(receivedBytes) bytes would overflow."
        case .emptyChunkBeforeCompletion(let offset):
            "The camera returned no object bytes at offset \(offset) before transfer completion."
        case .chunkExceedsRequest(let receivedBytes, let maximumBytes):
            "The camera returned \(receivedBytes) bytes for a request limited to \(maximumBytes)."
        case .transferAlreadyComplete:
            "The object transfer is already complete."
        }
    }
}
