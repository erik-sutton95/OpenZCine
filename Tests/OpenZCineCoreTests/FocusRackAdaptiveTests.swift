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
    delay: Double = 0, easing: FocusRackEasing = .linear
) throws -> FocusRackMovementPlan {
    try FocusRackPlanner.make(
        signedSteps: steps, duration: seconds, delay: delay, easing: easing,
        quiet: 0.01,
        timings: [
            1: timing(0.06), 4: timing(0.07), 5: timing(0.07), 9: timing(0.07), 12: timing(0.07),
        ], adaptive: true,
        timed: timed, grouped: true)
}

@Test func adaptiveTimedPlanningHandlesShortLongAndCloseFarSpans() throws {
    let shortClose = try adaptivePlan(10, seconds: 1)
    #expect(shortClose.chunks == Array(repeating: 1, count: 10))
    #expect(abs((shortClose.offsets.last ?? 0) - 0.94) < 1e-9)
    let longFar = try adaptivePlan(80, seconds: 20)
    #expect(longFar.chunks.count == 80)
    #expect(abs((longFar.offsets.last ?? 0) - 19.94) < 1e-9)
    #expect(try adaptivePlan(80, seconds: 1).chunks.map(abs).max() == 9)
    do {
        _ = try adaptivePlan(4, seconds: 20)
        Issue.record("Sparse long pull must not masquerade as smooth timing")
    } catch FocusRackError.durationTooLong(let maximum) {
        #expect(maximum < 1)
    }
}

@Test func adaptiveFastestPreservesBudgetDirectionAndOneExactResidual() throws {
    for sign in [-1, 1] {
        let plan = try adaptivePlan(sign * 83, seconds: 20, timed: false, delay: 2)
        #expect(
            plan.chunks == Array(repeating: sign * 12, count: 6) + [sign * 11])
        #expect(plan.chunks.reduce(0, +) == sign * 83)
        #expect(plan.offsets.allSatisfy { $0 == 2 })
        #expect(plan.minimumDuration == 0)
        #expect(plan.estimatedDuration == nil)
    }
    #expect(try adaptivePlan(3, seconds: 1, timed: false).chunks == [3])
    #expect(try adaptivePlan(5, seconds: 20, timed: false).chunks == [5])
}

@Test func fastestDoesNotInventAnEstimateBeforeItsQuantumIsMeasured() throws {
    let plan = try FocusRackPlanner.make(
        signedSteps: 80, duration: 3, delay: 0, easing: .easeInOut, quiet: 0.01,
        timings: [1: timing(0.06)], adaptive: true, timed: false, grouped: true)
    #expect(plan.estimatedDuration == nil)
    #expect(plan.chunks == Array(repeating: 12, count: 6) + [8])
    #expect(plan.offsets.allSatisfy { $0 == 0 })
}

@Test func timedPlanningUsesBoundedGroupsAndRetainsFineLongPulls() throws {
    #expect(try adaptivePlan(80, seconds: 2).chunks == Array(repeating: 4, count: 20))
    let fine = try adaptivePlan(94, seconds: 24)
    #expect(fine.chunks.allSatisfy { $0 == 1 })
    #expect(throws: FocusRackError.self) { try adaptivePlan(4, seconds: 2, easing: .easeInOut) }
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
    _ steps: Int, profile: FocusRackProfile = .adaptive, seekToA: Bool = true
) throws -> (FocusRackEngine, Double) {
    var engine = try FocusRackEngine(
        configuration: FocusRackEngine.productionConfiguration, adaptive: true, profile: profile)
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

@Test func emptySmoothTimingRangeGivesOneActionableError() throws {
    for duration in [3.0, 24.0] {
        #expect(throws: FocusRackError.self) {
            try FocusRackPlanner.make(
                signedSteps: 94, duration: duration, delay: 0,
                easing: .easeInOut, quiet: 0.01, timings: [1: timing(0.15)], adaptive: true,
                timed: true, grouped: true)
        }
    }
    #expect(focusRackMaximumForDisplay(0.516129) == 0.51)
    _ = try adaptivePlan(3, seconds: focusRackMaximumForDisplay(0.576129))
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

@Test func emptyRoundedTimingRangesAreNotAdvertisedAsSupported() throws {
    for duration in [24.0, 24.245] {
        #expect(throws: FocusRackError.noSmoothTiming) {
            try FocusRackPlanner.make(
                signedSteps: 94, duration: duration, delay: 0,
                easing: .linear, quiet: 0.01, timings: [1: timing(0.248)], adaptive: true,
                timed: true, grouped: true)
        }
    }
}

