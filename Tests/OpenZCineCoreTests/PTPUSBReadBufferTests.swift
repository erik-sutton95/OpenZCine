import Foundation
import OpenZCineCore
import Testing

@Test("PTP USB read buffer retains fragmented containers")
func fragmentedContainerIsReturnedOnlyAfterTheFinalBytesArrive() throws {
    let container = PTPUSBContainer(
        type: .response,
        code: PTPResponseCode.ok.rawValue,
        transactionID: 7,
        payload: Data([1, 2, 3])
    )
    let bytes = container.serializedBytes
    var buffer = PTPUSBReadBuffer()

    buffer.append(Array(bytes.prefix(6)))
    #expect(try buffer.nextContainer() == nil)

    buffer.append(Array(bytes.dropFirst(6)))
    #expect(try buffer.nextContainer() == container)
    #expect(buffer.bufferedByteCount == 0)
}

@Test("PTP USB read buffer retains a second container from one bulk read")
func multipleContainersFromOneReadRemainIndividuallyAddressable() throws {
    let first = PTPUSBContainer(type: .event, code: 0xC10A, transactionID: 0, payload: Data())
    let second = PTPUSBContainer(
        type: .response,
        code: PTPResponseCode.ok.rawValue,
        transactionID: 8,
        payload: Data()
    )
    var buffer = PTPUSBReadBuffer()
    buffer.append(first.serializedBytes + second.serializedBytes)

    #expect(try buffer.nextContainer() == first)
    #expect(try buffer.nextContainer() == second)
    #expect(try buffer.nextContainer() == nil)
}

@Test("PTP USB read buffer rejects an oversized declared container before allocating")
func oversizedDeclaredContainerIsRejected() throws {
    var buffer = PTPUSBReadBuffer(maximumContainerLength: 64)
    buffer.append([0x41, 0x00, 0x00, 0x00])

    #expect(
        throws: PTPUSBContainerError.exceedsMaximumLength(
            declaredLength: 65,
            maximumLength: 64
        )
    ) {
        try buffer.nextContainer()
    }
}
