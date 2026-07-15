import Foundation
import OpenZCineCore
import Testing

@testable import OpenZCineAndroidFacade

struct USBPTPTransactionTransportTests {
    @Test func idleInterruptReadIsNonterminalAndTheNextEventStillArrives() throws {
        let event = PTPUSBContainer(
            type: .event,
            code: PTPEventCode.movieRecordStarted.rawValue,
            transactionID: 12,
            payload: Data()
        )
        let raw = FakeUSBPTPRawIO(eventReads: [[], event.serializedBytes])
        let transport = AndroidUSBPTPTransport(rawIO: raw)

        #expect(throws: AndroidUSBPTPTransportError.timeout("the camera event")) {
            try transport.nextEventSynchronously()
        }
        #expect(!raw.isClosed())

        let received = try transport.nextEventSynchronously()
        #expect(received.rawEventCode == PTPEventCode.movieRecordStarted.rawValue)
        #expect(received.transactionID == 12)
        #expect(!raw.isClosed())
    }

    @Test func malformedDataPhaseNeverWritesAnAmbiguousUSBTransaction() throws {
        let raw = FakeUSBPTPRawIO()
        let transport = AndroidUSBPTPTransport(rawIO: raw)

        #expect(throws: AndroidUSBPTPTransportError.missingDataOut(.setDevicePropValue)) {
            try transport.executeTransactionSynchronously(
                operationCode: .setDevicePropValue,
                dataPhase: .dataOut
            )
        }
        #expect(raw.writes.isEmpty)

        #expect(throws: AndroidUSBPTPTransportError.unexpectedDataOut(.getDeviceInfo)) {
            try transport.executeTransactionSynchronously(
                operationCode: .getDeviceInfo,
                dataPhase: .dataIn,
                dataOut: Data([0x00])
            )
        }
        #expect(raw.writes.isEmpty)
    }

    @Test func reopeningAPTPSessionRestartsItsTransactionSequenceAtOne() throws {
        let raw = FakeUSBPTPRawIO(
            bulkReads: [
                response(transactionID: 0),
                response(transactionID: 1),
                response(transactionID: 2),
                response(transactionID: 0),
                response(transactionID: 1),
            ]
        )
        let transport = AndroidUSBPTPTransport(rawIO: raw)

        _ = try transport.executeTransactionSynchronously(
            operationCode: .openSession,
            transactionID: 0,
            parameters: [1]
        )
        _ = try transport.executeTransactionSynchronously(operationCode: .getDeviceInfo)
        _ = try transport.executeTransactionSynchronously(operationCode: .closeSession)
        _ = try transport.executeTransactionSynchronously(
            operationCode: .openSession,
            transactionID: 0,
            parameters: [1]
        )
        _ = try transport.executeTransactionSynchronously(operationCode: .getDeviceInfo)

        let transactionIDs = try raw.writes.map {
            try PTPUSBContainer(serializedBytes: $0).transactionID
        }
        #expect(transactionIDs == [0, 1, 2, 0, 1])
    }

    @Test func closingUSBTransportInterruptsAnInFlightCommandRead() {
        let raw = BlockingUSBPTPRawIO()
        let transport = AndroidUSBPTPTransport(rawIO: raw)
        let finished = DispatchSemaphore(value: 0)
        Thread.detachNewThread {
            _ = try? transport.executeTransactionSynchronously(operationCode: .getDeviceInfo)
            finished.signal()
        }
        defer { transport.close() }

        #expect(raw.waitUntilReadStarts(timeout: 1))
        transport.close()
        #expect(raw.isClosed())
        #expect(finished.wait(timeout: .now() + 1) == .success)
    }
}

private func response(transactionID: UInt32) -> [UInt8] {
    PTPUSBContainer(
        type: .response,
        code: PTPResponseCode.ok.rawValue,
        transactionID: transactionID,
        payload: Data()
    ).serializedBytes
}

private final class FakeUSBPTPRawIO: USBPTPRawIO, @unchecked Sendable {
    var writes: [[UInt8]] = []
    private var bulkReads: [[UInt8]]
    private var eventReads: [[UInt8]]
    private var closed = false

    init(bulkReads: [[UInt8]] = [], eventReads: [[UInt8]] = []) {
        self.bulkReads = bulkReads
        self.eventReads = eventReads
    }

    func writeBulk(_ bytes: [UInt8], timeoutMilliseconds _: Int) -> Int? {
        guard !closed else { return nil }
        writes.append(bytes)
        return bytes.count
    }

    func readBulk(maxBytes _: Int, timeoutMilliseconds _: Int) -> [UInt8]? {
        guard !closed else { return nil }
        guard !bulkReads.isEmpty else { return [] }
        return bulkReads.removeFirst()
    }

    func readEvent(maxBytes _: Int, timeoutMilliseconds _: Int) -> [UInt8]? {
        guard !closed else { return nil }
        guard !eventReads.isEmpty else { return [] }
        return eventReads.removeFirst()
    }

    func isClosed() -> Bool { closed }

    func close() {
        closed = true
    }
}

private final class BlockingUSBPTPRawIO: USBPTPRawIO, @unchecked Sendable {
    private let condition = NSCondition()
    private var closed = false
    private var readStarted = false

    func writeBulk(_ bytes: [UInt8], timeoutMilliseconds _: Int) -> Int? {
        guard !isClosed() else { return nil }
        return bytes.count
    }

    func readBulk(maxBytes _: Int, timeoutMilliseconds _: Int) -> [UInt8]? {
        condition.lock()
        readStarted = true
        condition.broadcast()
        while !closed {
            condition.wait()
        }
        condition.unlock()
        return nil
    }

    func readEvent(maxBytes _: Int, timeoutMilliseconds _: Int) -> [UInt8]? { nil }

    func isClosed() -> Bool {
        condition.lock()
        defer { condition.unlock() }
        return closed
    }

    func close() {
        condition.lock()
        closed = true
        condition.broadcast()
        condition.unlock()
    }

    func waitUntilReadStarts(timeout: TimeInterval) -> Bool {
        condition.lock()
        defer { condition.unlock() }
        let deadline = Date().addingTimeInterval(timeout)
        while !readStarted {
            guard condition.wait(until: deadline) else { return false }
        }
        return true
    }
}
