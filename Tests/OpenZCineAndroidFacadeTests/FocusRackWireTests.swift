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
    let calibrationJSON: String?
    let focusModeSwitchPending: Bool
    let focusMode: FocusControlMode
    let canChangeFocusMode: Bool
    let nativeAFConfigured: Bool
    let canNativeAutofocus: Bool
    let afSettingsChange: FocusAFSettingChange?
    let afSettingsPending: Bool
    let afSettingsRestoring: Bool
    let afSettingsReady: Bool
    let afSettingsFailure: String?
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

@Test(arguments: ["stop", "recordingStop", "interrupt", "ownershipLoss"])
func rackProductionWireStopDiscardsQueuedMovementBeforeItCanRearm(kind: String) async throws {
    let recordingStop = kind == "recordingStop"
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
    } else if kind == "ownershipLoss" {
        observation["foregroundOwner"] = false
        observation["frameSequence"] = 21
        _ = try rackWireReply(wire, owner, kind: "observe", fields: ["observation": observation])
    } else {
        _ = try rackWireReply(wire, owner, kind: kind)
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

@Test func rackWireRestoresValidatedCalibrationAcrossOwnersWithoutMarksOrMovement() async throws {
    let camera = RackWireCamera()
    let wire = FocusRackWire()
    let calibration = FocusRackCalibration(
        key: .init(
            cameraID: "fixture-body", transport: "usb", lens: "35-100mm f/2.8",
            focalLength: "70", focusMode: "AF-S", focusArea: "Single-point AF", focusSubject: "Off"),
        commandDurations: [64: 0.12, 128: 0.08])
    let encoded = try #require(
        String(data: FocusRackCalibrationCodec.encode(calibration), encoding: .utf8))
    var checkpoint = encoded
    for _ in 0..<2 {
        let owner = try #require(wire.create(driver: camera.driver))
        _ = try rackWireReply(
            wire, owner, kind: "loadCalibration", fields: ["calibrationJSON": checkpoint])
        let reply = try await waitForRackWire(wire, owner) { $0.calibrationJSON != nil }
        checkpoint = try #require(reply.calibrationJSON)
        #expect(try FocusRackCalibrationCodec.decode(Data(checkpoint.utf8)) == calibration)
        #expect(reply.state?.program.marks.isEmpty == true)
        #expect(reply.state?.captures.isEmpty == true)
        #expect(reply.state?.busy == false)
        #expect(!checkpoint.contains("stepPosition"))
        #expect(!checkpoint.contains("sessionID"))
        #expect(camera.log.isEmpty)
        wire.close(owner: owner)
    }
}

@Test func rackWireRejectsInvalidCalibrationWithoutReplacingTheSavedCheckpoint() async throws {
    let camera = RackWireCamera()
    let wire = FocusRackWire()
    let owner = try #require(wire.create(driver: camera.driver))
    defer { wire.close(owner: owner) }
    let calibration = FocusRackCalibration(
        key: .init(
            cameraID: "fixture-body", transport: "usb", lens: "35-100mm f/2.8",
            focalLength: "70", focusMode: "AF-S", focusArea: "Single-point AF", focusSubject: "Off"),
        commandDurations: [128: 0.08])
    let encoded = try #require(
        String(data: FocusRackCalibrationCodec.encode(calibration), encoding: .utf8))
    _ = try rackWireReply(
        wire, owner, kind: "loadCalibration", fields: ["calibrationJSON": encoded])
    _ = try await waitForRackWire(wire, owner) { $0.calibrationJSON != nil }
    _ = try rackWireReply(
        wire, owner, kind: "loadCalibration", fields: ["calibrationJSON": "{\"version\":999}"])
    let reply = try await waitForRackWire(wire, owner) { $0.error != nil }
    let retained = try #require(reply.calibrationJSON)
    #expect(try FocusRackCalibrationCodec.decode(Data(retained.utf8)) == calibration)
    #expect(reply.state?.program.marks.isEmpty == true)
    #expect(camera.log.isEmpty)
}