@Test func timedPlannerAutomaticallySelectsGranularityForRequestedDuration() throws {
    let measured: [Int: FocusRackCommandTiming] = [
        1: timing(0.14), 2: timing(0.13), 3: timing(0.12), 4: timing(0.11),
    ]
    for sign in [-1, 1] {
        let plans = try [3.0, 10.0, 20.0].map { duration in
            try FocusRackPlanner.make(
                signedSteps: sign * 94, duration: duration, delay: 2, easing: .linear,
                quiet: 0.01, timings: measured, adaptive: true, timed: true, grouped: true)
        }
        #expect(plans[0].chunks.map(abs).max() == 4)
        #expect(plans[1].chunks.map(abs).max() == 2)
        #expect(plans[2].chunks.allSatisfy { abs($0) == 1 })
        for (plan, duration) in zip(plans, [3.0, 10.0, 20.0]) {
            #expect(plan.chunks.reduce(0, +) == sign * 94)
            #expect(plan.offsets.first == 2)
            for index in 0..<(plan.chunks.count - 1) {
                let cost = try #require(measured[abs(plan.chunks[index])]).longest
                #expect(plan.offsets[index + 1] - plan.offsets[index] + 1e-9 >= cost + 0.01)
            }
            let final = try #require(plan.chunks.last)
            #expect(
                abs((plan.offsets.last ?? 0) + (measured[abs(final)]?.longest ?? 0) - 2 - duration)
                    < 1e-9)
        }
    }
}

@Test func automaticTimingKeepsOneExactResidualAndUsesPerSizeCosts() throws {
    for steps in [5, 79, 94, 95, 97] {
        for sign in [-1, 1] {
            let plan = try FocusRackPlanner.make(
                signedSteps: sign * steps, duration: max(0.3, 0.04 * Double(steps)), delay: 0,
                easing: .linear, quiet: 0.01,
                timings: [1: timing(0.14), 2: timing(0.13), 3: timing(0.12), 4: timing(0.11)],
                adaptive: true, timed: true, grouped: true)
            #expect(plan.chunks.reduce(0, +) == sign * steps)
            #expect(plan.chunks.allSatisfy { (1...5).contains(abs($0)) })
            #expect(plan.chunks.dropLast().allSatisfy { $0 == plan.chunks[0] })
            #expect(plan.chunks.allSatisfy { ($0 < 0) == (sign < 0) })
        }
    }
}

@Test func unknownTimingSizeUsesSessionEstimateAndUpdatesOnMeasurement() throws {
    let estimated = try FocusRackPlanner.make(
        signedSteps: 94, duration: 4, delay: 0, easing: .linear, quiet: 0.01,
        timings: [1: timing(0.14)], adaptive: true, timed: true, grouped: true)
    #expect(estimated.chunks.reduce(0, +) == 94)
    #expect(estimated.chunks.map(abs).max() == 4)
    #expect(throws: FocusRackError.self) {
        try FocusRackPlanner.make(
            signedSteps: 94, duration: 4, delay: 0, easing: .linear, quiet: 0.01,
            timings: [1: timing(0.14), 4: timing(0.20), 5: timing(0.30)], adaptive: true,
            timed: true, grouped: true)
    }
}

@Test func automaticTimedRunRetainsItsChunksAcrossPauseAndStaleCompletion() throws {
    var (engine, now) = try adaptiveEngineWithMarks(11)
    var transition = engine.currentProgram.transitions[0]
    transition.duration = 0.10
    transition.easing = .linear
    transition.delay = 2
    try engine.setTransition(transition, at: now)
    try engine.run(reverse: false, at: now)
    #expect(engine.nextAction(at: now + 1).kind == "wait")
    now += 2
    engine.observe(adaptiveContext(now), at: now)
    let first = engine.nextAction(at: now)
    #expect(first.signedPulses == 48)
    engine.requestPause(at: now + 0.001)
    now += 0.02
    engine.complete(runID: first.runID, commandID: 0, outcome: 0, at: now)
    #expect(engine.state(at: now).phase == .paused)
    #expect(engine.state(at: now).stepPosition == 3)
    engine.complete(runID: first.runID, commandID: 0, outcome: 0, at: now)
    #expect(engine.state(at: now).stepPosition == 3)
    now += 1
    engine.observe(adaptiveContext(now), at: now)
    try engine.resume(at: now)
    let remaining = try settleAdaptive(&engine, now: &now)
    #expect(remaining == [48, 48, 32])
    #expect(engine.state(at: now).stepPosition == 11)
    #expect(engine.state(at: now).phase == .complete)
}

