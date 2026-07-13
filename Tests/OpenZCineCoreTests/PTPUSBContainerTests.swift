import Foundation
import Testing

@testable import OpenZCineCore

@Test func usbContainerSerializesHeaderAndPayloadLittleEndian() {
    let container = PTPUSBContainer(
        type: .command,
        code: 0x1002,
        transactionID: 0,
        payload: Data([0x01, 0x00, 0x00, 0x00])
    )

    #expect(
        container.serializedBytes == [
            16, 0, 0, 0,
            1, 0,
            0x02, 0x10,
            0, 0, 0, 0,
            0x01, 0x00, 0x00, 0x00,
        ])
}

@Test func usbContainerRoundTrips() throws {
    let original = PTPUSBContainer(
        type: .response,
        code: 0x2001,
        transactionID: 42,
        payload: Data([0xAA, 0xBB, 0xCC, 0xDD])
    )

    let parsed = try PTPUSBContainer(serializedBytes: original.serializedBytes)

    #expect(parsed == original)
}

@Test func usbContainerRejectsShortHeader() {
    #expect(throws: PTPUSBContainerError.shortHeader(actualLength: 4)) {
        _ = try PTPUSBContainer(serializedBytes: [1, 2, 3, 4])
    }
}

@Test func usbContainerRejectsDeclaredLengthBeyondBuffer() {
    #expect(throws: PTPUSBContainerError.invalidLength(declaredLength: 20, actualLength: 12)) {
        _ = try PTPUSBContainer(serializedBytes: [
            20, 0, 0, 0,
            3, 0,
            0x01, 0x20,
            0, 0, 0, 0,
        ])
    }
}

@Test func usbContainerRejectsUnknownType() {
    #expect(throws: PTPUSBContainerError.unknownType(rawType: 9)) {
        _ = try PTPUSBContainer(serializedBytes: [
            12, 0, 0, 0,
            9, 0,
            0x01, 0x20,
            0, 0, 0, 0,
        ])
    }
}

@Test func usbCommandContainerCarriesOpcodeTransactionAndParameters() {
    let command = PTPUSBTransaction.commandContainer(
        operationCode: .getDevicePropValueEx,
        transactionID: 7,
        parameters: [0xD1AA]
    )

    #expect(
        Array(command) == [
            16, 0, 0, 0,
            1, 0,
            0x3B, 0x94,
            7, 0, 0, 0,
            0xAA, 0xD1, 0x00, 0x00,
        ])
}

@Test func usbTransactionResultParsesResponseAndRawData() throws {
    let response = PTPUSBContainer(
        type: .response, code: 0x2001, transactionID: 5, payload: Data()
    )
    let dataset = Data([0x11, 0x22, 0x33])

    let result = try PTPUSBTransaction.result(
        operationCode: .getDeviceInfo,
        responseBytes: Data(response.serializedBytes),
        dataBytes: dataset
    )

    #expect(result.operationResponse.responseCode == .ok)
    #expect(result.operationResponse.transactionID == 5)
    #expect(result.data == dataset)
}

@Test func usbTransactionResultStripsFullDataContainer() throws {
    let dataset = Data([0x11, 0x22, 0x33, 0x44])
    let dataContainer = PTPUSBContainer(
        type: .data,
        code: PTPOperationCode.getDeviceInfo.rawValue,
        transactionID: 5,
        payload: dataset
    )
    let response = PTPUSBContainer(
        type: .response, code: 0x2001, transactionID: 5, payload: Data()
    )

    let result = try PTPUSBTransaction.result(
        operationCode: .getDeviceInfo,
        responseBytes: Data(response.serializedBytes),
        dataBytes: Data(dataContainer.serializedBytes)
    )

    #expect(result.data == dataset)
}

@Test func usbTransactionResultKeepsDatasetThatMerelyResemblesAContainer() throws {
    // Header-shaped bytes whose transaction ID does not match must not be stripped.
    let lookalike = PTPUSBContainer(
        type: .data,
        code: PTPOperationCode.getDeviceInfo.rawValue,
        transactionID: 99,
        payload: Data([0x01])
    )
    let response = PTPUSBContainer(
        type: .response, code: 0x2001, transactionID: 5, payload: Data()
    )

    let result = try PTPUSBTransaction.result(
        operationCode: .getDeviceInfo,
        responseBytes: Data(response.serializedBytes),
        dataBytes: Data(lookalike.serializedBytes)
    )

    #expect(result.data == Data(lookalike.serializedBytes))
}

@Test func usbTransactionResultParsesResponseParameters() throws {
    let response = PTPUSBContainer(
        type: .response,
        code: 0x2019,
        transactionID: 3,
        payload: Data([0x01, 0x00, 0x00, 0x00, 0x02, 0x00, 0x00, 0x00])
    )

    let result = try PTPUSBTransaction.result(
        operationCode: .deviceReady,
        responseBytes: Data(response.serializedBytes),
        dataBytes: Data()
    )

    #expect(result.operationResponse.responseCode == .deviceBusy)
    #expect(result.operationResponse.parameters == [1, 2])
}

@Test func usbTransactionResultRejectsNonResponseContainer() {
    let event = PTPUSBContainer(type: .event, code: 0xC10A, transactionID: 1, payload: Data())

    #expect(throws: PTPUSBContainerError.unknownType(rawType: 4)) {
        _ = try PTPUSBTransaction.result(
            operationCode: .deviceReady,
            responseBytes: Data(event.serializedBytes),
            dataBytes: Data()
        )
    }
}

@Test func usbEventContainerDecodesToPTPEvent() throws {
    let container = PTPUSBContainer(
        type: .event,
        code: 0xC10A,
        transactionID: 12,
        payload: Data([0x07, 0x00, 0x00, 0x00])
    )

    let event = try PTPUSBTransaction.event(from: Data(container.serializedBytes))

    #expect(event.eventCode == .movieRecordStarted)
    #expect(event.transactionID == 12)
    #expect(event.parameters == [7])
    #expect(event.inferredRecordState == .recording)
}

@Test func usbEventDecodingRejectsNonEventContainer() {
    let command = PTPUSBTransaction.commandContainer(operationCode: .deviceReady, transactionID: 1)

    #expect(throws: PTPEventError.notAnEventPacket) {
        _ = try PTPUSBTransaction.event(from: command)
    }
}