@Test func rackWireNativeModeRevokesTimedIntentsAndAllowsRepeatedCameraAutofocus() async throws {
    let camera = RackWireCamera()
    let wire = FocusRackWire()
    let owner = try #require(wire.create(driver: camera.driver))
    defer { wire.close(owner: owner) }
    #expect(try rackWireReply(wire, owner).focusMode == .timedRack)
    _ = try rackWireReply(wire, owner, kind: "selectFocusMode", fields: ["focusMode": "nativeAF"])
    _ = try await waitForRackWire(wire, owner) { $0.focusMode == .nativeAF }
    var observation: [String: Any] = [
        "sessionID": "native-owner", "connected": true, "foregroundOwner": true,
        "recording": false, "frameSequence": 1, "frameAgeSeconds": 0,
        "externalFocusRevision": 0, "externalFocusIdle": true,
    ]
    for revision in 1...3 {
        observation["frameSequence"] = revision
        observation["externalFocusRevision"] = revision
        _ = try rackWireReply(
            wire, owner, kind: "externalFocus",
            fields: [
                "observation": observation, "movieFocusMode": "AF-F", "photography": false,
            ])
        let reply = try await waitForRackWire(wire, owner) {
            $0.nativeAFConfigured && !$0.focusModeSwitchPending
        }
        #expect(reply.canNativeAutofocus)
    }
    for kind in ["nudge", "run", "capture", "calibrate", "primary", "goTo", "updateTiming"] {
        _ = try rackWireReply(wire, owner, kind: kind)
        _ = try await waitForRackWire(wire, owner) { $0.error != nil }
    }
    #expect(!camera.log.contains("prepare"))
    #expect(!camera.log.contains("drive"))
    _ = try rackWireReply(
        wire, owner, kind: "observe",
        fields: [
            "observation": observation, "movieFocusMode": "AF-S", "photography": false,
        ])
    let unconfigured = try rackWireReply(wire, owner)
    #expect(!unconfigured.nativeAFConfigured)
    #expect(!unconfigured.canNativeAutofocus)
    observation["externalFocusIdle"] = false
    _ = try rackWireReply(wire, owner, kind: "observe", fields: ["observation": observation])
    #expect(try !rackWireReply(wire, owner).canChangeFocusMode)
    _ = try rackWireReply(wire, owner, kind: "selectFocusMode", fields: ["focusMode": "timedRack"])
    try await Task.sleep(for: .milliseconds(30))
    #expect(try rackWireReply(wire, owner).focusMode == .nativeAF)
    observation["externalFocusIdle"] = true
    _ = try rackWireReply(wire, owner, kind: "observe", fields: ["observation": observation])
    _ = try rackWireReply(wire, owner, kind: "selectFocusMode", fields: ["focusMode": "timedRack"])
    _ = try await waitForRackWire(wire, owner) { $0.focusMode == .timedRack }
    #expect(!camera.log.contains("drive"))
}

private final class HeldModeDrive: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<NikonFocusRackDriveOutcome, Never>?
    var hasStarted: Bool { lock.withLock { continuation != nil } }
    func drive() async -> NikonFocusRackDriveOutcome {
        await withCheckedContinuation { continuation in
            lock.withLock { self.continuation = continuation }
        }
    }
    func release() {
        let held = lock.withLock {
            let held = continuation
            continuation = nil
            return held
        }
        held?.resume(returning: .complete)
    }
}