@Test func coarseProfilesDoNotStretchIntoPreviouslySteppedCadences() throws {
    #expect(throws: FocusRackError.noSmoothTiming) {
        try FocusRackPlanner.make(
            signedSteps: 94, duration: 8, delay: 0, easing: .linear, quiet: 0.01,
            timings: [1: timing(0.14), 2: timing(0.4), 3: timing(0.4), 4: timing(0.11)],
            adaptive: true, timed: true, grouped: true)
    }
    #expect(throws: FocusRackError.noSmoothTiming) {
        try FocusRackPlanner.make(
            signedSteps: 94, duration: 13, delay: 0, easing: .linear, quiet: 0.01,
            timings: [1: timing(0.14), 2: timing(0.13), 3: timing(0.12), 4: timing(0.11)],
            adaptive: true, timed: true, grouped: true)
    }
    let plan = try adaptivePlan(94, seconds: 3)
    for (start, end) in zip(plan.offsets, plan.offsets.dropFirst()) {
        #expect(end - start <= FocusRackPlanner.maximumFineSpacing + 1e-9)
    }
}

@Test func fastProfileKeepsSmallerGroupsWhenTheyFitAndExpandsForWiderSpans() throws {
    func plan(_ steps: Int, cost: Double) throws -> FocusRackMovementPlan {
        try FocusRackPlanner.make(
            signedSteps: steps, duration: 1, delay: 2, easing: .linear, quiet: 0,
            timings: [
                1: timing(cost), 2: timing(cost), 3: timing(cost),
                4: timing(cost), 5: timing(cost),
            ], adaptive: true, timed: true, grouped: true)
    }
    for sign in [-1, 1] {
        let fast = try plan(sign * 60, cost: 0.08)
        #expect(fast.chunks == Array(repeating: sign * 5, count: 12))
        #expect(fast.chunks.reduce(0, +) == sign * 60)
        #expect(abs((fast.offsets.last ?? 0) + 0.08 - 3) < 1e-9)
        #expect(try plan(sign * 60, cost: 0.09).chunks.map(abs).max() == 9)
        #expect(try plan(sign * 94, cost: 0.08).chunks.map(abs).max() == 9)
        let residual = try FocusRackPlanner.make(
            signedSteps: sign * 94, duration: 1.6, delay: 0, easing: .linear, quiet: 0,
            timings: [
                1: timing(0.08), 2: timing(0.08), 3: timing(0.08),
                4: timing(0.08), 5: timing(0.08),
            ], adaptive: true, timed: true, grouped: true)
        #expect(residual.chunks == Array(repeating: sign * 5, count: 18) + [sign * 4])
        #expect(residual.chunks.reduce(0, +) == sign * 94)
    }
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

@Test func wideOneSecondPlanPrefers144AndFallsBackTo192WithoutRelaxingAdmission() throws {
    for sign in [-1, 1] {
        var costs = [
            1: timing(0.0763745), 3: timing(0.0763745), 5: timing(0.0763745),
            9: timing(0.064159042), 12: timing(0.059873292),
        ]
        func plan(_ seconds: Double) throws -> FocusRackMovementPlan {
            try FocusRackPlanner.make(
                signedSteps: sign * 135, duration: seconds, delay: 2, easing: .linear,
                quiet: 0, timings: costs, adaptive: true, timed: true, grouped: true)
        }
        #expect(try plan(1).chunks == Array(repeating: sign * 9, count: 15))
        costs[9] = timing(0.066875)
        let fallback = try plan(1)
        #expect(fallback.chunks == Array(repeating: sign * 12, count: 11) + [sign * 3])
        #expect(try plan(1.01).chunks == Array(repeating: sign * 9, count: 15))
        #expect(try plan(20).chunks == Array(repeating: sign, count: 135))
        #expect(fallback.chunks.reduce(0, +) == sign * 135)
        #expect(abs((fallback.offsets.last ?? 0) + 0.0763745 - 3) < 1e-9)
        costs[12] = timing(0.10)
        #expect(throws: FocusRackError.self) { try plan(1) }
    }
}

@Test func widerPositioningMeasuresOneExactResidualWithoutHiddenCalibration() throws {
    for residual in 1...11 {
        for sign in [-1, 1] {
            let steps = sign * (12 * 10 + residual)
            let unknown = try FocusRackPlanner.make(
                signedSteps: steps, duration: 1, delay: 0, easing: .linear,
                quiet: 0, timings: [12: timing(0.067)], adaptive: true, timed: false, grouped: true)
            #expect(unknown.chunks == Array(repeating: sign * 12, count: 10) + [sign * residual])
            #expect(unknown.chunks.reduce(0, +) == steps)
            #expect(unknown.estimatedDuration == nil)
            let known = try FocusRackPlanner.make(
                signedSteps: steps, duration: 1, delay: 0, easing: .linear,
                quiet: 0, timings: [12: timing(0.067), residual: timing(0.05)],
                adaptive: true, timed: false, grouped: true)
            #expect(abs((known.estimatedDuration ?? 0) - (10 * 0.067 + 0.05)) < 1e-9)
        }
    }
}

@Test func explicitPositioningMeasuresTheLargestProfileNeededFor130UnitOneSecondPull() throws {
    var costs = [1: timing(0.1691853334), 4: timing(0.079744625), 9: timing(0.0881446667)]
    func plan(timed: Bool) throws -> FocusRackMovementPlan {
        try FocusRackPlanner.make(
            signedSteps: -130, duration: 1, delay: 0, easing: .linear,
            quiet: 0, timings: costs, adaptive: true, timed: timed, grouped: true)
    }
    do {
        _ = try plan(timed: true)
        Issue.record("Unmeasured larger sizes must not bypass timing admission")
    } catch FocusRackError.durationTooShort(let minimum) {
        #expect(focusRackMinimumForDisplay(minimum) == 1.32)
    }
    let positioning = try plan(timed: false)
    #expect(positioning.chunks == Array(repeating: -12, count: 10) + [-10])
    costs[12] = timing(0.07)
    costs[10] = timing(0.075)
    let timed = try plan(timed: true)
    #expect(timed.chunks == positioning.chunks)
    #expect(timed.chunks.reduce(0, +) == -130)
    #expect(abs((timed.offsets.last ?? 0) + 0.075 - 1) < 1e-9)
}

@Test func refusedOneSecondPullPreservesTimingMarksAndIndependentPositioning() throws {
    var (engine, now) = try adaptiveEngineWithMarks(130)
    let marks = engine.currentProgram.marks
    for mark in ["B", "A"] {
        try engine.seek(markID: mark, at: now)
        try settleAdaptive(&engine, now: &now, commandDuration: 0.15)
    }
    try engine.setTransition(.init(duration: 1, delay: 0, easing: .linear), at: now)
    #expect(throws: FocusRackError.self) { try engine.run(direction: .aToB, at: now) }
    let state = engine.state(at: now)
    #expect(state.transition.duration == 1)
    #expect(state.pullAToB?.detail == "1 s pull")
    #expect(state.pullBToA?.detail == "1 s pull")
    #expect(!state.busy && state.referenceValid)
    #expect(state.stepPosition == 0)
    #expect(state.program.marks == marks)
    #expect(state.capabilities.canEditTiming)
    #expect(state.capabilities.canGoToB)
    #expect(state.capabilities.canNudge)
    #expect(state.pullAToB?.enabled == false)
    #expect(
        engine.snapshot(at: now, includeEvents: true).events.contains {
            $0.kind == "timingChanged" && $0.note?.contains("duration=1.0") == true
        })
}

