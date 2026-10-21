import Foundation
import OpenZCineCore
import Testing

@testable import OpenZCineAndroidFacade

private final class RackWireCamera: @unchecked Sendable {
    private let lock = NSLock()
    private var events: [String] = []
    private var stopped: Set<Int64> = []
    var log: [String] { lock.withLock { events } }
    var driver: NikonFocusRackAccess {
        .init(
            isCurrent: { true },
            prepareRun: { [self] run in
                lock.withLock {
                    events.append("prepare")
                    return !stopped.contains(run)
                }
            },
            requestStop: { [self] run in
                lock.withLock {
                    stopped.insert(run)
                    events.append("stop")
                }
            },
            driveChunk: { [self] run, _, _ in
                let admitted = lock.withLock {
                    if stopped.contains(run) { return false }
                    events.append("drive")
                    return true
                }
                if !admitted { return .cancelledBeforeActivation }
                try? await Task.sleep(for: .milliseconds(15))
                return lock.withLock { stopped.contains(run) ? .cancelledReady : .complete }
            },
            refreshSafety: {
                try .init(
                    reported: .init(
                        focalLength: "70", focalMinX100: 3500,
                        focalMaxX100: 10000, apertureMinX100: 280, focusMode: "AF-S",
                        focusArea: "Single-point AF", focusSubject: "Off", captureSelector: .video))
            })
    }
}

private struct RackWireReply: Decodable {
    let state: FocusRackState?
    let error: String?
    let templates: [FocusRackTemplate]
    let templatesJSON: String
    let traceJSON: String?
}

private func rackWireReply(
    _ wire: FocusRackWire, _ owner: String, kind: String = "poll",
    fields: [String: Any] = [:]
) throws -> RackWireReply {
    var request = fields
    request["kind"] = kind
    let requestData = try JSONSerialization.data(withJSONObject: request)
    let requestJSON = try #require(String(data: requestData, encoding: .utf8))
    let json = try #require(wire.step(owner: owner, requestJSON: requestJSON))
    return try JSONDecoder().decode(RackWireReply.self, from: Data(json.utf8))
}

private func waitForRackWire(
    _ wire: FocusRackWire, _ owner: String,
    predicate: (RackWireReply) -> Bool
) async throws -> RackWireReply {
    for _ in 0..<200 {
        let reply = try rackWireReply(wire, owner)
        if predicate(reply) { return reply }
        try await Task.sleep(for: .milliseconds(10))
    }
    Issue.record("Shared rack wire did not reach the expected state")
    return try rackWireReply(wire, owner)
}

@Test func rackProductionWireStoresOnlyValidatedTimingAndNeverStartsOnTemplateLoad() async throws {
    let camera = RackWireCamera()
    let wire = FocusRackWire()
    let owner = try #require(
        wire.create(
            driver: camera.driver,
            clock: .init(now: { 100 }, sleep: { _ in try await Task.sleep(for: .milliseconds(5)) }))
    )
    defer { wire.close(owner: owner) }
    let transition: [String: Any] = [
        "fromMark": "B", "toMark": "A", "duration": 24,
        "delay": 2, "easing": "linear",
    ]
    _ = try rackWireReply(wire, owner, kind: "timing", fields: ["transition": transition])
    _ = try rackWireReply(wire, owner, kind: "saveTemplate", fields: ["name": "  Slow  "])
    let saved = try await waitForRackWire(wire, owner) { $0.templates.count == 1 }
    #expect(saved.templates.first?.name == "Slow")
    #expect(saved.templates.first?.transition.duration == 24)
    #expect(saved.templates.first?.transition.delay == 2)
    let keys = Set(
        try #require(
            JSONSerialization.jsonObject(with: Data(saved.templatesJSON.utf8)) as? [[String: Any]]
        ).first?.keys.map { $0 } ?? [])
    #expect(keys == ["name", "transition"])
    #expect(!saved.templatesJSON.contains("stepPosition"))
    #expect(!saved.templatesJSON.contains("phase"))
    _ = try rackWireReply(
        wire, owner, kind: "loadTemplate",
        fields: ["template": ["name": "Slow", "transition": transition]])
    let loaded = try await waitForRackWire(wire, owner) { $0.state?.transition.duration == 24 }
    #expect(loaded.state?.program.marks.isEmpty == true)
    #expect(loaded.state?.busy == false)
    #expect(camera.log.isEmpty)
}

@Test func rackProductionWireRejectsMalformedAndRetiredOwnersWithoutMovement() async throws {
    let camera = RackWireCamera()
    let wire = FocusRackWire()
    let owner = try #require(
        wire.create(
            driver: camera.driver,
            clock: .init(now: { 100 }, sleep: { _ in try await Task.sleep(for: .milliseconds(5)) }))
    )
    #expect(wire.step(owner: owner, requestJSON: "not JSON") == nil)
    #expect(wire.step(owner: owner, requestJSON: String(repeating: " ", count: 16_385)) == nil)
    _ = try rackWireReply(wire, owner, kind: "start")
    _ = try await waitForRackWire(wire, owner) { $0.error != nil }
    wire.close(owner: owner)
    #expect(wire.step(owner: owner, requestJSON: "{\"kind\":\"start\"}") == nil)
    #expect(camera.log.isEmpty)
}