@Test(arguments: ["stop", "interrupt"])
func rackWireModeReservationSurvivesImmediateControlCancellation(kind: String) async throws {
    let camera = RackWireCamera()
    let wire = FocusRackWire()
    let owner = try #require(wire.create(driver: camera.driver))
    defer { wire.close(owner: owner) }
    let observation: [String: Any] = [
        "sessionID": "mode-cancellation", "connected": true, "foregroundOwner": true,
        "recording": false, "frameSequence": 1, "frameAgeSeconds": 0,
        "externalFocusRevision": 0, "externalFocusIdle": true,
        "focus": ["trackingAFActive": false, "subjectDetectionActive": false, "boxCount": 0],
    ]
    _ = try rackWireReply(
        wire, owner, kind: "observe",
        fields: ["observation": observation, "movieFocusMode": "AF-F", "photography": false])
    _ = try await waitForRackWire(wire, owner) { $0.state != nil && $0.canChangeFocusMode }
    _ = try rackWireReply(wire, owner, kind: "selectFocusMode", fields: ["focusMode": "nativeAF"])
    _ = try rackWireReply(wire, owner, kind: kind)
    let settled = try await waitForRackWire(wire, owner) {
        $0.focusMode == .nativeAF && !$0.focusModeSwitchPending
    }
    #expect(settled.canNativeAutofocus)
    #expect(!camera.log.contains("prepare"))
    #expect(!camera.log.contains("drive"))
}

@Test func rackWireCannotEnableNativeAutofocusBeforeAHeldManualDriveAcknowledgesCompletion()
    async throws
{
    let camera = RackWireCamera()
    let held = HeldModeDrive()
    let base = camera.driver
    let driver = NikonFocusRackAccess(
        isCurrent: base.isCurrent, prepareRun: base.prepareRun, requestStop: base.requestStop,
        driveChunk: { _, _, _ in await held.drive() }, refreshSafety: base.refreshSafety)
    let wire = FocusRackWire()
    let owner = try #require(
        wire.create(
            driver: driver,
            clock: .init(now: { 100 }, sleep: { _ in try await Task.sleep(for: .milliseconds(5)) }))
    )
    defer {
        held.release()
        wire.close(owner: owner)
    }
    var observation: [String: Any] = [
        "sessionID": "held-owner", "connected": true, "foregroundOwner": true,
        "recording": false, "frameSequence": 1, "frameAgeSeconds": 0,
        "externalFocusRevision": 0, "externalFocusIdle": true,
        "focus": ["trackingAFActive": false, "subjectDetectionActive": false, "boxCount": 0],
    ]
    for sequence in 1...20 {
        observation["frameSequence"] = sequence
        _ = try rackWireReply(
            wire, owner, kind: "observe",
            fields: [
                "observation": observation, "movieFocusMode": "AF-F", "photography": false,
            ])
        try await Task.sleep(for: .milliseconds(5))
    }
    _ = try await waitForRackWire(wire, owner) { $0.state?.capabilities.canNudge == true }
    let selected = try rackWireReply(
        wire, owner, kind: "selectFocusMode", fields: ["focusMode": "nativeAF"])
    _ = try rackWireReply(
        wire, owner, kind: "observe",
        fields: [
            "observation": observation, "movieFocusMode": "AF-F", "photography": false,
        ])
    #expect(selected.focusMode != .timedRack || selected.state?.capabilities.canAutofocus != true)
    if selected.focusModeSwitchPending {
        #expect(!selected.canNativeAutofocus)
        #expect(!selected.canChangeFocusMode)
    }
    _ = try await waitForRackWire(wire, owner) {
        $0.focusMode == .nativeAF && !$0.focusModeSwitchPending
    }
    _ = try rackWireReply(wire, owner, kind: "selectFocusMode", fields: ["focusMode": "timedRack"])
    _ = try await waitForRackWire(wire, owner) {
        $0.focusMode == .timedRack && !$0.focusModeSwitchPending
    }
    for sequence in 21...30 {
        observation["frameSequence"] = sequence
        _ = try rackWireReply(
            wire, owner, kind: "observe",
            fields: ["observation": observation, "movieFocusMode": "AF-F", "photography": false])
        try await Task.sleep(for: .milliseconds(5))
    }
    _ = try await waitForRackWire(wire, owner) { $0.state?.capabilities.canNudge == true }
    _ = try rackWireReply(wire, owner, kind: "nudge", fields: ["steps": 1])
    for _ in 0..<200 where !held.hasStarted { try await Task.sleep(for: .milliseconds(5)) }
    try #require(held.hasStarted)
    _ = try rackWireReply(wire, owner, kind: "selectFocusMode", fields: ["focusMode": "nativeAF"])
    let refused = try await waitForRackWire(wire, owner) { $0.error != nil }
    #expect(refused.focusMode == .timedRack)
    #expect(!refused.canNativeAutofocus)
    #expect(!refused.canChangeFocusMode)
    held.release()
    _ = try await waitForRackWire(wire, owner) { $0.state?.busy == false }
    _ = try rackWireReply(wire, owner, kind: "selectFocusMode", fields: ["focusMode": "nativeAF"])
    _ = try await waitForRackWire(wire, owner) {
        $0.focusMode == .nativeAF && $0.canNativeAutofocus
    }
}

