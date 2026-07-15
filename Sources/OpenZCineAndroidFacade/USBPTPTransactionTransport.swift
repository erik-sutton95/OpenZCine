import Foundation
import OpenZCineCore

/// Raw endpoint I/O owned by the Android platform adapter.
///
/// The Kotlin implementation deliberately exposes bytes and lifecycle only.
/// Swift owns generic PTP container framing, transaction IDs, and every
/// Nikon-specific session operation above this seam.
protocol USBPTPRawIO: AnyObject, Sendable {
    func writeBulk(_ bytes: [UInt8], timeoutMilliseconds: Int) -> Int?
    func readBulk(maxBytes: Int, timeoutMilliseconds: Int) -> [UInt8]?
    /// Empty bytes mean a benign idle timeout; nil means closed or failed.
    func readEvent(maxBytes: Int, timeoutMilliseconds: Int) -> [UInt8]?
    func isClosed() -> Bool
    func close()
}

/// Raw USB bridge failures before a PTP operation reaches the shared core.
enum AndroidUSBPTPTransportError: Error, LocalizedError, Equatable {
    case connectionClosed
    case timeout(String)
    case writeFailed(expected: Int, actual: Int)
    case readFailed(String)
    case missingDataOut(PTPOperationCode)
    case unexpectedDataOut(PTPOperationCode)
    case unexpectedContainer(PTPUSBContainerType)
    case mismatchedTransaction(expected: UInt32, actual: UInt32)
    case mismatchedOperation(expected: UInt16, actual: UInt16)

    var errorDescription: String? {
        switch self {
        case .connectionClosed:
            "The USB-C camera was disconnected."
        case .timeout(let label):
            "USB \(label) timed out."
        case .writeFailed(let expected, let actual):
            "USB wrote \(actual) of \(expected) bytes to the camera."
        case .readFailed(let label):
            "USB could not read \(label) from the camera."
        case .missingDataOut(let operation):
            "USB \(operation) requires host-to-camera data but none was supplied."
        case .unexpectedDataOut(let operation):
            "USB \(operation) was given host-to-camera data for a data-in operation."
        case .unexpectedContainer(let type):
            "USB camera sent an unexpected PTP container type \(type.rawValue)."
        case .mismatchedTransaction(let expected, let actual):
            "USB camera replied to transaction \(actual), expected \(expected)."
        case .mismatchedOperation(let expected, let actual):
            "USB camera replied to operation \(actual), expected \(expected)."
        }
    }
}

/// Generic-container PTP transport over Android's platform-owned USB bytes.
///
/// This type is platform-neutral so its framing and idle-event semantics run
/// against a fake raw I/O endpoint in the normal Swift facade test suite. The
/// Android-only JNI handle conforms to ``USBPTPRawIO`` at runtime.
final class AndroidUSBPTPTransport: CameraTransport, @unchecked Sendable {
    let kind: CameraTransportKind = .usb

    init(rawIO: any USBPTPRawIO) {
        self.rawIO = rawIO
    }

    func executeTransaction(
        operationCode: PTPOperationCode,
        transactionID: UInt32?,
        parameters: [UInt32],
        dataPhase: PTPDataPhase,
        dataOut: Data?,
        deadline: Duration?
    ) async throws -> PTPIPTransactionResult {
        try Task.checkCancellation()
        return try executeTransactionSynchronously(
            operationCode: operationCode,
            transactionID: transactionID,
            parameters: parameters,
            dataPhase: dataPhase,
            dataOut: dataOut,
            deadline: deadline
        )
    }

    func nextEvent() async throws -> PTPEvent {
        try nextEventSynchronously()
    }

    func close() {
        // Do not take `transactionLock` here. A command read can be blocked
        // in the platform layer, and closing the raw endpoints is precisely
        // how detach/event-failure wakes that read without a ten-second wait.
        stateLock.lock()
        let alreadyClosed = isClosed
        isClosed = true
        stateLock.unlock()
        guard !alreadyClosed else { return }
        rawIO.close()
    }

    /// Blocking transaction entry used by the JNI facade's Swift-owned
    /// session thread. It serializes whole PTP operations, never raw packets,
    /// matching `CameraTransport`'s contract.
    func executeTransactionSynchronously(
        operationCode: PTPOperationCode,
        transactionID explicitTransactionID: UInt32? = nil,
        parameters: [UInt32] = [],
        dataPhase: PTPDataPhase = .noDataOrDataIn,
        dataOut: Data? = nil,
        deadline: Duration? = nil
    ) throws -> PTPIPTransactionResult {
        try validateDataPhase(operationCode: operationCode, dataPhase: dataPhase, dataOut: dataOut)

        transactionLock.lock()
        defer { transactionLock.unlock() }
        stateLock.lock()
        let closed = isClosed
        stateLock.unlock()
        guard !closed else { throw AndroidUSBPTPTransportError.connectionClosed }
        let transactionID = explicitTransactionID ?? nextTransactionID
        if explicitTransactionID == nil { nextTransactionID += 1 }
        let timeout = timeoutMilliseconds(deadline: deadline)
        try write(
            PTPUSBTransaction.commandContainer(
                operationCode: operationCode,
                transactionID: transactionID,
                parameters: parameters
            ),
            timeoutMilliseconds: timeout
        )
        if let dataOut {
            let dataContainer = PTPUSBContainer(
                type: .data,
                code: operationCode.rawValue,
                transactionID: transactionID,
                payload: dataOut
            )
            try write(Data(dataContainer.serializedBytes), timeoutMilliseconds: timeout)
        }

        var dataPayload = Data()
        while true {
            let container = try nextCommandContainer(timeoutMilliseconds: timeout)
            guard container.transactionID == transactionID else {
                throw AndroidUSBPTPTransportError.mismatchedTransaction(
                    expected: transactionID, actual: container.transactionID)
            }
            switch container.type {
            case .data:
                guard container.code == operationCode.rawValue else {
                    throw AndroidUSBPTPTransportError.mismatchedOperation(
                        expected: operationCode.rawValue, actual: container.code)
                }
                dataPayload.append(container.payload)
            case .response:
                let result = try PTPUSBTransaction.result(
                    operationCode: operationCode,
                    responseBytes: Data(container.serializedBytes),
                    dataBytes: dataPayload
                )
                // PTP reserves transaction ID 0 for OpenSession and starts
                // the new logical session at 1. USB pairing retries reuse a
                // claimed physical interface, unlike PTP-IP where the retry
                // gets a new transport instance, so carry out that reset here.
                if operationCode == .openSession,
                    transactionID == 0,
                    result.operationResponse.responseCode == .ok
                        || result.operationResponse.responseCode == .sessionAlreadyOpen
                {
                    nextTransactionID = 1
                }
                return result
            case .command, .event:
                throw AndroidUSBPTPTransportError.unexpectedContainer(container.type)
            }
        }
    }

