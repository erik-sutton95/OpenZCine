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

    @Test func changeAfAreaWritesOneCommandContainerAndNoUSBDataPayload() throws {
        let raw = FakeUSBPTPRawIO(bulkReads: [response(transactionID: 1)])
        let transport = AndroidUSBPTPTransport(rawIO: raw)

        _ = try transport.executeTransactionSynchronously(
            operationCode: .changeAfArea,
            parameters: [1_234, 567],
            dataPhase: .noDataOrDataIn,
            dataOut: nil)

        #expect(raw.writes.count == 1)
        let commandBytes = try #require(raw.writes.first)
        let command = try PTPUSBContainer(serializedBytes: commandBytes)
        #expect(command.type == .command)
        #expect(command.code == PTPOperationCode.changeAfArea.rawValue)
        #expect(command.transactionID == 1)
        #expect(
            command.payload
                == Data(ByteCoding.uint32LE(1_234) + ByteCoding.uint32LE(567)))
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

    @Test func descriptorBackedUSBWritesReuseExactFakeCameraValuesAndReadThemBack() throws {
        let currentScreen: UInt64 = 0x1770_0D08_0019_0000
        let selectedScreen: UInt64 = 0x0F00_0870_003C_0000
        let currentCodec: UInt32 = 0x0031_0A03
        let selectedCodec: UInt32 = 0x0001_0A01
        let screenDescriptor = enumDescriptor(
            property: .movieRecordScreenSize,
            valueByteCount: 8,
            values: [ByteCoding.uint64LE(currentScreen), ByteCoding.uint64LE(selectedScreen)])
        let codecDescriptor = enumDescriptor(
            property: .movieFileType,
            valueByteCount: 4,
            values: [ByteCoding.uint32LE(currentCodec), ByteCoding.uint32LE(selectedCodec)])
        let raw = FakeUSBPTPRawIO(
            bulkReads: [
                dataAndResponse(
                    operation: .getDevicePropDescEx,
                    transactionID: 1,
                    payload: screenDescriptor),
                response(transactionID: 2),
                dataAndResponse(
                    operation: .getDevicePropValueEx,
                    transactionID: 3,
                    payload: Data(ByteCoding.uint64LE(selectedScreen))),
                dataAndResponse(
                    operation: .getDevicePropDescEx,
                    transactionID: 4,
                    payload: codecDescriptor),
                response(transactionID: 5),
                dataAndResponse(
                    operation: .getDevicePropValueEx,
                    transactionID: 6,
                    payload: Data(ByteCoding.uint32LE(selectedCodec))),
            ])
        let transport = AndroidUSBPTPTransport(rawIO: raw)

        let screenResult = try transport.executeTransactionSynchronously(
            operationCode: .getDevicePropDescEx,
            parameters: [PTPPropertyCode.movieRecordScreenSize.rawValue],
            dataPhase: .dataIn)
        let screenMode = try #require(
            PTPCameraPropertyDecoders.screenSizeModes(fromDescriptor: screenResult.data)
                .first { $0.label == "4K · 60p" })
        _ = try transport.executeTransactionSynchronously(
            operationCode: .setDevicePropValue,
            parameters: [PTPPropertyCode.movieRecordScreenSize.rawValue],
            dataPhase: .dataOut,
            dataOut: Data(ByteCoding.uint64LE(screenMode.raw)))
        let screenReadback = try transport.executeTransactionSynchronously(
            operationCode: .getDevicePropValueEx,
            parameters: [PTPPropertyCode.movieRecordScreenSize.rawValue],
            dataPhase: .dataIn)
        #expect(screenReadback.data == Data(ByteCoding.uint64LE(screenMode.raw)))

        let codecResult = try transport.executeTransactionSynchronously(
            operationCode: .getDevicePropDescEx,
            parameters: [PTPPropertyCode.movieFileType.rawValue],
            dataPhase: .dataIn)
        let codecRawValues = PTPCameraPropertyDecoders.devicePropDescEnumValues(
            data: codecResult.data, valueByteCount: 4)
        let codecMode = try #require(
            PTPCameraPropertyDecoders.fileTypeModes(fromEnum: codecRawValues)
                .first { $0.label == "H.265" })
        _ = try transport.executeTransactionSynchronously(
            operationCode: .setDevicePropValue,
            parameters: [PTPPropertyCode.movieFileType.rawValue],
            dataPhase: .dataOut,
            dataOut: Data(ByteCoding.uint32LE(codecMode.raw)))
        let codecReadback = try transport.executeTransactionSynchronously(
            operationCode: .getDevicePropValueEx,
            parameters: [PTPPropertyCode.movieFileType.rawValue],
            dataPhase: .dataIn)
        #expect(codecReadback.data == Data(ByteCoding.uint32LE(codecMode.raw)))

        let dataWrites = try raw.writes.compactMap { bytes -> PTPUSBContainer? in
            let container = try PTPUSBContainer(serializedBytes: bytes)
            return container.type == .data ? container : nil
        }
        #expect(dataWrites.map(\.payload) == [screenReadback.data, codecReadback.data])
        #expect(dataWrites.map(\.transactionID) == [2, 5])
    }

    @Test func usbRoundTripMeasuresResponseDelayAndClearsOnClose() throws {
        let raw = FakeUSBPTPRawIO(
            bulkReads: [response(transactionID: 1)],
            bulkReadDelayMilliseconds: 12)
        let transport = AndroidUSBPTPTransport(rawIO: raw)

        _ = try transport.executeTransactionSynchronously(operationCode: .getDeviceInfo)

        let measured = try #require(transport.latestCommandRoundTripMilliseconds())
        #expect(measured >= 8)
        #expect(measured < 1_000)
        transport.close()
        #expect(transport.latestCommandRoundTripMilliseconds() == nil)
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

private func dataAndResponse(
    operation: PTPOperationCode,
    transactionID: UInt32,
    payload: Data
) -> [UInt8] {
    PTPUSBContainer(
        type: .data,
        code: operation.rawValue,
        transactionID: transactionID,
        payload: payload
    ).serializedBytes + response(transactionID: transactionID)
}

private func enumDescriptor(
    property: PTPPropertyCode,
    valueByteCount: Int,
    values: [[UInt8]]
) -> Data {
    var bytes = ByteCoding.uint32LE(property.rawValue)
    bytes += ByteCoding.uint16LE(UInt16(valueByteCount))
    bytes.append(1)
    bytes += [UInt8](repeating: 0, count: valueByteCount * 2)
    bytes.append(2)
    bytes += ByteCoding.uint16LE(UInt16(values.count))
    for value in values {
        bytes += value
    }
    return Data(bytes)
}

private final class FakeUSBPTPRawIO: USBPTPRawIO, @unchecked Sendable {
    var writes: [[UInt8]] = []
    private var bulkReads: [[UInt8]]
    private var eventReads: [[UInt8]]
    private let bulkReadDelayMilliseconds: UInt64
    private var closed = false

    init(
        bulkReads: [[UInt8]] = [],
        eventReads: [[UInt8]] = [],
        bulkReadDelayMilliseconds: UInt64 = 0
    ) {
        self.bulkReads = bulkReads
        self.eventReads = eventReads
        self.bulkReadDelayMilliseconds = bulkReadDelayMilliseconds
    }

    func writeBulk(_ bytes: [UInt8], timeoutMilliseconds _: Int) -> Int? {
        guard !closed else { return nil }
        writes.append(bytes)
        return bytes.count
    }

    func readBulk(maxBytes _: Int, timeoutMilliseconds _: Int) -> [UInt8]? {
        guard !closed else { return nil }
        guard !bulkReads.isEmpty else { return [] }
        if bulkReadDelayMilliseconds > 0 {
            Thread.sleep(forTimeInterval: Double(bulkReadDelayMilliseconds) / 1_000)
        }
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