private final class AFSettingsWireCamera: @unchecked Sendable {
    private let lock = NSLock()
    private var current = FocusAFSettingsValues(mode: "AF-C", area: "Wide-L", subject: "People")
    private var driveCount = 0
    private var safetyFails = false
    var failSafety: Bool {
        get { lock.withLock { safetyFails } }
        set { lock.withLock { safetyFails = newValue } }
    }
    init(values: FocusAFSettingsValues = .init(mode: "AF-C", area: "Wide-L", subject: "People")) {
        current = values
    }
    var values: FocusAFSettingsValues { lock.withLock { current } }
    var drives: Int { lock.withLock { driveCount } }
    func manualArea(_ value: String) { lock.withLock { current.area = value } }
    func apply(_ change: FocusAFSettingChange) {
        lock.withLock {
            switch change.property {
            case .mode: current.mode = change.value
            case .area: current.area = change.value
            case .subject: current.subject = change.value
            }
        }
    }
    var driver: NikonFocusRackAccess {
        .init(
            isCurrent: { true }, prepareRun: { _ in true }, requestStop: { _ in },
            driveChunk: { [self] _, _, _ in
                lock.withLock { driveCount += 1 }
                return .complete
            },
            refreshSafety: { [self] in
                if failSafety { throw NikonFocusRackAccessError.safetyUnavailable }
                let values = values
                return try .init(
                    reported: .init(
                        focalLength: "70", focalMinX100: 3500,
                        focalMaxX100: 10000, apertureMinX100: 280, focusMode: values.mode,
                        focusArea: values.area, focusSubject: values.subject,
                        captureSelector: .video))
            })
    }
}

private func afWireFields(
    _ camera: AFSettingsWireCamera, recording: Bool? = false,
    foreground: Bool = true, focusIdle: Bool = true,
    session: String = "af-settings-owner"
) -> [String: Any] {
    let values = camera.values
    return [
        "afSettings": [
            "sessionID": session,
            "values": [
                "mode": values.mode as Any, "area": values.area as Any,
                "subject": values.subject as Any,
            ],
            "recording": recording as Any? ?? NSNull(), "recordingPending": false,
            "movie": true, "foreground": foreground, "focusIdle": focusIdle, "commandsIdle": true,
        ]
    ]
}

private func completeAFWireChange(
    _ change: FocusAFSettingChange, camera: AFSettingsWireCamera,
    wire: FocusRackWire, owner: String
) throws {
    camera.apply(change)
    var fields = afWireFields(camera)
    fields["afChange"] = try JSONSerialization.jsonObject(with: JSONEncoder().encode(change))
    _ = try rackWireReply(wire, owner, kind: "afSettingsComplete", fields: fields)
}

