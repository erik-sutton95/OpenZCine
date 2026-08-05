import Foundation
import Testing

@testable import OpenZCineCore

@Suite("Watch relay wire protocol")
struct WatchRelayProtocolTests {
    private var goldenFixtureURL: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/WatchRelayProtocolV1.json")
    }

    private func goldenPayload(named name: String) throws -> Data {
        let data = try Data(contentsOf: goldenFixtureURL)
        let root = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let payload = try #require(root[name])
        if let string = payload as? String {
            return try JSONEncoder().encode(string)
        }
        return try JSONSerialization.data(withJSONObject: payload)
    }

    private func goldenEnvelope(kind: WatchRelayProtocol.Kind, named name: String) throws -> Data {
        Data([kind.rawValue]) + (try goldenPayload(named: name))
    }

    private func sampleState() -> WatchRelayState {
        WatchRelayState(
            recordState: .recording,
            timecode: Timecode(on: true, hour: 1, minute: 2, second: 3, frame: 4),
            mediaStatus: MediaStatus(gigabytesFree: 521, percentFree: 47, minutesRemaining: 47),
            media: "521 GB · 47 min",
            cameraBatteryPercent: 80,
            cameraName: "Nikon ZR",
            isRecording: true,
            connection: .connected,
            feedLive: true,
            liveFPS: "25.00"
        )
    }

    @Test("State round-trips through its envelope")
    func stateEnvelopeRoundTrips() throws {
        let state = sampleState()
        let envelope = try WatchRelayEnvelope.encode(kind: .state, payload: state)
        #expect(try WatchRelayEnvelope.kind(of: envelope) == .state)
        let decoded = try WatchRelayEnvelope.decode(WatchRelayState.self, from: envelope)
        #expect(decoded == state)
    }

    @Test("State with no media status round-trips")
    func stateWithoutMediaStatusRoundTrips() throws {
        let state = WatchRelayState(
            recordState: .standby,
            timecode: Timecode(on: false, hour: 0, minute: 0, second: 0, frame: 0),
            mediaStatus: nil,
            media: "—",
            cameraBatteryPercent: 0,
            cameraName: "",
            isRecording: false,
            connection: .noCamera,
            feedLive: false,
            liveFPS: "0.00"
        )
        let envelope = try WatchRelayEnvelope.encode(kind: .state, payload: state)
        let decoded = try WatchRelayEnvelope.decode(WatchRelayState.self, from: envelope)
        #expect(decoded == state)
    }

    @Test("Frame round-trips through its envelope")
    func frameEnvelopeRoundTrips() throws {
        let frame = WatchRelayFrame(
            jpeg: Data([0xFF, 0xD8, 0xFF, 0xE0, 0x00, 0x10]),
            timecode: Timecode(on: true, hour: 12, minute: 34, second: 56, frame: 7),
            isRecording: true
        )
        let envelope = try WatchRelayEnvelope.encode(kind: .frame, payload: frame)
        #expect(try WatchRelayEnvelope.kind(of: envelope) == .frame)
        let decoded = try WatchRelayEnvelope.decode(WatchRelayFrame.self, from: envelope)
        #expect(decoded == frame)
    }

    @Test("Command round-trips through its envelope")
    func commandEnvelopeRoundTrips() throws {
        let command = WatchRelayCommand.toggleRecord
        let envelope = try WatchRelayEnvelope.encode(kind: .command, payload: command)
        #expect(try WatchRelayEnvelope.kind(of: envelope) == .command)
        let decoded = try WatchRelayEnvelope.decode(WatchRelayCommand.self, from: envelope)
        #expect(decoded == command)
    }

    @Test("Result round-trips through its envelope")
    func resultEnvelopeRoundTrips() throws {
        let result = WatchCommandResult(accepted: false, isRecording: true, error: "not reachable")
        let envelope = try WatchRelayEnvelope.encode(kind: .result, payload: result)
        #expect(try WatchRelayEnvelope.kind(of: envelope) == .result)
        let decoded = try WatchRelayEnvelope.decode(WatchCommandResult.self, from: envelope)
        #expect(decoded == result)
    }

    @Test("v1 golden fixtures stay compatible with the canonical Swift models")
    func v1GoldenFixturesRemainCanonical() throws {
        let fixture = try Data(contentsOf: goldenFixtureURL)
        let root = try #require(JSONSerialization.jsonObject(with: fixture) as? [String: Any])
        #expect(root["protocolVersion"] as? Int == 1)

        let stateEnvelope = try goldenEnvelope(kind: .state, named: "state")
        let state = try WatchRelayEnvelope.decode(WatchRelayState.self, from: stateEnvelope)
        #expect(state == sampleState())

        let stateWithoutMediaEnvelope =
            try goldenEnvelope(kind: .state, named: "stateWithoutMediaStatus")
        let stateWithoutMedia =
            try WatchRelayEnvelope.decode(WatchRelayState.self, from: stateWithoutMediaEnvelope)
        #expect(stateWithoutMedia.mediaStatus == nil)

        let frameEnvelope = try goldenEnvelope(kind: .frame, named: "frame")
        let frame = try WatchRelayEnvelope.decode(WatchRelayFrame.self, from: frameEnvelope)
        #expect(frame.jpeg == Data([0xFF, 0xD8, 0xFF, 0xE0, 0x00, 0x10]))
        #expect(frame.timecode == Timecode(on: true, hour: 12, minute: 34, second: 56, frame: 7))

        let commandEnvelope = try goldenEnvelope(kind: .command, named: "command")
        let command = try WatchRelayEnvelope.decode(WatchRelayCommand.self, from: commandEnvelope)
        #expect(command == .toggleRecord)

        let resultEnvelope = try goldenEnvelope(kind: .result, named: "result")
        let result = try WatchRelayEnvelope.decode(WatchCommandResult.self, from: resultEnvelope)
        let expectedResult = WatchCommandResult(
            accepted: false,
            isRecording: true,
            error: "not reachable"
        )
        #expect(result == expectedResult)
    }

    @Test("Empty envelope reports an empty error")
    func emptyEnvelopeThrows() {
        #expect(throws: WatchRelayEnvelopeError.empty) {
            try WatchRelayEnvelope.kind(of: Data())
        }
    }

    @Test("Unknown kind byte is rejected")
    func unknownKindThrows() {
        #expect(throws: WatchRelayEnvelopeError.unknownKind(0x99)) {
            try WatchRelayEnvelope.kind(of: Data([0x99, 0x00]))
        }
    }
}