@Test func rackTenBy160PlanRequiresItsOwnMeasuredBudgetAndKeepsExactSignedMovement() throws {
    for sign in [-1, 1] {
        func plan(_ costs: [Int: FocusRackCommandTiming]) throws -> FocusRackMovementPlan {
            try FocusRackPlanner.make(
                signedSteps: sign * 100, duration: 1, delay: 2, easing: .linear,
                quiet: 0, timings: costs, adaptive: true, timed: true, grouped: true,
                profile: .tenBy160Experiment)
        }
        #expect(throws: FocusRackError.calibrationRequired) {
            try plan([1: timing(0.001), 12: timing(0.001)])
        }
        #expect(throws: FocusRackError.self) { try plan([10: timing(0.1001), 12: timing(0.001)]) }
        var measured = timing(0.04)
        measured.record(0.08)
        let selected = try plan([1: timing(0.001), 10: measured, 12: timing(0.001)])
        #expect(selected.chunks == Array(repeating: sign * 10, count: 10))
        #expect(selected.chunks.reduce(0, +) * 16 == sign * 1600)
        #expect(abs(selected.minimumDuration - 0.8) < 1e-9)
        #expect(abs((selected.offsets.last ?? 0) + 0.08 - 3) < 1e-9)
    }
}

@Test func rackTenBy160LeavesDefaultPlanningAndOtherMovesUnchanged() throws {
    let costs = [1: timing(0.12), 4: timing(0.05), 10: timing(0.06), 12: timing(0.08)]
    let baseline = try FocusRackPlanner.make(
        signedSteps: 100, duration: 1, delay: 0, easing: .linear,
        quiet: 0, timings: costs, adaptive: true, timed: true, grouped: true)
    #expect(baseline.chunks == Array(repeating: 12, count: 8) + [4])
    for (steps, duration, easing, adaptive, grouped, timed) in [
        (99, 1.0, FocusRackEasing.linear, true, true, true),
        (101, 1.0, .linear, true, true, true),
        (100, 1.05, .linear, true, true, true),
        (100, 1.0, .easeInOut, true, true, true),
        (100, 1.0, .linear, false, true, true),
        (100, 1.0, .linear, true, false, true),
        (99, 1.0, .linear, true, true, false),
        (10, 1.0, .linear, true, false, false),
    ] {
        func plan(_ profile: FocusRackProfile) throws -> FocusRackMovementPlan {
            try FocusRackPlanner.make(
                signedSteps: steps, duration: duration, delay: 0, easing: easing,
                quiet: 0, timings: [1: timing(0.005)], adaptive: adaptive,
                timed: timed, grouped: grouped, profile: profile)
        }
        let standard = try plan(.adaptive)
        let experiment = try plan(.tenBy160Experiment)
        #expect(experiment.chunks == standard.chunks)
        #expect(experiment.offsets == standard.offsets)
        #expect(experiment.minimumDuration == standard.minimumDuration)
    }
}

