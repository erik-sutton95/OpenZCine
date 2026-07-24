import Foundation
import Testing

@testable import OpenZCineCore

@Suite("PTP event: movie record lifecycle")
struct PTPEventTests {
    private func eventPayload(code: UInt16, transactionID: UInt32 = 1, parameters: [UInt32] = [])
        -> Data
    {
        var bytes: [UInt8] = []
        bytes += ByteCoding.uint16LE(code)
        bytes += ByteCoding.uint32LE(transactionID)
        for parameter in parameters {
            bytes += ByteCoding.uint32LE(parameter)
        }
        return Data(bytes)
    }

    @Test func movieRecordStartedInfersRecording() throws {
        let event = try PTPEvent(payloadBytes: Array(eventPayload(code: 0xC10A)))
        #expect(event.eventCode == .movieRecordStarted)
        #expect(event.inferredRecordState == .recording)
    }

    @Test func movieRecordCompleteInfersStandby() throws {
        let event = try PTPEvent(payloadBytes: Array(eventPayload(code: 0xC108)))
        #expect(event.eventCode == .movieRecordComplete)
        #expect(event.inferredRecordState == .standby)
    }

    @Test func movieRecordInterruptedInfersStandby() throws {
        let event = try PTPEvent(payloadBytes: Array(eventPayload(code: 0xC105, parameters: [42])))
        #expect(event.eventCode == .movieRecordInterrupted)
        #expect(event.parameters == [42])
        #expect(event.recordingInterruptionErrorCode == 42)
        #expect(event.inferredRecordState == .standby)
    }

    @Test func unrelatedEventHasNoRecordHint() throws {
        let event = try PTPEvent(payloadBytes: Array(eventPayload(code: 0x4006)))
        #expect(event.rawEventCode == 0x4006)
        #expect(event.eventCode == .unknown)
        #expect(event.recordingInterruptionErrorCode == nil)
        #expect(event.inferredRecordState == nil)
    }

    @Test func unknownNikonCodePreservesItsRawValue() throws {
        let event = try PTPEvent(payloadBytes: Array(eventPayload(code: 0xC1FE, parameters: [7])))

        #expect(event.rawEventCode == 0xC1FE)
        #expect(event.eventCode == .unknown)
        #expect(event.parameters == [7])
    }

    @Test func parseFromEventPacket() throws {
        let payload = eventPayload(code: 0xC10A)
        let packet = PTPIPPacket(type: .event, payload: payload)
        let event = try PTPEvent(from: packet)
        #expect(event.inferredRecordState == .recording)
    }

    @Test func getEventExListParsesMultipleElements() {
        // NumberOfElements=2; el1 = ObjectAdded(0x4002) with 1 param (a handle);
        // el2 = CaptureComplete(0x400D) with 0 params.
        var bytes: [UInt8] = []
        func u16(_ v: UInt16) {
            bytes.append(UInt8(v & 0xFF))
            bytes.append(UInt8((v >> 8) & 0xFF))
        }
        func u32(_ v: UInt32) {
            u16(UInt16(v & 0xFFFF))
            u16(UInt16((v >> 16) & 0xFFFF))
        }
        u32(2)
        u16(0x4002)
        u16(1)
        u32(0x0001_0042)
        u16(0x400D)
        u16(0)
        let events = PTPNikonEventList.parse(bytes)
        #expect(events.count == 2)
        #expect(events[0].eventCode == .objectAdded)
        #expect(events[0].parameters == [0x0001_0042])
        #expect(events[1].eventCode == .captureComplete)
        #expect(events[1].parameters.isEmpty)
    }

    @Test func getEventExEmptyListIsNoEvents() {
        #expect(PTPNikonEventList.parse([0, 0, 0, 0]).isEmpty)
        #expect(PTPNikonEventList.parse([]).isEmpty)
    }

    @Test func getEventExStopsAtTruncatedPayload() {
        // Declares 3 elements but only one complete element of bytes follows.
        var bytes: [UInt8] = [3, 0, 0, 0]
        bytes += [0x02, 0x40, 0x00, 0x00]  // ObjectAdded, 0 params
        let events = PTPNikonEventList.parse(bytes)
        #expect(events.count == 1)
        #expect(events[0].eventCode == .objectAdded)
    }

}
