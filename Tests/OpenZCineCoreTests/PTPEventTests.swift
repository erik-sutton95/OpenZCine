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
        #expect(event.eventCode == .unknown)
        #expect(event.recordingInterruptionErrorCode == nil)
        #expect(event.inferredRecordState == nil)
    }

    @Test func parseFromEventPacket() throws {
        let payload = eventPayload(code: 0xC10A)
        let packet = PTPIPPacket(type: .event, payload: payload)
        let event = try PTPEvent(from: packet)
        #expect(event.inferredRecordState == .recording)
    }
}