@Test func rackTenBy160CalibrationAdmissionAndExecutionUseTheSameProfile() throws {
    var (engine, now) = try adaptiveEngineWithMarks(
        100, profile: .tenBy160Experiment, seekToA: false)
    let marks = engine.currentProgram.marks
    try engine.setTransition(.init(duration: 1, delay: 0, easing: .linear), at: now)
    let before = engine.state(at: now)
    #expect(before.admissionMessage == FocusRackError.calibrationRequired.localizedDescription)
    #expect(before.primary.disabledReason == "Go to A or B first")
    #expect(before.playbackInstruction == "Go to A or B first")
    #expect(before.pullAToB?.enabled == false && before.pullBToA?.enabled == false)
    #expect(before.capabilities.canGoToA)
    #expect(throws: FocusRackError.calibrationRequired) {
        try engine.run(direction: .bToA, at: now)
    }
    #expect(!engine.state(at: now).busy)
    #expect(engine.currentProgram.marks == marks)
    try engine.seek(markID: "A", at: now)
    #expect(
        try settleAdaptive(&engine, now: &now, commandDuration: 0.08)
            == Array(repeating: -160, count: 10))
    #expect(engine.state(at: now).admissionMessage == nil)
    #expect(engine.state(at: now).pullAToB?.enabled == true)
    try engine.run(direction: .aToB, at: now)
    #expect(
        try settleAdaptive(&engine, now: &now, commandDuration: 0.08)
            == Array(repeating: 160, count: 10))
    #expect(engine.state(at: now).stepPosition == 100)
    #expect(engine.state(at: now).pullBToA?.enabled == true)
    try engine.run(direction: .bToA, at: now)
    #expect(
        try settleAdaptive(&engine, now: &now, commandDuration: 0.08)
            == Array(repeating: -160, count: 10))
    #expect(engine.state(at: now).stepPosition == 0)
    #expect(engine.state(at: now).phase == .complete)
    #expect(engine.currentProgram.marks == marks)
    #expect(
        engine.snapshot(at: now, includeEvents: true).events.filter { $0.kind == "runStarted" }
            .allSatisfy { $0.note?.contains("profile=tenBy160Experiment") == true })
}

@Test func rackTenBy160SlowCalibrationDoesNotFallBackOrChangeMarks() throws {
    var (engine, now) = try adaptiveEngineWithMarks(
        100, profile: .tenBy160Experiment, seekToA: false)
    let marks = engine.currentProgram.marks
    try engine.seek(markID: "A", at: now)
    try settleAdaptive(&engine, now: &now, commandDuration: 0.1001)
    try engine.setTransition(.init(duration: 1, delay: 0, easing: .linear), at: now)
    #expect(engine.state(at: now).minimumDuration == 1.01)
    #expect(engine.state(at: now).pullAToB?.enabled == false)
    #expect(throws: FocusRackError.self) { try engine.run(direction: .aToB, at: now) }
    #expect(!engine.state(at: now).busy)
    #expect(engine.state(at: now).stepPosition == 0)
    #expect(engine.currentProgram.marks == marks)
    #expect(engine.state(at: now).capabilities.canGoToB)
}