@Test func rackWireAutomaticSettingsRestoreOriginalsAcrossBothModesWithoutDrivingFocus()
    async throws
{
    let camera = AFSettingsWireCamera()
    let original = camera.values
    let wire = FocusRackWire()
    let owner = try #require(wire.create(driver: camera.driver))
    defer { wire.close(owner: owner) }
    _ = try rackWireReply(
        wire, owner, kind: "openPanel", fields: afWireFields(camera, recording: true))
    let parked = try await waitForRackWire(wire, owner) { $0.afSettingsPending }
    #expect(parked.afSettingsChange == nil)
    #expect(parked.state?.capabilities.canNudge != true)
    _ = try rackWireReply(wire, owner, kind: "observe", fields: afWireFields(camera))
    for expected in [FocusAFProperty.mode, .subject, .area] {
        let reply = try await waitForRackWire(wire, owner) { $0.afSettingsChange != nil }
        let change = try #require(reply.afSettingsChange)
        #expect(change.property == expected)
        try completeAFWireChange(change, camera: camera, wire: wire, owner: owner)
        _ = try await waitForRackWire(wire, owner) { $0.afSettingsChange?.id != change.id }
    }
    _ = try await waitForRackWire(wire, owner) { $0.afSettingsReady }
    #expect(camera.values == .target(.timedRack))
    var fields = afWireFields(camera)
    fields["focusMode"] = "nativeAF"
    _ = try rackWireReply(wire, owner, kind: "selectFocusMode", fields: fields)
    let native = try await waitForRackWire(wire, owner) { $0.afSettingsChange != nil }
    let change = try #require(native.afSettingsChange)
    #expect(change.property == .mode && change.value == "AF-F")
    try completeAFWireChange(change, camera: camera, wire: wire, owner: owner)
    _ = try await waitForRackWire(wire, owner) { $0.afSettingsReady && !$0.afSettingsPending }
    _ = try rackWireReply(
        wire, owner, kind: "closePanel", fields: afWireFields(camera, recording: true))
    let deferred = try await waitForRackWire(wire, owner) { $0.afSettingsRestoring }
    #expect(deferred.afSettingsChange == nil)
    _ = try rackWireReply(
        wire, owner, kind: "observe", fields: afWireFields(camera, focusIdle: false))
    try await Task.sleep(for: .milliseconds(20))
    #expect(try rackWireReply(wire, owner).afSettingsChange == nil)
    _ = try rackWireReply(wire, owner, kind: "observe", fields: afWireFields(camera))
    for _ in 0..<3 {
        let reply = try await waitForRackWire(wire, owner) { $0.afSettingsChange != nil }
        let change = try #require(reply.afSettingsChange)
        #expect(change.restoring)
        try completeAFWireChange(change, camera: camera, wire: wire, owner: owner)
        _ = try await waitForRackWire(wire, owner) { $0.afSettingsChange?.id != change.id }
    }
    _ = try await waitForRackWire(wire, owner) { !$0.afSettingsPending }
    #expect(camera.values == original)
    #expect(camera.drives == 0)
}

@Test(arguments: ["manualAFSetting", "closePanel"])
func rackWireManualOrCloseIntentSynchronouslyRevokesAReservedSettingAndOldSessionAdmission(
    kind: String
) async throws {
    let camera = AFSettingsWireCamera()
    let wire = FocusRackWire()
    let owner = try #require(wire.create(driver: camera.driver))
    defer { wire.close(owner: owner) }
    _ = try rackWireReply(wire, owner, kind: "openPanel", fields: afWireFields(camera))
    let reply = try await waitForRackWire(wire, owner) { $0.afSettingsChange != nil }
    let change = try #require(reply.afSettingsChange)
    let changeJSON = try JSONSerialization.jsonObject(with: JSONEncoder().encode(change))
    var fields = afWireFields(camera)
    fields["afChange"] = changeJSON
    fields["kind"] = "afSettingsAdmission"
    let request = try #require(
        String(data: JSONSerialization.data(withJSONObject: fields), encoding: .utf8))
    #expect(wire.step(owner: owner, requestJSON: request) == "{\"allowed\":true}")
    _ = try rackWireReply(wire, owner, kind: kind, fields: ["afProperty": "mode"])
    #expect(wire.step(owner: owner, requestJSON: request) == "{\"allowed\":false}")
    fields = afWireFields(camera, session: "replacement-owner")
    _ = try rackWireReply(wire, owner, kind: "observe", fields: fields)
    #expect(wire.step(owner: owner, requestJSON: request) == "{\"allowed\":false}")
    #expect(camera.drives == 0)
}

