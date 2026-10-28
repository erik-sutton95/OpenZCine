import Foundation
import Testing

@testable import OpenZCineCore

private func preparationContext(_ now: Double, recording: Bool = false) -> FocusRackContext {
    .init(
        sessionID: "preparation-session", connected: true, movieMode: true,
        foregroundOwner: true, focusMode: "AF-S",
        focus: .init(
            trackingAFActive: false, subjectDetectionActive: false, boxCount: 0,
            selectedBoxIndex: nil),
        frameTimestamp: now, safetyTimestamp: now, focusSettled: true,
        lens: "synthetic interchangeable lens", focalLength: "35 mm", recording: recording,
        frameSequence: Int64(now * 1_000_000), focusArea: "Auto", focusSubject: "Off")
}

private func preparationEngine(_ span: Int, fromA: Bool = false) throws -> (FocusRackEngine, Double)
{
    var engine = try FocusRackEngine(
        configuration: FocusRackEngine.productionConfiguration, adaptive: true,
        profile: .calibratedFineExperiment)
    var now = 1.0
    engine.observe(preparationContext(now), at: now)
    try engine.capture(markID: "A", at: now)
    var remaining = abs(span)
    while remaining > 0 {
        let units = min(remaining, 100)
        try engine.nudge(towardNear: span < 0, steps: units, at: now)
        _ = try finishPreparation(&engine, now: &now)
        remaining -= units
    }
    try engine.capture(markID: "B", at: now)
    if fromA {
        try engine.seek(markID: "A", at: now)
        _ = try finishPreparation(&engine, now: &now)
    }
    return (engine, now)
}