@Test(arguments: [0, 3, 4])
func rackTenBy160StopKeepsCompletedLedgerOrInvalidatesUncertainMovement(outcome: Int) throws {
    var (engine, now) = try adaptiveEngineWithMarks(100, profile: .tenBy160Experiment)
    try engine.setTransition(.init(duration: 1, delay: 0, easing: .linear), at: now)
    try engine.run(direction: .aToB, at: now)
    let action = engine.nextAction(at: now)
    #expect(action.signedPulses == 160)
    engine.requestStop(at: now + 0.001)
    now += 0.02
    engine.complete(runID: action.runID, commandID: 0, outcome: outcome, at: now)
    #expect(engine.state(at: now).referenceValid == (outcome == 0))
    #expect(engine.state(at: now).stepPosition == (outcome == 0 ? 10 : nil))
    #expect(engine.nextAction(at: now + 1).kind == "idle")
    engine.complete(runID: action.runID, commandID: 0, outcome: 0, at: now + 0.01)
    #expect(engine.state(at: now).stepPosition == (outcome == 0 ? 10 : nil))
}

@Test func rackOptionalFineCalibrationMeasuresExactTripsWithoutGatingPlayback() throws {
    var (engine, now) = try adaptiveEngineWithMarks(100, profile: .calibratedFineExperiment)
    let marks = engine.currentProgram.marks
    engine.recordSafetyRead(startedAt: now - 0.08, finishedAt: now, accepted: true)
    try engine.setTransition(.init(duration: 1), at: now)
    #expect(engine.state(at: now).admissionMessage == nil)
    #expect(engine.state(at: now).pullAToB?.enabled == true)
    #expect(engine.state(at: now).pullBToA?.enabled == false)
    try engine.run(direction: .aToB, at: now)
    #expect(try settleAdaptive(&engine, now: &now) == Array(repeating: 160, count: 10))
    #expect(engine.state(at: now).pullBToA?.enabled == true)
    try engine.run(direction: .bToA, at: now)
    #expect(try settleAdaptive(&engine, now: &now) == Array(repeating: -160, count: 10))
    for (stage, quantum) in [2, 2, 3, 3, 4, 4, 6, 6, 8, 8].enumerated() {
        let state = engine.state(at: now)
        #expect(state.calibration?.enabled == true)
        #expect(state.calibration?.detail == "\(quantum * 16)-pulse increments · \(stage + 1)/10")
        try engine.calibrate(at: now)
        #expect(engine.state(at: now).calibration?.enabled == false)
        let pulses = try settleAdaptive(&engine, now: &now, commandDuration: 0.06)
        let sign = stage.isMultiple(of: 2) ? 1 : -1
        let expected =
            Array(repeating: sign * quantum * 16, count: 100 / quantum)
            + (100 % quantum == 0 ? [] : [sign * (100 % quantum) * 16])
        #expect(pulses == expected)
        #expect(pulses.reduce(0, +) == sign * 1_600)
        #expect(engine.state(at: now).stepPosition == (sign == 1 ? 100 : 0))
        #expect(engine.currentProgram.marks == marks)
    }
    #expect(engine.state(at: now).calibration?.title == "Calibration measured")
    #expect(engine.state(at: now).calibration?.enabled == false)
    for duration in [1.0, 3.0, 5.0] {
        try engine.setTransition(.init(duration: duration), at: now)
        try engine.run(direction: .aToB, at: now)
        let pulses = try settleAdaptive(&engine, now: &now, commandDuration: 0.06)
        #expect(pulses.first == (duration == 1 ? 128 : (duration == 3 ? 64 : 32)))
        #expect(pulses.reduce(0, +) == 1_600)
        #expect(engine.state(at: now).phase == .complete)
        try engine.seek(markID: "A", at: now)
        #expect(try settleAdaptive(&engine, now: &now).allSatisfy { $0 == -160 })
    }
}

@Test func rackFineCalibrationDoesNotCreditCancelledOrWrongDirectionTrips() throws {
    var (engine, now) = try adaptiveEngineWithMarks(100, profile: .calibratedFineExperiment)
    try engine.calibrate(at: now)
    let first = engine.nextAction(at: now)
    engine.requestStop(at: now + 0.001)
    now += 0.06
    engine.complete(runID: first.runID, commandID: 0, outcome: 0, at: now)
    #expect(engine.state(at: now).stepPosition == 2)
    #expect(engine.state(at: now).calibration?.detail == "32-pulse increments · 1/10")
    #expect(engine.state(at: now).calibration?.enabled == false)
    engine.observe(adaptiveContext(now), at: now)
    try engine.seek(markID: "A", at: now)
    try settleAdaptive(&engine, now: &now)
    try engine.calibrate(at: now)
    try settleAdaptive(&engine, now: &now)
    #expect(engine.state(at: now).calibration?.detail == "32-pulse increments · 2/10")
    try engine.seek(markID: "A", at: now)
    try settleAdaptive(&engine, now: &now)
    #expect(engine.state(at: now).calibration?.enabled == false)
    #expect(throws: FocusRackError.notAtStart) { try engine.calibrate(at: now) }
    try engine.seek(markID: "B", at: now)
    try settleAdaptive(&engine, now: &now)
    try engine.calibrate(at: now)
    try settleAdaptive(&engine, now: &now)
    #expect(engine.state(at: now).calibration?.detail == "48-pulse increments · 3/10")
    try engine.capture(markID: "A", at: now)
    #expect(engine.state(at: now).calibration?.detail == "32-pulse increments · 1/10")
}