@Test func rackWireReadinessFailureIsVisibleAndNeverAutomaticallyRetries() async throws {
    let camera = AFSettingsWireCamera()
    let base = camera.driver
    let driver = NikonFocusRackAccess(
        isCurrent: base.isCurrent, prepareRun: base.prepareRun,
        requestStop: base.requestStop, driveChunk: base.driveChunk,
        refreshSafety: { throw NikonFocusRackAccessError.safetyUnavailable })
    let wire = FocusRackWire()
    let owner = try #require(wire.create(driver: driver))
    defer { wire.close(owner: owner) }
    _ = try rackWireReply(wire, owner, kind: "openPanel", fields: afWireFields(camera))
    let failed = try await waitForRackWire(wire, owner) { $0.afSettingsFailure != nil }
    #expect(failed.afSettingsChange == nil)
    #expect(!failed.afSettingsPending)
    #expect(!failed.afSettingsReady)
    #expect(camera.drives == 0)
}

@Test func rackWireMatchingSetupPreservesMarksAndActualAFWriteInvalidatesRelativeReference()
    async throws
{
    let camera = AFSettingsWireCamera(values: .target(.timedRack))
    let wire = FocusRackWire()
    let owner = try #require(wire.create(driver: camera.driver))
    defer { wire.close(owner: owner) }
    var fields = afWireFields(camera)
    for sequence in 1...20 {
        fields["observation"] = [
            "sessionID": "af-settings-owner", "connected": true,
            "foregroundOwner": true, "recording": false, "frameSequence": sequence,
            "frameAgeSeconds": 0, "externalFocusRevision": 0, "externalFocusIdle": true,
            "focus": ["trackingAFActive": false, "subjectDetectionActive": false, "boxCount": 0],
        ]
        _ = try rackWireReply(wire, owner, kind: "observe", fields: fields)
        try await Task.sleep(for: .milliseconds(5))
    }
    _ = try await waitForRackWire(wire, owner) { $0.state?.capabilities.canCaptureA == true }
    fields["markID"] = "A"
    fields["expectedFrameSequence"] = 20
    _ = try rackWireReply(wire, owner, kind: "capture", fields: fields)
    let captured = try await waitForRackWire(wire, owner) { $0.state?.program.marks.count == 1 }
    let position = captured.state?.stepPosition
    _ = try rackWireReply(wire, owner, kind: "openPanel", fields: fields)
    let noOp = try await waitForRackWire(wire, owner) { $0.afSettingsReady }
    #expect(noOp.afSettingsChange == nil)
    #expect(noOp.state?.stepPosition == position)
    #expect(noOp.state?.program.marks == captured.state?.program.marks)
    fields["focusMode"] = "nativeAF"
    _ = try rackWireReply(wire, owner, kind: "selectFocusMode", fields: fields)
    let write = try await waitForRackWire(wire, owner) { $0.afSettingsChange != nil }
    #expect(write.afSettingsChange?.value == "AF-F")
    #expect(write.state?.stepPosition == nil)
    #expect(camera.drives == 0)
}

