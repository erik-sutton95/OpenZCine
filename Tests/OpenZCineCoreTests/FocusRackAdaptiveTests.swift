import Foundation
import Testing

@testable import OpenZCineCore

private func timing(_ seconds: Double) -> FocusRackCommandTiming {
    var result = FocusRackCommandTiming()
    result.record(seconds)
    return result
}

private func adaptivePlan(
    _ steps: Int, seconds: Double, timed: Bool = true,
    delay: Double = 0
) throws -> FocusRackMovementPlan {
    try FocusRackPlanner.make(
        signedSteps: steps, duration: seconds, delay: delay, quiet: 0.01,
        timings: [
            1: timing(0.06), 4: timing(0.07), 5: timing(0.07), 9: timing(0.07), 12: timing(0.07),
        ],
        timed: timed, grouped: true)
}

@Test func adaptiveFastestPreservesBudgetDirectionAndOneExactResidual() throws {
    for sign in [-1, 1] {
        let plan = try adaptivePlan(sign * 83, seconds: 20, timed: false, delay: 2)
        #expect(
            plan.chunks == Array(repeating: sign * 12, count: 6) + [sign * 11])
        #expect(plan.chunks.reduce(0, +) == sign * 83)
        #expect(plan.offsets.allSatisfy { $0 == 2 })
        #expect(plan.estimatedDuration == nil)
    }
    #expect(try adaptivePlan(3, seconds: 1, timed: false).chunks == [3])
    #expect(try adaptivePlan(5, seconds: 20, timed: false).chunks == [5])
}

@Test func fastestDoesNotInventAnEstimateBeforeItsQuantumIsMeasured() throws {
    let plan = try FocusRackPlanner.make(
        signedSteps: 80, duration: 3, delay: 0, quiet: 0.01,
        timings: [1: timing(0.06)], timed: false, grouped: true)
    #expect(plan.estimatedDuration == nil)
    #expect(plan.chunks == Array(repeating: 12, count: 6) + [8])
    #expect(plan.offsets.allSatisfy { $0 == 0 })
}

@Test func durationModeRestoresOldTemplatesAndRejectsUnknownModes() throws {
    let old = Data(
        #"[{"name":"Old","transition":{"fromMark":"A","toMark":"B","duration":3,"delay":2,"easing":"linear"}}]"#
            .utf8)
    let restored = try FocusRackTemplateCodec.decode(old)
    #expect(restored[0].transition.durationMode == .timed)
    var fastest = restored[0].transition
    fastest.durationMode = .fastest
    let data = try FocusRackTemplateCodec.encode([.init(name: "Fast", transition: fastest)])
    #expect(try FocusRackTemplateCodec.decode(data)[0].transition == fastest)
    let unknown = Data(
        String(decoding: data, as: UTF8.self).replacingOccurrences(of: "fastest", with: "unknown")
            .utf8)
    #expect(throws: (any Error).self) { try FocusRackTemplateCodec.decode(unknown) }
}

private func adaptiveContext(_ now: Double) -> FocusRackContext {
    .init(
        sessionID: "adaptive-test", connected: true, movieMode: true, foregroundOwner: true,
        focusMode: "AF-S",
        focus: .init(
            trackingAFActive: false, subjectDetectionActive: false,
            boxCount: 1, selectedBoxIndex: nil), frameTimestamp: now, safetyTimestamp: now,
        focusSettled: true, lens: "test lens", focalLength: "70", recording: false,
        frameSequence: Int64(now * 1_000_000), focusArea: "Single-point AF", focusSubject: "Off")
}