@Test func rackPartialCalibrationAddsMeasuredChoicesWithoutAssumingResidualTiming() throws {
    var timings = [6: timing(0.06), 10: timing(0.08)]
    func plan(_ duration: Double) throws -> FocusRackMovementPlan {
        try FocusRackPlanner.make(
            signedSteps: 100, duration: duration, delay: 0, easing: .linear,
            quiet: 0, timings: timings, adaptive: true, timed: true, grouped: true,
            profile: .calibratedFineExperiment, safetyReadBudget: 0.1)
    }
    #expect(try plan(1).chunks == Array(repeating: 10, count: 10))
    // The finer 3s family cannot be replaced with unqualified coarse ordinary moves.
    #expect(throws: FocusRackError.noSmoothTiming) { try plan(3) }
    timings[4] = timing(0.06)
    #expect(try plan(3).chunks.contains(4))
    #expect(try plan(5).chunks.contains(4))
    timings[6] = timing(0.4)
    #expect(try plan(3).chunks.allSatisfy { abs($0) == 4 })
}

@Test(arguments: [1.0, 3.0, 5.0])
func rackMeasuredFinePlanningRetainsWorstCostsAndReservesSafetySlots(duration: Double) throws {
    let timings = [
        1: timing(0.210), 2: timing(0.06), 3: timing(0.06), 4: timing(0.06),
        6: timing(0.06), 8: timing(0.06), 10: timing(0.09),
    ]
    for sign in [-1, 1] {
        let plan = try FocusRackPlanner.make(
            signedSteps: sign * 100, duration: duration, delay: 0, easing: .linear,
            quiet: 0, timings: timings, adaptive: true, timed: true, grouped: true,
            profile: .calibratedFineExperiment, safetyReadBudget: 0.1)
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
func rackGrowingReadBudgetStopsBeforeTheNextActivation(afterFirstCommand: Bool) throws {
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
    #expect(engine.nextAction(at: now).kind == "idle")
    #expect(engine.state(at: now).phase == .failed)
    #expect(engine.state(at: now).stepPosition == acknowledged)
    #expect(engine.state(at: now).referenceValid)
    #expect(
        engine.snapshot(at: now, includeEvents: true).events.last?.kind
            == "maintenanceBudgetExceeded")
}

@Test func rackCountdownRefreshCanKeepAOneSecondFinePullWithinFreshEvidence() throws {
    var (engine, now) = try adaptiveEngineWithMarks(100, profile: .calibratedFineExperiment)
    for _ in 0..<10 {
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
    var (engine, now) = try adaptiveEngineWithMarks(100, profile: .calibratedFineExperiment)
    for _ in 0..<10 {
        try engine.calibrate(at: now)
        try settleAdaptive(&engine, now: &now, commandDuration: 0.06)
    }
    let marks = engine.currentProgram.marks
    engine.recordSafetyRead(startedAt: now - 1.328, finishedAt: now, accepted: true)
    // A short pull still needs actual preflight qualification, not a future idle-read slot.
    try engine.setTransition(.init(duration: 1), at: now)
    #expect(engine.state(at: now).admissionMessage == nil)
    try engine.setTransition(.init(duration: 3), at: now)
    #expect(engine.state(at: now).admissionMessage != nil)
    engine.recordSafetyRead(startedAt: now - 0.06, finishedAt: now, accepted: true)
    #expect(engine.safetyReadBudget == 0.1)
    for duration in [1.0, 3.0, 5.0] {
        try engine.setTransition(.init(duration: duration), at: now)
        #expect(engine.state(at: now).admissionMessage == nil)
    }
    #expect(engine.currentProgram.marks == marks)
    #expect(engine.state(at: now).calibration?.title == "Calibration measured")
    let read = try #require(
        engine.snapshot(at: now, includeEvents: true).events.last { $0.kind == "safetyRead" })
    let worst = try #require(
        read.note?.split(separator: " ").first { $0.hasPrefix("worst=") })
    #expect(abs(try #require(Double(worst.dropFirst(6))) - 1.328) < 1e-9)
    try engine.setTransition(.init(duration: 1), at: now)
    try engine.run(direction: .aToB, at: now)
    let pulses = try settleAdaptive(&engine, now: &now, commandDuration: 0.06)
    #expect(pulses == Array(repeating: 128, count: 12) + [64])
    #expect(engine.state(at: now).phase == .complete)
}