    /// Blocking event entry used by the USB session's one Swift-owned drain
    /// thread. An empty platform read is a typed idle timeout, not a link loss;
    /// `PTPIPClientSession.runUSBEventDrain` catches that timeout and continues.
    func nextEventSynchronously() throws -> PTPEvent {
        eventLock.lock()
        defer { eventLock.unlock() }
        while true {
            let container = try nextEventContainer(timeoutMilliseconds: eventTimeoutMilliseconds)
            guard container.type == .event else { continue }
            return try PTPUSBTransaction.event(from: Data(container.serializedBytes))
        }
    }

    private let rawIO: any USBPTPRawIO
    private let transactionLock = NSLock()
    private let eventLock = NSLock()
    private let stateLock = NSLock()
    private var nextTransactionID: UInt32 = 1
    private var isClosed = false
    private var commandBuffer = PTPUSBReadBuffer()
    private var eventBuffer = PTPUSBReadBuffer()

    private func validateDataPhase(
        operationCode: PTPOperationCode,
        dataPhase: PTPDataPhase,
        dataOut: Data?
    ) throws {
        switch dataPhase {
        case .dataOut:
            guard dataOut != nil else {
                throw AndroidUSBPTPTransportError.missingDataOut(operationCode)
            }
        case .noDataOrDataIn, .dataIn:
            guard dataOut == nil else {
                throw AndroidUSBPTPTransportError.unexpectedDataOut(operationCode)
            }
        }
    }

    private func write(_ bytes: Data, timeoutMilliseconds: Int) throws {
        var offset = 0
        let raw = Array(bytes)
        while offset < raw.count {
            let remaining = Array(raw[offset...])
            guard let count = rawIO.writeBulk(remaining, timeoutMilliseconds: timeoutMilliseconds)
            else {
                throw closedOrReadFailure("the camera")
            }
            guard count > 0, count <= remaining.count else {
                throw AndroidUSBPTPTransportError.writeFailed(
                    expected: remaining.count, actual: count)
            }
            offset += count
        }
    }

    private func nextCommandContainer(timeoutMilliseconds: Int) throws -> PTPUSBContainer {
        while true {
            if let container = try commandBuffer.nextContainer() { return container }
            commandBuffer.append(
                try readBulkBytes(
                    label: "the camera response", timeoutMilliseconds: timeoutMilliseconds))
        }
    }

    private func nextEventContainer(timeoutMilliseconds: Int) throws -> PTPUSBContainer {
        while true {
            if let container = try eventBuffer.nextContainer() { return container }
            eventBuffer.append(
                try readEventBytes(
                    label: "the camera event", timeoutMilliseconds: timeoutMilliseconds))
        }
    }

    private func readBulkBytes(label: String, timeoutMilliseconds: Int) throws -> [UInt8] {
        guard
            let bytes = rawIO.readBulk(
                maxBytes: readChunkSize, timeoutMilliseconds: timeoutMilliseconds)
        else {
            throw closedOrReadFailure(label)
        }
        guard !bytes.isEmpty else { throw AndroidUSBPTPTransportError.timeout(label) }
        return bytes
    }

    private func readEventBytes(label: String, timeoutMilliseconds: Int) throws -> [UInt8] {
        guard
            let bytes = rawIO.readEvent(
                maxBytes: readChunkSize, timeoutMilliseconds: timeoutMilliseconds)
        else {
            throw closedOrReadFailure(label)
        }
        guard !bytes.isEmpty else { throw AndroidUSBPTPTransportError.timeout(label) }
        return bytes
    }

    private func closedOrReadFailure(_ label: String) -> AndroidUSBPTPTransportError {
        if rawIO.isClosed() { return .connectionClosed }
        return .readFailed(label)
    }

    private func timeoutMilliseconds(deadline: Duration?) -> Int {
        guard let deadline else { return defaultTimeoutMilliseconds }
        let components = deadline.components
        let milliseconds =
            components.seconds * 1_000
            + components.attoseconds / 1_000_000_000_000_000
        return Int(Swift.max(1, Swift.min(milliseconds, Int64(defaultTimeoutMilliseconds))))
    }

    private let defaultTimeoutMilliseconds = 10_000
    /// Keep idle interrupt reads short so disconnect waits at most one cycle.
    private let eventTimeoutMilliseconds = 1_000
    private let readChunkSize = 16 * 1024
}