@discardableResult private func settleAdaptive(
    _ engine: inout FocusRackEngine, now: inout Double, commandDuration: Double = 0.02
) throws -> [Int] {
    var pulses: [Int] = []
    for _ in 0..<1_000 {
        engine.observe(adaptiveContext(now), at: now)
        guard engine.snapshot(at: now).busy else {
            now += 0.02
            engine.observe(adaptiveContext(now), at: now)
            return pulses
        }
        let action = engine.nextAction(at: now)
        if action.kind == "drive" {
            pulses.append(try #require(action.signedPulses))
            now += commandDuration
            engine.complete(
                runID: action.runID, commandID: try #require(action.commandID), outcome: 0, at: now)
        } else if action.kind == "readSafety" {
            let started = now
            now += 0.1
            engine.recordSafetyRead(startedAt: started, finishedAt: now, accepted: true)
            engine.observe(adaptiveContext(now), at: now)
            engine.finishScheduledRead(
                runID: action.runID, commandID: try #require(action.commandID), accepted: true,
                at: now)
        } else {
            now += action.waitSeconds ?? 0.01
        }
    }
    throw FocusRackError.movementPending
}

private func adaptiveEngineWithMarks(
    _ steps: Int, seekToA: Bool = true
) throws -> (FocusRackEngine, Double) {
    var engine = try FocusRackEngine(
        configuration: FocusRackEngine.productionConfiguration)
    var now = 0.0
    engine.observe(adaptiveContext(now), at: now)
    try engine.capture(markID: "A", at: now)
    var remaining = steps
    while remaining > 0 {
        let count = min(10, remaining)
        try engine.nudge(towardNear: false, steps: count, at: now)
        let setup = try settleAdaptive(&engine, now: &now)
        #expect(setup.allSatisfy { $0 == 16 })
        remaining -= count
    }
    try engine.capture(markID: "B", at: now)
    guard seekToA else { return (engine, now) }
    try engine.seek(markID: "A", at: now)
    let seek = try settleAdaptive(&engine, now: &now)
    #expect(seek.reduce(0, +) == -steps * 16)
    #expect(engine.state(at: now).stepPosition == 0)
    return (engine, now)
}

@Test func adaptiveFastestRunUsesExactLedgerAndSurvivesPauseAndStaleCompletion() throws {
    var (engine, now) = try adaptiveEngineWithMarks(25)
    let marks = engine.currentProgram.marks
    var transition = engine.currentProgram.transitions[0]
    transition.durationMode = .fastest
    transition.delay = 2
    try engine.setTransition(transition, at: now)
    #expect(engine.currentProgram.marks == marks)
    try engine.run(reverse: false, at: now)
    #expect(engine.nextAction(at: now + 1).kind == "wait")
    now += 2
    engine.observe(adaptiveContext(now), at: now)
    let first = engine.nextAction(at: now)
    #expect(first.signedPulses == 192)
    engine.requestPause(at: now + 0.001)
    now += 0.02
    engine.complete(runID: first.runID, commandID: 0, outcome: 0, at: now)
    #expect(engine.state(at: now).stepPosition == 12)
    #expect(engine.state(at: now).completedSteps == 12)
    #expect(engine.state(at: now).totalSteps == 25)
    #expect(engine.state(at: now).phase == .paused)
    engine.complete(runID: first.runID, commandID: 0, outcome: 0, at: now)
    #expect(engine.state(at: now).stepPosition == 12)
    now += 1
    engine.observe(adaptiveContext(now), at: now)
    try engine.resume(at: now)
    let remainder = try settleAdaptive(&engine, now: &now)
    #expect(remainder == [192, 16])
    #expect(engine.state(at: now).stepPosition == 25)
    #expect(engine.state(at: now).phase == .complete)
    #expect(engine.state(at: now).completedSteps == 25)
}

@Test func adaptiveInterruptedCoarseChunkInvalidatesWithoutSendingRemainder() throws {
    var (engine, now) = try adaptiveEngineWithMarks(11)
    var transition = engine.currentProgram.transitions[0]
    transition.durationMode = .fastest
    try engine.setTransition(transition, at: now)
    try engine.run(reverse: false, at: now)
    let action = engine.nextAction(at: now)
    engine.requestStop(at: now + 0.001)
    engine.complete(runID: action.runID, commandID: 0, outcome: 3, at: now + 0.02)
    #expect(!engine.state(at: now + 0.02).referenceValid)
    #expect(engine.nextAction(at: now + 1).kind == "idle")
}

@Test func adaptiveResetAndTemplateLoadClearOldProgress() throws {
    var (engine, now) = try adaptiveEngineWithMarks(11)
    #expect(engine.state(at: now).totalSteps == 11)
    try engine.reset(at: now)
    #expect(engine.state(at: now).completedSteps == 0)
    #expect(engine.state(at: now).totalSteps == 0)
    now += 0.02
    engine.observe(adaptiveContext(now), at: now)
    try engine.nudge(towardNear: false, steps: 4, at: now)
    try settleAdaptive(&engine, now: &now)
    try engine.applyTemplate(.init(name: "Fresh", transition: .init()), at: now)
    #expect(engine.state(at: now).completedSteps == 0)
    #expect(engine.state(at: now).totalSteps == 0)
}

@Test func automaticTimedRunRetainsItsChunksAcrossPauseAndStaleCompletion() throws {
    var (engine, now) = try adaptiveEngineWithMarks(11)
    var transition = engine.currentProgram.transitions[0]
    transition.duration = 3
    transition.easing = .linear
    transition.delay = 2
    try engine.setTransition(transition, at: now)
    try engine.run(reverse: false, at: now)
    #expect(engine.nextAction(at: now + 1).kind == "wait")
    now += 2
    engine.observe(adaptiveContext(now), at: now)
    let first = engine.nextAction(at: now)
    #expect(first.signedPulses == 16)
    engine.requestPause(at: now + 0.001)
    now += 0.02
    engine.complete(runID: first.runID, commandID: 0, outcome: 0, at: now)
    #expect(engine.state(at: now).phase == .paused)
    #expect(engine.state(at: now).stepPosition == 1)
    engine.complete(runID: first.runID, commandID: 0, outcome: 0, at: now)
    #expect(engine.state(at: now).stepPosition == 1)
    now += 1
    engine.observe(adaptiveContext(now), at: now)
    try engine.resume(at: now)
    let remaining = try settleAdaptive(&engine, now: &now)
    #expect(remaining == Array(repeating: 16, count: 10))
    #expect(engine.state(at: now).stepPosition == 11)
    #expect(engine.state(at: now).phase == .complete)
}

@Test func zeroQuietStillWaitsForReadyAndPreflightDoesNotConsumeThePull() throws {
    var (engine, now) = try adaptiveEngineWithMarks(60)
    var transition = engine.currentProgram.transitions[0]
    transition.duration = 1
    transition.delay = 0.2
    transition.easing = .linear
    try engine.setTransition(transition, at: now)
    try engine.run(reverse: false, at: now)
    let run = engine.state(at: now).runID
    now += 0.5
    engine.observe(adaptiveContext(now), at: now)
    engine.finishPreflight(runID: run, at: now)
    #expect(abs((engine.scheduledFinish ?? 0) - now - 1.2) < 1e-9)
    #expect(engine.nextAction(at: now + 0.19).kind == "wait")
    now += 0.2
    engine.observe(adaptiveContext(now), at: now)
    let first = engine.nextAction(at: now)
    #expect(first.kind == "drive")
    #expect(engine.nextAction(at: now + 0.01).kind == "idle")
    #expect(engine.state(at: now).stepPosition == 0)
    engine.requestStop(at: now + 0.01)
    engine.complete(
        runID: run, commandID: try #require(first.commandID), outcome: 3, at: now + 0.02)
    engine.finishPreflight(runID: run, at: now + 1)
    #expect(engine.nextAction(at: now + 1).kind == "idle")
    #expect(!engine.state(at: now + 1).referenceValid)
}

@Test(arguments: [false, true])
func preflightRebaseExcludesPausesBeforeItsCompletion(resumeDuringPreflight: Bool) throws {
    var (engine, now) = try adaptiveEngineWithMarks(11)
    var transition = engine.currentProgram.transitions[0]
    transition.duration = 1
    transition.delay = 0.2
    try engine.setTransition(transition, at: now)
    try engine.run(reverse: false, at: now)
    let run = engine.state(at: now).runID
    engine.requestPause(at: now + 0.1)
    if resumeDuringPreflight { try engine.resume(at: now + 0.2) }
    now += 0.5
    engine.observe(adaptiveContext(now), at: now)
    engine.finishPreflight(runID: run, at: now)
    if !resumeDuringPreflight {
        #expect(engine.scheduledFinish == nil)
        now += 0.05
        try engine.resume(at: now)
    }
    #expect(abs((engine.scheduledFinish ?? 0) - now - 1.2) < 1e-9)
    #expect(engine.state(at: now).activeElapsed == 0)
    #expect(engine.nextAction(at: now + 0.19).kind == "wait")
    #expect(engine.nextAction(at: now + 0.2).kind == "drive")
}

@Test func widerPositioningMeasuresOneExactResidualWithoutHiddenCalibration() throws {
    for residual in 1...11 {
        for sign in [-1, 1] {
            let steps = sign * (12 * 10 + residual)
            let unknown = try FocusRackPlanner.make(
                signedSteps: steps, duration: 1, delay: 0, quiet: 0, timings: [12: timing(0.067)],
                timed: false, grouped: true)
            #expect(unknown.chunks == Array(repeating: sign * 12, count: 10) + [sign * residual])
            #expect(unknown.chunks.reduce(0, +) == steps)
            #expect(unknown.estimatedDuration == nil)
            let known = try FocusRackPlanner.make(
                signedSteps: steps, duration: 1, delay: 0, quiet: 0,
                timings: [12: timing(0.067), residual: timing(0.05)],
                timed: false, grouped: true)
            #expect(abs((known.estimatedDuration ?? 0) - (10 * 0.067 + 0.05)) < 1e-9)
        }
    }
}

@Test func rackPartialCalibrationAddsMeasuredChoicesWithoutAssumingResidualTiming() throws {
    var timings = [6: timing(0.06), 10: timing(0.08)]
    func plan(_ duration: Double) throws -> FocusRackMovementPlan {
        try FocusRackPlanner.make(
            signedSteps: 100, duration: duration, delay: 0, quiet: 0, timings: timings, timed: true,
            grouped: true,
            safetyReadBudget: 0.1)
    }
    #expect(try plan(1).chunks == Array(repeating: 10, count: 10))
    // Partial evidence can supply a complete timed move without borrowing unmeasured sizes.
    #expect(try plan(3).chunks.allSatisfy { [6, 10].contains(abs($0)) })
    timings[4] = timing(0.06)
    #expect(try plan(3).chunks.contains(4))
    #expect(try plan(5).chunks.contains(4))
    timings[6] = timing(0.4)
    #expect(try plan(3).chunks.allSatisfy { [4, 10].contains(abs($0)) })
}

@Test(arguments: [1.0, 3.0, 5.0])
func rackMeasuredFinePlanningRetainsWorstCostsAndReservesSafetySlots(duration: Double) throws {
    let timings = [
        1: timing(0.210), 2: timing(0.06), 3: timing(0.06), 4: timing(0.06),
        6: timing(0.06), 8: timing(0.06), 10: timing(0.09),
    ]
    for sign in [-1, 1] {
        let plan = try FocusRackPlanner.make(
            signedSteps: sign * 100, duration: duration, delay: 0, quiet: 0, timings: timings,
            timed: true, grouped: true,
            safetyReadBudget: 0.1)
        #expect(plan.chunks.reduce(0, +) == sign * 100)
        for index in 0..<(plan.chunks.count - 1) {
            let gap = plan.offsets[index + 1] - plan.offsets[index]
            let nativeCost = timings[abs(plan.chunks[index])]?.longest ?? 0
            #expect(gap + 1e-9 >= nativeCost)
            if let read = plan.maintenanceReadOffsets?[index + 1] {
                #expect(read + 1e-9 >= plan.offsets[index] + nativeCost)
                #expect(read + 0.1 <= plan.offsets[index + 1] + 1e-9)
            }
            #expect(gap <= FocusRackPlanner.maximumFineSpacing + 1e-9)
        }
        #expect(
            (plan.offsets.last ?? 0) + (timings[abs(plan.chunks.last ?? 0)]?.longest ?? 0)
                == duration)
    }
    #expect(timings[1]?.longest == 0.210)
}

@Test(arguments: [false, true])
func rackGrowingReadBudgetKeepsSafeMovementAvailable(afterFirstCommand: Bool) throws {
    var (engine, now) = try adaptiveEngineWithMarks(100)
    engine.recordSafetyRead(startedAt: now - 0.05, finishedAt: now, accepted: true)
    try engine.setTransition(.init(duration: 3), at: now)
    try engine.run(direction: .aToB, at: now)
    if afterFirstCommand {
        let first = engine.nextAction(at: now)
        #expect(first.kind == "drive")
        now += 0.02
        engine.complete(runID: first.runID, commandID: 0, outcome: 0, at: now)
    } else {
        engine.finishPreflight(runID: engine.state(at: now).runID, at: now)
    }
    let acknowledged = engine.state(at: now).stepPosition
    engine.recordSafetyRead(startedAt: now - 0.3, finishedAt: now, accepted: true)
    if afterFirstCommand { now += 0.25 }
    engine.observe(adaptiveContext(now), at: now)
    #expect(engine.nextAction(at: now).kind == "drive")
    #expect(engine.state(at: now).phase == .moving)
    #expect(engine.state(at: now).stepPosition == acknowledged)
    #expect(engine.state(at: now).referenceValid)
}

@Test func rackCountdownRefreshCanKeepAOneSecondFinePullWithinFreshEvidence() throws {
    var (engine, now) = try adaptiveEngineWithMarks(100)
    for _ in 0..<2 {
        try engine.calibrate(at: now)
        try settleAdaptive(&engine, now: &now, commandDuration: 0.06)
    }
    engine.recordSafetyRead(startedAt: now - 0.05, finishedAt: now, accepted: true)
    try engine.setTransition(.init(duration: 1, delay: 2), at: now)
    try engine.run(direction: .aToB, at: now)
    let started = now
    #expect(engine.nextAction(at: now).kind == "wait")
    for elapsed in [1.0, 1.9] {
        now = started + elapsed
        engine.recordSafetyRead(startedAt: now - 0.05, finishedAt: now, accepted: true)
        engine.observe(adaptiveContext(now), at: now)
        #expect(engine.nextAction(at: now).kind == "wait")
        #expect(engine.state(at: now).stepPosition == 0)
    }
    now = started + 2
    engine.observe(adaptiveContext(now), at: now)
    let pulses = try settleAdaptive(&engine, now: &now, commandDuration: 0.06)
    #expect(pulses.reduce(0, +) == 1_600)
    #expect(engine.state(at: now).phase == .complete)
}

@Test func rackFreshQualificationRecoversFromAHistoricalSlowIdleRead() throws {
    var (engine, now) = try adaptiveEngineWithMarks(100)
    for _ in 0..<2 {
        try engine.calibrate(at: now)
        try settleAdaptive(&engine, now: &now, commandDuration: 0.06)
    }
    let marks = engine.currentProgram.marks
    engine.recordSafetyRead(startedAt: now - 1.328, finishedAt: now, accepted: true)
    // A short pull still needs actual preflight qualification, not a future idle-read slot.
    try engine.setTransition(.init(duration: 1), at: now)
    #expect(engine.state(at: now).admissionMessage == nil)
    try engine.setTransition(.init(duration: 3), at: now)
    #expect(engine.state(at: now).admissionMessage == nil)
    #expect(engine.state(at: now).estimatedDuration.map { $0.isFinite && $0 > 0 } == true)
    engine.recordSafetyRead(startedAt: now - 0.06, finishedAt: now, accepted: true)
    #expect(engine.safetyReadBudget == 0.1)
    for duration in [1.0, 3.0, 5.0] {
        try engine.setTransition(.init(duration: duration), at: now)
        #expect(engine.state(at: now).admissionMessage == nil)
    }
    #expect(engine.currentProgram.marks == marks)
    #expect(engine.state(at: now).calibration?.title == "Prepare lens")
    try engine.setTransition(.init(duration: 1), at: now)
    try engine.run(direction: .aToB, at: now)
    let pulses = try settleAdaptive(&engine, now: &now, commandDuration: 0.06)
    #expect(pulses == Array(repeating: 128, count: 12) + [64])
    #expect(engine.state(at: now).phase == .complete)
}

@Test func rackActualSlowPreflightKeepsCoveredCommandsAvailable() throws {
    var (engine, now) = try adaptiveEngineWithMarks(100)
    engine.recordSafetyRead(startedAt: now - 0.06, finishedAt: now, accepted: true)
    try engine.setTransition(.init(duration: 1), at: now)
    try engine.run(direction: .aToB, at: now)
    let run = engine.state(at: now).runID
    let readStart = now
    now += 1.328
    engine.recordSafetyRead(startedAt: readStart, finishedAt: now, accepted: true)
    var context = adaptiveContext(now)
    context.safetyTimestamp = readStart
    engine.observe(context, at: now)
    engine.finishPreflight(runID: run, at: now)
    #expect(engine.nextAction(at: now).kind == "drive")
    #expect(engine.state(at: now).busy)
    #expect(engine.state(at: now).stepPosition == 0)
    #expect(engine.state(at: now).referenceValid)
}

@Test func rackMaintenanceDeadlineHonorsPauseAndCannotAffectAnotherRun() throws {
    var (engine, now) = try adaptiveEngineWithMarks(100)
    engine.recordSafetyRead(startedAt: now - 0.06, finishedAt: now, accepted: true)
    try engine.setTransition(.init(duration: 3, delay: 1), at: now)
    try engine.run(direction: .aToB, at: now)
    let run = engine.state(at: now).runID
    let deadline = try #require(engine.nextCommandDeadline)
    engine.requestPause(at: now + 0.1)
    engine.finishMaintenanceRead(runID: run, at: deadline + 0.1)
    #expect(engine.state(at: deadline + 0.1).phase == .paused)
    now = deadline + 0.2
    engine.observe(adaptiveContext(now), at: now)
    try engine.resume(at: now)
    engine.finishMaintenanceRead(runID: run, at: now)
    #expect(engine.state(at: now).busy)
    #expect(try #require(engine.nextCommandDeadline) > now)
    engine.requestStop(at: now)
    try engine.run(direction: .aToB, at: now)
    engine.finishMaintenanceRead(runID: run, at: now + 100)
    #expect(engine.state(at: now).busy)
    #expect(engine.state(at: now).runID != run)
}

@Test func rackNonHundredUnitPlansStillRequireMeasuredResidualCommands() throws {
    var timings = [1: timing(0.06), 8: timing(0.068), 10: timing(0.06)]
    func plan() throws -> FocusRackMovementPlan {
        try FocusRackPlanner.make(
            signedSteps: 106, duration: 1, delay: 0, quiet: 0, timings: timings, timed: true,
            grouped: true,
            safetyReadBudget: 0.1)
    }
    let fine = try plan()
    #expect(fine.chunks.reduce(0, +) == 106)
    #expect(fine.chunks.allSatisfy { [1, 8, 10].contains(abs($0)) })
    #expect(fine.duration == 1)
    timings[2] = timing(0.06)
    #expect(try plan().chunks == Array(repeating: 8, count: 13) + [2])
    timings[2] = timing(0.128)
    let slowerResidual = try plan()
    #expect(slowerResidual.chunks.reduce(0, +) == 106)
    #expect(slowerResidual.chunks.allSatisfy { [1, 8, 10].contains(abs($0)) })
    #expect(slowerResidual.duration == 1)
}