@Test func rackActualSlowPreflightRefusesAShortPullBeforeActivation() throws {
    var (engine, now) = try adaptiveEngineWithMarks(100, profile: .calibratedFineExperiment)
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
    #expect(engine.nextAction(at: now).kind == "idle")
    #expect(engine.state(at: now).phase == .failed)
    #expect(engine.state(at: now).stepPosition == 0)
    #expect(engine.state(at: now).referenceValid)
    #expect(
        !engine.snapshot(at: now, includeEvents: true).events.contains {
            $0.runID == run && $0.kind == "commandStarted"
        })
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

@Test(arguments: [8, 106])
func rackFineCalibrationUsesTheActualSharpMarkSpan(span: Int) throws {
    var (engine, now) = try adaptiveEngineWithMarks(
        span, profile: .calibratedFineExperiment, seekToA: false)
    let marks = engine.currentProgram.marks
    engine.recordSafetyRead(startedAt: now - 0.06, finishedAt: now, accepted: true)
    for (stage, quantum) in [2, 2, 3, 3, 4, 4, 6, 6, 8, 8].enumerated() {
        #expect(engine.state(at: now).calibration?.enabled == true)
        try engine.calibrate(at: now)
        let pulses = try settleAdaptive(&engine, now: &now, commandDuration: 0.06)
        let sign = stage.isMultiple(of: 2) ? -1 : 1
        let expected =
            Array(repeating: sign * quantum * 16, count: span / quantum)
            + (span % quantum == 0 ? [] : [sign * (span % quantum) * 16])
        #expect(pulses == expected)
        #expect(pulses.contains(sign * quantum * 16))
        #expect(pulses.reduce(0, +) == sign * span * 16)
        #expect(engine.state(at: now).stepPosition == (sign == 1 ? span : 0))
        #expect(engine.currentProgram.marks == marks)
    }
    #expect(engine.state(at: now).calibration?.title == "Calibration measured")
    guard span == 106 else { return }
    for duration in [1.0, 3.0, 5.0] {
        try engine.setTransition(.init(duration: duration), at: now)
        for direction in [FocusRackDirection.bToA, .aToB] {
            try engine.run(direction: direction, at: now)
            let pulses = try settleAdaptive(&engine, now: &now, commandDuration: 0.06)
            let sign = direction == .aToB ? 1 : -1
            let expectedFirst = duration == 1 ? 128 : (duration == 3 ? 64 : 32)
            #expect(pulses.first == sign * expectedFirst)
            #expect(pulses.reduce(0, +) == sign * 1_696)
            #expect(engine.state(at: now).phase == .complete)
            #expect(engine.currentProgram.marks == marks)
        }
    }
}

@Test func rackCalibrationCannotClaimAQuantumLargerThanItsMarkSpan() throws {
    var (engine, now) = try adaptiveEngineWithMarks(7, profile: .calibratedFineExperiment)
    #expect(engine.state(at: now).calibration == nil)
    #expect(throws: FocusRackError.referenceUnavailable) { try engine.calibrate(at: now) }
}

@Test func rackNonHundredUnitPlansStillRequireMeasuredResidualCommands() throws {
    var timings = [1: timing(0.06), 8: timing(0.068), 10: timing(0.06)]
    func plan() throws -> FocusRackMovementPlan {
        try FocusRackPlanner.make(
            signedSteps: 106, duration: 1, delay: 0, easing: .linear,
            quiet: 0, timings: timings, adaptive: true, timed: true, grouped: true,
            profile: .calibratedFineExperiment, safetyReadBudget: 0.1)
    }
    let fine = try plan()
    #expect(fine.chunks.allSatisfy { abs($0) == 1 })
    #expect(fine.duration > 1)
    timings[2] = timing(0.06)
    #expect(try plan().chunks == Array(repeating: 8, count: 13) + [2])
    timings[2] = timing(0.128)
    let slowerResidual = try plan()
    #expect(slowerResidual.chunks == Array(repeating: 8, count: 13) + [2])
    #expect(slowerResidual.duration > 1)
}