@Test(arguments: [false, true])
func rackProductionWireStopDiscardsQueuedMovementBeforeItCanRearm(recordingStop: Bool) async throws
{
    let camera = RackWireCamera()
    let wire = FocusRackWire()
    let owner = try #require(
        wire.create(
            driver: camera.driver,
            clock: .init(now: { 100 }, sleep: { _ in try await Task.sleep(for: .milliseconds(5)) }))
    )
    defer { wire.close(owner: owner) }
    var observation: [String: Any] = [
        "sessionID": "fake-owner", "connected": true, "foregroundOwner": true,
        "recording": recordingStop, "frameSequence": 1, "frameAgeSeconds": 0,
        "externalFocusRevision": 0, "externalFocusIdle": true,
        "focus": ["trackingAFActive": false, "subjectDetectionActive": false, "boxCount": 0],
    ]
    for sequence in 1...20 {
        observation["frameSequence"] = sequence
        _ = try rackWireReply(wire, owner, kind: "observe", fields: ["observation": observation])
        try await Task.sleep(for: .milliseconds(10))
    }
    let ready = try await waitForRackWire(wire, owner) { $0.state?.capabilities.canNudge == true }
    #expect(ready.state?.capabilities.canNudge == true)
    for _ in 0..<100 {
        _ = try rackWireReply(
            wire, owner, kind: "nudge", fields: ["towardNear": false, "steps": 4])
    }
    if recordingStop {
        observation["recording"] = false
        observation["frameSequence"] = 21
        _ = try rackWireReply(wire, owner, kind: "observe", fields: ["observation": observation])
    } else {
        _ = try rackWireReply(wire, owner, kind: "stop")
    }
    _ = try await waitForRackWire(wire, owner) { $0.state?.busy == false }
    try await Task.sleep(for: .milliseconds(100))
    let log = camera.log
    if let firstStop = log.firstIndex(of: "stop") {
        #expect(!log.dropFirst(firstStop + 1).contains("drive"))
    } else {
        // If actor work had not begun, Stop revoked every queued nudge before native preparation.
        #expect(!log.contains("drive"))
    }
}

@Test func rackWireQueuedFieldEditsPreserveFastestWithoutWaitingForSnapshots() async throws {
    let camera = RackWireCamera()
    let wire = FocusRackWire()
    let owner = try #require(wire.create(driver: camera.driver))
    defer { wire.close(owner: owner) }
    _ = try rackWireReply(
        wire, owner, kind: "updateTiming",
        fields: ["timingUpdate": ["durationMode": "fastest"]])
    _ = try rackWireReply(
        wire, owner, kind: "updateTiming",
        fields: ["timingUpdate": ["delay": 2, "direction": "bToA"]])
    let reply = try await waitForRackWire(wire, owner) {
        $0.state?.transition.delay == 2 && $0.state?.direction == .bToA
    }
    #expect(reply.state?.transition.durationMode == .fastest)
    #expect(reply.state?.transition.duration == 3)
    #expect(camera.log.isEmpty)
}

@Test func directRunWireRequiresOneTypedDirectionAndNeverRepositions() async throws {
    let camera = RackWireCamera()
    let wire = FocusRackWire()
    let owner = try #require(wire.create(driver: camera.driver))
    defer { wire.close(owner: owner) }
    _ = try rackWireReply(wire, owner, kind: "run", fields: ["direction": "bToA"])
    let reply = try await waitForRackWire(wire, owner) { $0.error != nil }
    #expect(reply.error != nil)
    #expect(camera.log.isEmpty)
    #expect(wire.step(owner: owner, requestJSON: #"{"kind":"run","direction":"bad"}"#) == nil)
}

@Test func rackWireDiagnosticsAreExplicitBoundedAndConsumedOnceWithoutCameraMovement() async throws
{
    let camera = RackWireCamera()
    let wire = FocusRackWire()
    let owner = try #require(wire.create(driver: camera.driver))
    defer { wire.close(owner: owner) }
    #expect(try rackWireReply(wire, owner).traceJSON == nil)
    _ = try rackWireReply(wire, owner, kind: "diagnostics")
    let reply = try await waitForRackWire(wire, owner) { $0.traceJSON != nil }
    let data = Data(try #require(reply.traceJSON).utf8)
    let trace = try JSONDecoder().decode(FocusRackDiagnostics.self, from: data)
    #expect(trace.events.isEmpty)
    #expect(try rackWireReply(wire, owner).traceJSON == nil)
    #expect(camera.log.isEmpty)
}