@Test func rackWireCrossPropertyReadbackChangeRevokesPreparedSettingAdmissionImmediately()
    async throws
{
    let camera = AFSettingsWireCamera()
    let wire = FocusRackWire()
    let owner = try #require(wire.create(driver: camera.driver))
    defer { wire.close(owner: owner) }
    _ = try rackWireReply(wire, owner, kind: "openPanel", fields: afWireFields(camera))
    let prepared = try await waitForRackWire(wire, owner) { $0.afSettingsChange != nil }
    let change = try #require(prepared.afSettingsChange)
    #expect(change.property == .mode)
    var fields = afWireFields(camera)
    var input = try #require(fields["afSettings"] as? [String: Any])
    var values = try #require(input["values"] as? [String: Any])
    values["area"] = "Single"
    input["values"] = values
    fields["afSettings"] = input
    fields["afChange"] = try JSONSerialization.jsonObject(with: JSONEncoder().encode(change))
    fields["kind"] = "afSettingsAdmission"
    let request = try #require(
        String(data: JSONSerialization.data(withJSONObject: fields), encoding: .utf8))
    #expect(wire.step(owner: owner, requestJSON: request) == "{\"allowed\":false}")
    #expect(camera.drives == 0)
}

@Test func rackWireSameModeSelectionRetriesAnExplicitlyFailedSetup() async throws {
    let camera = AFSettingsWireCamera()
    camera.failSafety = true
    let wire = FocusRackWire()
    let owner = try #require(wire.create(driver: camera.driver))
    defer { wire.close(owner: owner) }
    _ = try rackWireReply(wire, owner, kind: "openPanel", fields: afWireFields(camera))
    _ = try await waitForRackWire(wire, owner) { $0.afSettingsFailure != nil }
    camera.failSafety = false
    var fields = afWireFields(camera)
    fields["focusMode"] = "timedRack"
    _ = try rackWireReply(wire, owner, kind: "selectFocusMode", fields: fields)
    let retried = try await waitForRackWire(wire, owner) { $0.afSettingsChange != nil }
    #expect(retried.afSettingsFailure == nil)
    #expect(retried.focusMode == .timedRack)
    #expect(retried.afSettingsChange?.value == "AF-S")
    #expect(camera.drives == 0)
}

@Test func rackWireExplicitSameModeReownsAManualAreaUsingItsLatestBaseline() async throws {
    let camera = AFSettingsWireCamera(values: .target(.timedRack))
    let wire = FocusRackWire()
    let owner = try #require(wire.create(driver: camera.driver))
    defer { wire.close(owner: owner) }
    _ = try rackWireReply(wire, owner, kind: "openPanel", fields: afWireFields(camera))
    _ = try await waitForRackWire(wire, owner) { $0.afSettingsReady }
    _ = try rackWireReply(wire, owner, kind: "manualAFSetting", fields: ["afProperty": "area"])
    camera.manualArea("Wide-S")
    var fields = afWireFields(camera)
    fields["focusMode"] = "timedRack"
    _ = try rackWireReply(wire, owner, kind: "selectFocusMode", fields: fields)
    let reconfigured = try await waitForRackWire(wire, owner) { $0.afSettingsChange != nil }
    let setup = try #require(reconfigured.afSettingsChange)
    #expect(setup.property == .area && setup.value == "Auto")
    try completeAFWireChange(setup, camera: camera, wire: wire, owner: owner)
    _ = try await waitForRackWire(wire, owner) { $0.afSettingsReady && !$0.afSettingsPending }
    _ = try rackWireReply(wire, owner, kind: "closePanel", fields: afWireFields(camera))
    let closing = try await waitForRackWire(wire, owner) { $0.afSettingsChange != nil }
    let restore = try #require(closing.afSettingsChange)
    #expect(restore.restoring && restore.property == .area && restore.value == "Wide-S")
    try completeAFWireChange(restore, camera: camera, wire: wire, owner: owner)
    _ = try await waitForRackWire(wire, owner) { !$0.afSettingsPending }
    #expect(camera.values.area == "Wide-S")
    #expect(camera.drives == 0)
}

