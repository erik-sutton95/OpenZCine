import Foundation
import Testing

@testable import OpenZCineCore

private let calibrationKey = FocusRackCalibrationKey(
    cameraID: "synthetic-body", transport: "usb", lens: "synthetic lens", focalLength: "70",
    focusMode: "AF-S", focusArea: "Auto", focusSubject: "Off")

private let savedCalibration = FocusRackCalibration(
    key: calibrationKey,
    commandDurations: [16: 0.14, 32: 0.125, 48: 0.09, 64: 0.117, 96: 0.089, 128: 0.08])

private func calibrationContext(_ now: Double) -> FocusRackContext {
    .init(
        sessionID: "fresh-session", connected: true, movieMode: true, foregroundOwner: true,
        focusMode: "AF-S",
        focus: .init(
            trackingAFActive: false, subjectDetectionActive: false, boxCount: 0,
            selectedBoxIndex: nil),
        frameTimestamp: now, safetyTimestamp: now, focusSettled: true,
        lens: "synthetic lens", focalLength: "70", recording: false,
        frameSequence: Int64(now * 1_000_000), focusArea: "Auto", focusSubject: "Off")
}

private func recoveredEngine() throws -> FocusRackEngine {
    var engine = try FocusRackEngine(
        configuration: FocusRackEngine.productionConfiguration, adaptive: true,
        profile: .calibratedFineExperiment)
    engine.observe(calibrationContext(1), at: 1)
    return engine
}

@Test func rackCalibrationCodecRoundTripsAndRejectsIncompatibleEvidence() throws {
    let data = try FocusRackCalibrationCodec.encode(savedCalibration)
    #expect(try FocusRackCalibrationCodec.decode(data) == savedCalibration)
    var object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    for (field, value) in [("version", 2), ("pulsesPerStep", 32)] {
        var changed = object
        changed[field] = value
        #expect(throws: (any Error).self) {
            try FocusRackCalibrationCodec.decode(JSONSerialization.data(withJSONObject: changed))
        }
    }
    object["profile"] = "adaptive"
    #expect(throws: (any Error).self) {
        try FocusRackCalibrationCodec.decode(JSONSerialization.data(withJSONObject: object))
    }
    for durations in [[128: -0.1], [128: Double.infinity], [17: 0.1], [:]] {
        #expect(throws: (any Error).self) {
            try FocusRackCalibrationCodec.encode(
                .init(key: calibrationKey, commandDurations: durations))
        }
    }
}

@Test func rackCalibrationRecoveryIsIdempotentAndDoesNotRestoreExecutionState() throws {
    var engine = try recoveredEngine()
    let before = engine.snapshot(at: 1, includeEvents: true)
    engine.restoreCalibration(savedCalibration, at: 1)
    let first = engine.snapshot(at: 1, includeEvents: true)
    engine.restoreCalibration(savedCalibration, at: 1)
    let second = engine.snapshot(at: 1, includeEvents: true)
    #expect(second.timingEvidence == savedCalibration.commandDurations)
    #expect(second.events == first.events)
    #expect(second.runID == before.runID)
    #expect(second.marks == before.marks)
    #expect(second.stepPosition == before.stepPosition)
    #expect(!second.busy)
    #expect(engine.safetyReadBudget == 0)
    #expect(engine.state(at: 1).calibration == nil)
    #expect(engine.nextAction(at: 1).kind == "idle")
    #expect(second.events.allSatisfy { $0.kind == "timingRestored" })
    #expect(
        !String(decoding: try JSONEncoder().encode(second), as: UTF8.self).contains(
            "synthetic-body"))
}

@Test func rackCalibrationRecoveryRequiresFreshMatchingSettledEvidence() throws {
    for index in 0..<8 {
        var engine = try recoveredEngine()
        var context = calibrationContext(1)
        switch index {
        case 0: context.safetyTimestamp = -2
        case 1: context.frameTimestamp = -2
        case 2: context.lens = "another lens"
        case 3: context.focalLength = "50"
        case 4: context.focusArea = nil
        case 5: context.movieMode = false
        case 6: context.foregroundOwner = false
        default: context.focusSettled = false
        }
        engine.observe(context, at: 1)
        engine.restoreCalibration(savedCalibration, at: 1)
        #expect(engine.calibrationTimings.isEmpty)
    }
    var engine = try recoveredEngine()
    try engine.capture(markID: "A", at: 1)
    engine.requireReadinessFrame(at: 1)
    engine.restoreCalibration(savedCalibration, at: 1)
    #expect(engine.calibrationTimings.isEmpty)
    engine.observe(calibrationContext(1.01), at: 1.01)
    engine.restoreCalibration(savedCalibration, at: 1.01)
    #expect(engine.calibrationTimings == savedCalibration.commandDurations)
}

