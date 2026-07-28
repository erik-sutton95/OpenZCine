// Event-channel lifecycle tests against the scripted fake ZR. These cover the
// second PTP-IP socket that the command/live-view tests do not read: raw event
// preservation, Nikon record lifecycle delivery, and independent socket recovery.

import Dispatch
import Foundation
import OpenZCineCore
import Testing

@testable import OpenZCineAndroidFacade

struct EventDrainTests {
    private func connect(to server: FakeZRServer) throws -> PTPIPClientSession {
        try PTPIPClientSession.connect(
            host: "127.0.0.1", port: server.port, timeoutMilliseconds: 2_000)
    }

    @Test func drainsRawAndRecordingEventsUntilDisconnect() throws {
        let server = try FakeZRServer()
        defer { server.stop() }
        let session = try connect(to: server)
        let collector = EventCollector()

        try session.startEventDrain(
            onEvent: collector.record,
            onEnded: collector.markEnded)
        #expect(server.waitForEventChannel())

        // DevicePropChanged names the changed property in `e1` but carries no value.
        // Its raw code/UINT32 data must survive intact.
        #expect(
            server.sendEvent(
                rawEventCode: 0x4006,
                transactionID: 7,
                parameters: [0xD0A4, UInt32.max]))
        try collector.waitForEvents(atLeast: 1)

        try session.startRecording()
        try collector.waitForEvent(code: .movieRecordStarted)
        try session.stopRecording()
        try collector.waitForEvent(code: .movieRecordComplete)

        let events = collector.snapshot()
        let property = try #require(events.first)
        #expect(property.rawEventCode == 0x4006)
        #expect(property.eventCode == .devicePropChanged)
        #expect(property.changedPropertyCode == .movieRecProhibitionCondition)
        #expect(property.transactionID == 7)
        #expect(property.parameters == [0xD0A4, UInt32.max])
        #expect(events.contains { $0.inferredRecordState == .recording })
        #expect(events.contains { $0.inferredRecordState == .standby })

        session.disconnect()
        try collector.waitForEnd()
        #expect(collector.terminalMessage == nil)
    }

    @Test func rejectsASecondEventDrainForOneSession() throws {
        let server = try FakeZRServer()
        defer { server.stop() }
        let session = try connect(to: server)
        defer { session.disconnect() }

        try session.startEventDrain(onEvent: { _ in }, onEnded: { _ in })
        #expect(throws: PTPIPClientSessionError.eventDrainAlreadyActive) {
            try session.startEventDrain(onEvent: { _ in }, onEnded: { _ in })
        }
    }

    @Test func eventChannelFailureLeavesCommandAndLiveViewUsable() throws {
        let server = try FakeZRServer()
        defer { server.stop() }
        let session = try connect(to: server)
        defer { session.disconnect() }
        let collector = EventCollector()

        try session.startEventDrain(
            onEvent: collector.record,
            onEnded: collector.markEnded)
        #expect(server.waitForEventChannel())

        server.closeEventChannel()
        try collector.waitForEnd()

        #expect(collector.terminalMessage != nil)
        let firstFrame = DispatchSemaphore(value: 0)
        try session.startLiveView(
            onFrame: { _, _ in firstFrame.signal() },
            onEnded: {})
        defer { session.stopLiveView() }
        #expect(firstFrame.wait(timeout: .now() + .seconds(5)) == .success)
    }
}

// MARK: - #268 · the body's event queue is polled in EVERY chrome

/// `GetEventEx` (0x941C) is the channel a Nikon body announces a setting change on, and it used to
/// be polled in photography chrome only — where it had been introduced, for body-fired stills.
/// Cinema mode, how the ZR is normally shot, was left with no fast path at all: a lens-ring turn
/// waited for a round-robin that revisits any one property about every 20 s.
struct DeviceEventQueuePollTests {
    @Test func aBodySideChangeIsReadableInCinemaChrome() throws {
        let server = try FakeZRServer()
        defer { server.stop() }
        let session = try PTPIPClientSession.connect(
            host: "127.0.0.1", port: server.port, timeoutMilliseconds: 2_000)
        defer { session.disconnect() }

        // The fake body reports `LiveViewSelector = 1`, so one selector read leaves the session
        // in cinema chrome — the state the old gate refused to poll in.
        let chrome = session.refreshAndroidPropertySnapshot(.selector)
        #expect(chrome.properties.captureSelector == .video)
        #expect(!StillCapturePolicy.prefersPhotographyChrome(selector: .video))

        // One detent of the aperture ring: the aperture plus a dependent.
        server.queueDeviceEvent(
            rawEventCode: 0x4006, parameters: [PTPPropertyCode.movieFNumber.rawValue])
        server.queueDeviceEvent(
            rawEventCode: 0x4006, parameters: [PTPPropertyCode.exposureIndicateStatus.rawValue])

        let events = session.pollDeviceEvents()
        #expect(events.map(\.eventCode) == [.devicePropChanged, .devicePropChanged])
        #expect(
            events.compactMap(\.changedPropertyCode) == [.movieFNumber, .exposureIndicateStatus])
        // Parameter1 = 0 clears the body's queue, so the same burst is never re-read.
        #expect(session.pollDeviceEvents().isEmpty)
    }

    @Test func aBodyFiredCaptureStillSurfacesOnTheSameQueue() throws {
        // Widening the gate must not cost the poll its original job. Deciding whether a capture
        // is actionable belongs to the consumer — `MonitorScreen`'s body-capture sync already
        // applies the photography test — not to whether the queue gets read at all.
        let server = try FakeZRServer()
        defer { server.stop() }
        let session = try PTPIPClientSession.connect(
            host: "127.0.0.1", port: server.port, timeoutMilliseconds: 2_000)
        defer { session.disconnect() }

        server.queueDeviceEvent(rawEventCode: 0x4002, parameters: [0x0000_0011])
        #expect(session.pollDeviceEvents().map(\.eventCode) == [.objectAdded])
    }
}

// SAFETY: all mutable collector state is guarded by `condition`.
private final class EventCollector: @unchecked Sendable {
    private struct TimedOut: Error {}

    private let condition = NSCondition()
    private var events: [PTPEvent] = []
    private var ended = false
    private var terminal: String?

    func record(_ event: PTPEvent) {
        condition.lock()
        events.append(event)
        condition.broadcast()
        condition.unlock()
    }

    func markEnded(_ message: String?) {
        condition.lock()
        ended = true
        terminal = message
        condition.broadcast()
        condition.unlock()
    }

    var terminalMessage: String? {
        condition.lock()
        defer { condition.unlock() }
        return terminal
    }

    func snapshot() -> [PTPEvent] {
        condition.lock()
        defer { condition.unlock() }
        return events
    }

    func waitForEvents(atLeast count: Int, timeoutSeconds: TimeInterval = 5) throws {
        try wait(timeoutSeconds: timeoutSeconds) { events.count >= count }
    }

    func waitForEvent(code: PTPEventCode, timeoutSeconds: TimeInterval = 5) throws {
        try wait(timeoutSeconds: timeoutSeconds) { events.contains { $0.eventCode == code } }
    }

    func waitForEnd(timeoutSeconds: TimeInterval = 5) throws {
        try wait(timeoutSeconds: timeoutSeconds) { ended }
    }

    private func wait(timeoutSeconds: TimeInterval, matching predicate: () -> Bool) throws {
        condition.lock()
        defer { condition.unlock() }
        let deadline = Date().addingTimeInterval(timeoutSeconds)
        while !predicate() {
            guard condition.wait(until: deadline) else { throw TimedOut() }
        }
    }
}