private func finishPreparation(_ engine: inout FocusRackEngine, now: inout Double) throws -> [Int] {
    var pulses: [Int] = []
    for _ in 0..<2_000 {
        engine.observe(preparationContext(now), at: now)
        guard engine.snapshot(at: now).busy else { return pulses }
        let action = engine.nextAction(at: now)
        switch action.kind {
        case "drive":
            pulses.append(try #require(action.signedPulses))
            #expect(engine.nextAction(at: now).kind == "idle")
            now += 0.0858
            engine.complete(
                runID: action.runID, commandID: try #require(action.commandID), outcome: 0, at: now)
            now += 0.001
        case "readSafety":
            let started = now
            now += 0.1
            engine.recordSafetyRead(startedAt: started, finishedAt: now, accepted: true)
            engine.observe(preparationContext(now), at: now)
            engine.finishScheduledRead(
                runID: action.runID, commandID: try #require(action.commandID), accepted: true,
                at: now)
        default: now += action.waitSeconds ?? 0.001
        }
    }
    throw FocusRackError.movementPending
}

@Test(arguments: [-151, -150, -47, -8, -7, -1, 1, 7, 8, 47, 150, 151], [false, true])
func rackPreparationMeasuresBoundedSizesInOneExplicitPass(span: Int, fromA: Bool) throws {
    var (engine, now) = try preparationEngine(span, fromA: fromA)
    let marks = engine.currentProgram.marks
    let transition = engine.currentProgram.transitions
    #expect(engine.state(at: now).calibration?.title == "Prepare lens")
    #expect(engine.state(at: now).calibration?.enabled == true)
    try engine.calibrate(at: now)
    #expect(engine.state(at: now).calibration?.enabled == false)
    #expect(engine.state(at: now).timingWarning == nil)
    let commands = try finishPreparation(&engine, now: &now)
    let requested = fromA ? span : -span
    #expect(commands.reduce(0, +) == requested * 16)
    #expect(commands.allSatisfy { abs($0) <= 192 && $0.signum() == requested.signum() })
    var position = fromA ? 0 : span
    for command in commands {
        position += command / 16
        #expect((min(0, span)...max(0, span)).contains(position))
        #expect(engine.calibrationTimings[abs(command)] != nil)
    }
    if abs(span) >= 46 {
        #expect(Set(commands.map(abs)).isSuperset(of: [16, 32, 48, 64, 96, 128, 160, 192]))
    }
    #expect(engine.state(at: now).phase == .complete)
    #expect(engine.state(at: now).stepPosition == (fromA ? span : 0))
    #expect(engine.currentProgram.marks == marks)
    #expect(engine.currentProgram.transitions == transition)
    #expect(engine.state(at: now).calibration?.enabled == true)
}

@Test func rackPreparationRequiresRecordingStoppedAndStopsWhenRecordingStarts() throws {
    var (engine, now) = try preparationEngine(150)
    engine.observe(preparationContext(now, recording: true), at: now)
    #expect(engine.state(at: now).calibration?.enabled == false)
    #expect(throws: FocusRackError.self) { try engine.calibrate(at: now) }
    #expect(!engine.snapshot(at: now).busy)
    engine.observe(preparationContext(now), at: now)
    try engine.calibrate(at: now)
    let first = engine.nextAction(at: now)
    engine.observe(preparationContext(now, recording: true), at: now)
    #expect(engine.state(at: now).phase == .stopping)
    now += 0.0858
    engine.complete(runID: first.runID, commandID: 0, outcome: 0, at: now)
    #expect(engine.state(at: now).phase == .stopped)
    #expect(engine.state(at: now).stepPosition == 149)
    #expect(engine.nextAction(at: now).kind == "idle")
}

@Test(arguments: [2, 3, 4, 5, 6, 0x12019])
func rackPreparationFailureNeverContinuesOrCreditsUnfinishedCommands(outcome: Int) throws {
    var (engine, now) = try preparationEngine(150)
    let before = engine.calibrationTimings
    try engine.calibrate(at: now)
    let action = engine.nextAction(at: now)
    now += 0.05
    engine.complete(runID: action.runID, commandID: 0, outcome: outcome, at: now)
    #expect(!engine.snapshot(at: now).busy)
    #expect(engine.nextAction(at: now).kind == "idle")
    #expect(engine.calibrationTimings == before)
    #expect(engine.state(at: now).phase != .complete)
}

@Test func rackPreparationStopKeepsOnlyAcknowledgedMovementAndRequiresAnEndpointToRestart() throws {
    var (engine, now) = try preparationEngine(150)
    try engine.calibrate(at: now)
    let action = engine.nextAction(at: now)
    engine.requestStop(at: now)
    now += 0.0858
    engine.complete(runID: action.runID, commandID: 0, outcome: 0, at: now)
    engine.observe(preparationContext(now), at: now)
    #expect(engine.state(at: now).stepPosition == 149)
    #expect(engine.state(at: now).calibration?.enabled == false)
    #expect(throws: FocusRackError.notAtStart) { try engine.calibrate(at: now) }
    #expect(engine.nextAction(at: now).kind == "idle")
}

@Test func rackPreparationContextChangeRejectsOldEvidenceAndRemainingCommands() throws {
    var (engine, now) = try preparationEngine(150)
    try engine.calibrate(at: now)
    let action = engine.nextAction(at: now)
    var changed = preparationContext(now)
    changed.lens = "different lens"
    engine.observe(changed, at: now)
    now += 0.0858
    engine.complete(runID: action.runID, commandID: 0, outcome: 0, at: now)
    #expect(engine.calibrationTimings.isEmpty)
    #expect(!engine.snapshot(at: now).busy)
    #expect(engine.nextAction(at: now).kind == "idle")
    #expect(engine.state(at: now).phase != .complete)
}

@Test func rackPreparationRecordingGuardDoesNotLeakIntoLaterTimedPlayback() throws {
    var (engine, now) = try preparationEngine(150)
    try engine.calibrate(at: now)
    _ = try finishPreparation(&engine, now: &now)
    try engine.run(direction: .aToB, at: now)
    engine.observe(preparationContext(now, recording: true), at: now)
    #expect(engine.snapshot(at: now).busy)
    #expect(engine.state(at: now).phase != .stopped)
    #expect(engine.state(at: now).phase != .stopping)
}

@Test func rackPreparationPlanIsBoundedAtTheExistingMaximumAndRejectsInvalidSpans() throws {
    for span in [-10_000, 10_000] {
        let plan = try FocusRackPreparation.make(signedSteps: span)
        #expect(plan.chunks.reduce(0, +) == span)
        #expect(plan.chunks.count <= 10_000)
        #expect(plan.chunks.allSatisfy { (1...12).contains(abs($0)) })
    }
    for span in [Int.min, -10_001, 0, 10_001] {
        #expect(throws: FocusRackError.invalidConfiguration) {
            try FocusRackPreparation.make(signedSteps: span)
        }
    }
}

@Test func rackTimingDetailShowsAnEstimateBelowTheRequestedTarget() {
    var state = FocusRackState.initial
    state.transition = .init(duration: 3)
    state.estimatedDuration = 0.0858
    #expect(state.playbackDetail == "3 s target · ~0.09 s")
}

@Test func rackPreparedLensUsesTheSamePlannerForOneThreeAndSixSecondTargets() throws {
    var (engine, now) = try preparationEngine(150)
    try engine.calibrate(at: now)
    _ = try finishPreparation(&engine, now: &now)
    let marks = engine.currentProgram.marks
    for duration in [1.0, 3.0, 6.0] {
        try engine.setTransition(.init(duration: duration), at: now)
        for direction in [FocusRackDirection.aToB, .bToA] {
            #expect(engine.state(at: now).admissionMessage == nil)
            try engine.run(direction: direction, at: now)
            let commands = try finishPreparation(&engine, now: &now)
            let sign = direction == .aToB ? 1 : -1
            #expect(commands.reduce(0, +) == sign * 2_400)
            #expect(engine.state(at: now).phase == .complete)
            #expect(engine.state(at: now).stepPosition == (sign == 1 ? 150 : 0))
            #expect(engine.currentProgram.marks == marks)
            #expect(engine.currentProgram.transitions[0].duration == duration)
        }
    }
}

@Test(arguments: [1, 7, 8, 47, 150, 151])
func rackPreparationGuidanceTracksAcknowledgedSizesWithoutBlockingPlayback(span: Int) throws {
    var (engine, now) = try preparationEngine(span)
    let plan = try FocusRackPreparation.make(signedSteps: span)
    let missing = plan.chunks.contains { engine.calibrationTimings[abs($0) * 16] == nil }
    let before = engine.state(at: now)
    #expect(before.preparationRecommended == missing)
    #expect(before.preparingLens == false)
    #expect(before.pullBToA?.enabled == true)
    try engine.calibrate(at: now)
    #expect(engine.state(at: now).preparingLens == true)
    _ = try finishPreparation(&engine, now: &now)
    #expect(engine.state(at: now).preparationRecommended == false)
    #expect(engine.state(at: now).preparingLens == false)
    engine.observe(preparationContext(now, recording: true), at: now)
    #expect(engine.state(at: now).preparationRecommended == false)
    #expect(engine.state(at: now).pullAToB?.enabled == true)
}

@Test func rackPreparationGuidanceIsStableWhileRecordingAndRetiresForUnknownPositions() throws {
    var (engine, now) = try preparationEngine(150)
    engine.observe(preparationContext(now, recording: true), at: now)
    #expect(engine.state(at: now).preparationRecommended == true)
    #expect(engine.state(at: now).calibration?.enabled == false)
    engine.observe(preparationContext(now), at: now)
    try engine.calibrate(at: now)
    let first = engine.nextAction(at: now)
    engine.requestStop(at: now)
    #expect(engine.state(at: now).preparingLens == false)
    now += 0.05
    engine.complete(runID: first.runID, commandID: 0, outcome: 4, at: now)
    #expect(engine.state(at: now).referenceValid == false)
    #expect(engine.state(at: now).preparationRecommended == false)
}

@Test func rackPreparationGuidanceMetadataRoundTripsAndOlderPayloadsDecode() throws {
    var state = FocusRackState.initial
    state.preparationRecommended = true
    state.preparingLens = false
    state.timingWarningIsEstimate = true
    let data = try JSONEncoder().encode(state)
    let restored = try JSONDecoder().decode(FocusRackState.self, from: data)
    #expect(restored.preparationRecommended == true)
    #expect(restored.preparingLens == false)
    #expect(restored.timingWarningIsEstimate == true)
    var old = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    old.removeValue(forKey: "preparationRecommended")
    old.removeValue(forKey: "preparingLens")
    old.removeValue(forKey: "timingWarningIsEstimate")
    let legacy = try JSONDecoder().decode(
        FocusRackState.self, from: JSONSerialization.data(withJSONObject: old))
    #expect(legacy.preparationRecommended == nil)
    #expect(legacy.preparingLens == nil)
    #expect(legacy.timingWarningIsEstimate == nil)
}

@Test func rackPreparationGuidanceReturnsForANewUnmeasuredResidual() throws {
    var (engine, now) = try preparationEngine(150)
    try engine.calibrate(at: now)
    _ = try finishPreparation(&engine, now: &now)
    #expect(engine.state(at: now).preparationRecommended == false)
    try engine.seek(markID: "B", at: now)
    _ = try finishPreparation(&engine, now: &now)
    try engine.nudge(towardNear: false, steps: 1, at: now)
    _ = try finishPreparation(&engine, now: &now)
    try engine.capture(markID: "B", at: now)
    #expect(engine.calibrationTimings[144] == nil)
    #expect(engine.state(at: now).preparationRecommended == true)
    #expect(engine.state(at: now).pullBToA?.enabled == true)
    try engine.calibrate(at: now)
    _ = try finishPreparation(&engine, now: &now)
    #expect(engine.calibrationTimings[144] != nil)
    #expect(engine.state(at: now).preparationRecommended == false)
}

@Test func rackPreparationGuidanceReturnsWhenLensTimingBecomesIncompatible() throws {
    var (engine, now) = try preparationEngine(150)
    try engine.calibrate(at: now)
    _ = try finishPreparation(&engine, now: &now)
    #expect(engine.state(at: now).preparationRecommended == false)
    let marks = engine.currentProgram.marks
    var changed = preparationContext(now)
    changed.lens = "another synthetic lens"
    engine.observe(changed, at: now)
    #expect(engine.currentProgram.marks == marks)
    #expect(engine.state(at: now).preparationRecommended == true)
    #expect(engine.state(at: now).preparingLens == false)
}

@Test func rackTimingWarningMetadataKeepsCompletionSeparateFromTheNextEstimate() throws {
    var (engine, now) = try preparationEngine(150)
    #expect(engine.state(at: now).timingWarning != nil)
    #expect(engine.state(at: now).timingWarningIsEstimate == true)
    try engine.run(direction: .bToA, at: now)
    _ = try finishPreparation(&engine, now: &now)
    let completed = engine.state(at: now)
    #expect(completed.phase == .complete)
    #expect(try #require(completed.actualMovementDuration) > 3)
    #expect(completed.timingWarning?.contains("completed in") == true)
    #expect(completed.timingWarningIsEstimate == false)
    try engine.setTransition(.init(duration: 1), at: now)
    #expect(engine.state(at: now).timingWarningIsEstimate == true)
}