@Test func rackWireInterruptionRevokesSettingsUntilAnExplicitResumeDespiteStaleObservations()
    async throws
{
    let camera = AFSettingsWireCamera()
    let wire = FocusRackWire()
    let owner = try #require(wire.create(driver: camera.driver))
    defer { wire.close(owner: owner) }
    _ = try rackWireReply(wire, owner, kind: "openPanel", fields: afWireFields(camera))
    let prepared = try await waitForRackWire(wire, owner) { $0.afSettingsChange != nil }
    let change = try #require(prepared.afSettingsChange)
    let changeJSON = try JSONSerialization.jsonObject(with: JSONEncoder().encode(change))
    _ = try rackWireReply(wire, owner, kind: "interrupt")
    var admission = afWireFields(camera)
    admission["kind"] = "afSettingsAdmission"
    admission["afChange"] = changeJSON
    let request = try #require(
        String(data: JSONSerialization.data(withJSONObject: admission), encoding: .utf8))
    #expect(wire.step(owner: owner, requestJSON: request) == "{\"allowed\":false}")
    var fields = afWireFields(camera)
    fields["afChange"] = changeJSON
    _ = try rackWireReply(wire, owner, kind: "afSettingsDeferred", fields: fields)
    _ = try rackWireReply(wire, owner, kind: "observe", fields: afWireFields(camera))
    try await Task.sleep(for: .milliseconds(20))
    #expect(try rackWireReply(wire, owner).afSettingsChange == nil)
    _ = try rackWireReply(wire, owner, kind: "resumeAFSettings", fields: afWireFields(camera))
    let resumed = try await waitForRackWire(wire, owner) { $0.afSettingsChange != nil }
    #expect(resumed.afSettingsChange?.id != change.id)
    #expect(camera.drives == 0)
}

@Test(arguments: [false, true])
func rackWireRestorationWaitsForANewFocusedFrameAfterSettingOrTapCompletion(tapped: Bool)
    async throws
{
    let camera = AFSettingsWireCamera(values: .target(.timedRack))
    let wire = FocusRackWire()
    let owner = try #require(wire.create(driver: camera.driver))
    defer { wire.close(owner: owner) }
    var fields = afWireFields(camera)
    fields["focusMode"] = "nativeAF"
    _ = try rackWireReply(wire, owner, kind: "selectFocusMode", fields: fields)
    let setupReply = try await waitForRackWire(wire, owner) { $0.afSettingsChange != nil }
    let setup = try #require(setupReply.afSettingsChange)
    camera.apply(setup)
    fields = afWireFields(camera)
    var input = try #require(fields["afSettings"] as? [String: Any])
    input["frameSequence"] = 100
    input["focusAfterSequence"] = 100
    fields["afSettings"] = input
    fields["afChange"] = try JSONSerialization.jsonObject(with: JSONEncoder().encode(setup))
    _ = try rackWireReply(wire, owner, kind: "afSettingsComplete", fields: fields)
    _ = try await waitForRackWire(wire, owner) { !$0.afSettingsPending }
    let lastActionSequence = tapped ? 101 : 100
    if tapped {
        input["frameSequence"] = 101
        fields["afSettings"] = input
        _ = try rackWireReply(wire, owner, kind: "observe", fields: fields)
        input["focusAfterSequence"] = 101
        fields["afSettings"] = input
        _ = try rackWireReply(wire, owner, kind: "externalFocus", fields: fields)
    }
    _ = try rackWireReply(wire, owner, kind: "closePanel", fields: fields)
    let parked = try await waitForRackWire(wire, owner) { $0.afSettingsRestoring }
    #expect(parked.afSettingsChange == nil)
    try await Task.sleep(for: .milliseconds(20))
    #expect(try rackWireReply(wire, owner).afSettingsChange == nil)
    input["frameSequence"] = lastActionSequence + 1
    fields["afSettings"] = input
    _ = try rackWireReply(wire, owner, kind: "observe", fields: fields)
    let ready = try await waitForRackWire(wire, owner) { $0.afSettingsChange != nil }
    #expect(ready.afSettingsChange?.restoring == true)
    #expect(ready.afSettingsChange?.value == "AF-S")
    #expect(camera.drives == 0)
}