private func settleCalibrationTest(
    _ engine: inout FocusRackEngine, now: inout Double, cost: Double
) throws -> [Int] {
    var pulses: [Int] = []
    for _ in 0..<2_000 {
        engine.observe(calibrationContext(now), at: now)
        if !engine.snapshot(at: now).busy { return pulses }
        let action = engine.nextAction(at: now)
        if action.kind == "drive" {
            pulses.append(try #require(action.signedPulses))
            now += cost
            engine.complete(
                runID: action.runID, commandID: try #require(action.commandID), outcome: 0, at: now)
            now += 0.001
        } else if action.kind == "readSafety" {
            let started = now
            now += 0.1
            engine.recordSafetyRead(startedAt: started, finishedAt: now, accepted: true)
            engine.observe(calibrationContext(now), at: now)
            engine.finishScheduledRead(
                runID: action.runID, commandID: try #require(action.commandID), accepted: true,
                at: now)
        } else {
            now += max(0.001, action.waitSeconds ?? 0.01)
        }
    }
    throw FocusRackError.movementPending
}

@Test func rackRecoveredFinerPlansWorkWithNewMarkOriginAndRetainLargerCurrentCosts() throws {
    var engine = try recoveredEngine()
    var now = 1.0
    try engine.capture(markID: "B", at: now)
    for _ in 0..<10 {
        try engine.nudge(towardNear: true, steps: 10, at: now)
        _ = try settleCalibrationTest(&engine, now: &now, cost: 0.214)
    }
    engine.observe(calibrationContext(now), at: now)
    try engine.capture(markID: "A", at: now)
    let marks = engine.snapshot(at: now).marks
    #expect(marks.map(\.stepPosition) == [-100, 0])
    engine.restoreCalibration(savedCalibration, at: now)
    #expect(try #require(engine.calibrationTimings[16]) >= 0.214 - 1e-9)
    engine.recordSafetyRead(startedAt: now - 0.1, finishedAt: now, accepted: true)
    for duration in [1.1, 3, 5.5] {
        for direction in [FocusRackDirection.aToB, .bToA] {
            try engine.setTransition(.init(duration: duration), at: now)
            try engine.run(direction: direction, at: now)
            let sign = direction == .aToB ? 1 : -1
            let actual = try settleCalibrationTest(&engine, now: &now, cost: 0.02)
            #expect(actual.reduce(0, +) == sign * 1600)
            #expect(actual.allSatisfy { savedCalibration.commandDurations[abs($0)] != nil })
            if duration >= 3 { #expect(actual.filter { abs($0) < 128 }.count > actual.count / 2) }
            #expect(engine.snapshot(at: now).phase == "complete")
            #expect(engine.snapshot(at: now).marks == marks)
        }
    }
    #expect(engine.state(at: now).calibration?.detail == "32-pulse increments · 1/10")
    // Reset clears relative positions, but the same saved evidence can be merged again.
    try engine.reset(at: now)
    #expect(engine.calibrationTimings.isEmpty)
    engine.observe(calibrationContext(now + 0.01), at: now + 0.01)
    engine.restoreCalibration(savedCalibration, at: now + 0.01)
    #expect(engine.calibrationTimings == savedCalibration.commandDurations)
}

@Test func rackCalibrationCannotChangeAnActiveOrUncertainMove() throws {
    var engine = try recoveredEngine()
    try engine.nudge(towardNear: true, steps: 1, at: 1)
    engine.restoreCalibration(savedCalibration, at: 1)
    #expect(engine.calibrationTimings.isEmpty)
    let action = engine.nextAction(at: 1)
    engine.complete(runID: action.runID, commandID: 0, outcome: 4, at: 1.01)
    engine.observe(calibrationContext(1.02), at: 1.02)
    engine.restoreCalibration(savedCalibration, at: 1.02)
    #expect(engine.calibrationTimings.isEmpty)
    #expect(engine.snapshot(at: 1.02).stepPosition == nil)
}

@Test func rackOldScopeCompletionCannotPopulateTheNewTimingBank() throws {
    var engine = try recoveredEngine()
    engine.bindCalibrationKey(calibrationKey, at: 1)
    engine.restoreCalibration(savedCalibration, at: 1)
    try engine.nudge(towardNear: true, steps: 1, at: 1)
    let action = engine.nextAction(at: 1)
    #expect(action.kind == "drive")
    engine.detachCalibrationKey(at: 1.01)
    let newKey = FocusRackCalibrationKey(
        cameraID: "other-body", transport: "usb", lens: calibrationKey.lens,
        focalLength: calibrationKey.focalLength, focusMode: calibrationKey.focusMode,
        focusArea: calibrationKey.focusArea, focusSubject: calibrationKey.focusSubject)
    engine.bindCalibrationKey(newKey, at: 1.01)
    engine.complete(runID: action.runID, commandID: 0, outcome: 0, at: 1.02)
    #expect(engine.calibrationTimings.isEmpty)
    #expect(engine.snapshot(at: 1.02).stepPosition == nil)
    #expect(!engine.snapshot(at: 1.02).busy)
}
