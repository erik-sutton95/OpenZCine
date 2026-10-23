import Foundation
import Testing

@testable import OpenZCineCore

// Saved native maxima, including the slow 128-pulse observation. Synthetic camera identity only.
let jointRackMaxima: [Int: Double] = [
    16: 0.21372308325953782, 32: 0.12446125014685094, 48: 0.08745091664604843,
    64: 0.11623549996875226, 96: 0.08870562491938472, 128: 0.10687066667014733,
    160: 0.07956708315759897,
]

private let phoneJointMaxima: [Int: Double] = [
    16: 0.21372308325953782, 32: 0.12446125014685094, 48: 0.11696191667579114,
    64: 0.12687424989417195, 96: 0.08870562491938472, 128: 0.10687066667014733,
    160: 0.08087966684252024, 192: 0.0732764583081007,
]

private func jointTimings() -> [Int: FocusRackCommandTiming] {
    jointRackMaxima.reduce(into: [:]) { result, item in
        var timing = FocusRackCommandTiming()
        timing.record(item.value)
        result[item.key / 16] = timing
    }
}

private func jointPlan(_ steps: Int = 100, duration: Double = 3, delay: Double = 0) throws
    -> FocusRackMovementPlan
{
    try FocusRackPlanner.make(
        signedSteps: steps, duration: duration, delay: delay, easing: .linear, quiet: 0,
        timings: jointTimings(), adaptive: true, timed: true, grouped: true,
        profile: .calibratedFineExperiment, safetyReadBudget: 0.1)
}

@Test(arguments: [100, -100, 106, -106])
func rackJointPlanUsesSmallerMeasuredMovesAndExplicitFreshReadWindows(steps: Int) throws {
    let plan = try jointPlan(steps, delay: 0.7)
    let reads = try #require(plan.maintenanceReadOffsets)
    #expect(plan.chunks.reduce(0, +) == steps)
    #expect(
        plan.chunks.allSatisfy {
            $0.signum() == steps.signum() && jointRackMaxima[abs($0) * 16] != nil
        })
    #expect(plan.chunks.filter { abs($0) == 4 }.count >= 21)
    #expect(plan.chunks.map(abs).max() == 8)
    #expect(reads.count == 1)
    var safetyAt = plan.delay - 0.1
    for index in plan.chunks.indices {
        let due = plan.offsets[index]
        if let read = reads[index] {
            #expect(index > 0)
            let previousFinish =
                plan.offsets[index - 1] + (jointRackMaxima[abs(plan.chunks[index - 1]) * 16] ?? 0)
            #expect(read + 1e-9 >= previousFinish)
            #expect(read + 0.1 <= due + 1e-9)
            #expect(due - read - 0.1 >= 0.002 - 1e-9)
            #expect(read + 0.1 <= safetyAt + 2)
            safetyAt = read
        }
        let finish = due + (jointRackMaxima[abs(plan.chunks[index]) * 16] ?? 0)
        #expect(finish <= safetyAt + 2)
        if index + 1 < plan.chunks.count {
            let gap = plan.offsets[index + 1] - due
            #expect(finish <= plan.offsets[index + 1] + 1e-9)
            if reads[index + 1] == nil {
                #expect(plan.offsets[index + 1] - finish >= 0.002 - 1e-9)
            }
            #expect(gap <= FocusRackPlanner.maximumFineSpacing + 1e-9)
        } else {
            #expect(abs(finish - plan.delay - plan.duration) < 1e-9)
        }
    }
    if abs(steps) == 100 { #expect(plan.chunks.count == 23) }
}

@Test func rackJointSearchRejectsInvalidOrUnboundedRequestsAndKeepsShortPlanning() throws {
    for steps in [Int.min, 0, 10_001] {
        #expect(throws: FocusRackError.invalidConfiguration) { try jointPlan(steps) }
    }
    for duration in [Double.infinity, Double.nan, 0] {
        #expect(throws: FocusRackError.invalidConfiguration) { try jointPlan(duration: duration) }
    }
    #expect(throws: FocusRackError.self) { try jointPlan(duration: Double.greatestFiniteMagnitude) }
    #expect(try jointPlan(duration: 1.5).maintenanceReadOffsets == nil)
    for span in [10_000, -10_000] {
        let plan = try jointPlan(span, duration: 300)
        #expect(plan.chunks.reduce(0, +) == span)
        #expect(plan.chunks.count <= abs(span))
        #expect(plan.maintenanceReadOffsets?.isEmpty == false)
    }
}

private func jointContext(_ now: Double, safetyAt: Double) -> FocusRackContext {
    .init(
        sessionID: "synthetic-joint-session", connected: true, movieMode: true,
        foregroundOwner: true, focusMode: "AF-S",
        focus: .init(
            trackingAFActive: false, subjectDetectionActive: false, boxCount: 0,
            selectedBoxIndex: nil),
        frameTimestamp: now, safetyTimestamp: safetyAt, focusSettled: true,
        lens: "synthetic-lens", focalLength: "70", recording: false,
        frameSequence: Int64(now * 1_000_000), focusArea: "Single-point AF", focusSubject: "Off")
}

private func jointEngine(
    duration: Double = 3, span: Int = 100, maxima: [Int: Double] = jointRackMaxima
) throws -> (FocusRackEngine, Double) {
    var engine = try FocusRackEngine(
        configuration: FocusRackEngine.productionConfiguration, adaptive: true,
        profile: .calibratedFineExperiment)
    var now = 0.0
    engine.observe(jointContext(now, safetyAt: now), at: now)
    try engine.capture(markID: "A", at: now)
    var remaining = span
    while remaining > 0 {
        let steps = min(10, remaining)
        try engine.nudge(towardNear: false, steps: steps, at: now)
        while engine.snapshot(at: now).busy {
            engine.observe(jointContext(now, safetyAt: now), at: now)
            let action = engine.nextAction(at: now)
            #expect(action.kind == "drive")
            now += 0.02
            engine.complete(
                runID: action.runID, commandID: try #require(action.commandID), outcome: 0, at: now)
        }
        now += 0.01
        engine.observe(jointContext(now, safetyAt: now), at: now)
        remaining -= steps
    }
    try engine.capture(markID: "B", at: now)
    let key = try #require(
        FocusRackCalibrationKey(
            cameraID: "synthetic-body", transport: "usb", context: jointContext(now, safetyAt: now))
    )
    engine.bindCalibrationKey(key, at: now)
    engine.restoreCalibration(.init(key: key, commandDurations: maxima), at: now)
    engine.recordSafetyRead(startedAt: now - 0.099, finishedAt: now, accepted: true)
    try engine.setTransition(.init(duration: duration), at: now)
    try engine.run(direction: .bToA, at: now)
    engine.finishPreflight(runID: engine.state(at: now).runID, at: now)
    engine.observe(jointContext(now, safetyAt: now - 0.099), at: now)
    return (engine, now)
}

@Test(arguments: [0.1, 0.12])
func rackJointEngineCompletesWithActualEvidenceAndReadGrowthThatFits(readCost: Double) throws {
    var (engine, now) = try jointEngine()
    let epoch = now
    var safetyAt = now - 0.099
    var pulses = 0
    var reads = 0
    for _ in 0..<200 where engine.snapshot(at: now).busy {
        engine.observe(jointContext(now, safetyAt: safetyAt), at: now)
        let action = engine.nextAction(at: now)
        switch action.kind {
        case "drive":
            let command = try #require(action.signedPulses)
            pulses += command
            now += try #require(jointRackMaxima[abs(command)])
            engine.complete(
                runID: action.runID, commandID: try #require(action.commandID), outcome: 0, at: now)
        case "readSafety":
            reads += 1
            safetyAt = now
            now += readCost
            engine.recordSafetyRead(startedAt: safetyAt, finishedAt: now, accepted: true)
            engine.observe(jointContext(now, safetyAt: safetyAt), at: now)
            engine.finishScheduledRead(
                runID: action.runID, commandID: try #require(action.commandID), accepted: true,
                at: now)
        default: now += try #require(action.waitSeconds)
        }
    }
    #expect(engine.snapshot(at: now).phase == "complete")
    #expect(engine.snapshot(at: now).stepPosition == 0)
    #expect(pulses == -1600)
    #expect(reads == 1)
    #expect(abs(now - epoch - 3) < 1e-9)
    for (pulses, maximum) in jointRackMaxima {
        #expect(abs((engine.calibrationTimings[pulses] ?? 0) - maximum) < 1e-9)
    }
}

@Test(arguments: ["stop", "late", "rejected", "pause", "frame"])
func rackJointReadSettlementCannotUnlockUnsafeOrRetiredMovement(reason: String) throws {
    var (engine, now) = try jointEngine()
    var safetyAt = now - 0.099
    var held: FocusRackEngineAction?
    for _ in 0..<150 {
        engine.observe(jointContext(now, safetyAt: safetyAt), at: now)
        let action = engine.nextAction(at: now)
        if action.kind == "readSafety" {
            held = action
            break
        }
        if action.kind == "drive" {
            let pulses = try #require(action.signedPulses)
            now += try #require(jointRackMaxima[abs(pulses)])
            engine.complete(
                runID: action.runID, commandID: try #require(action.commandID), outcome: 0, at: now)
        } else {
            now += try #require(action.waitSeconds)
        }
    }
    let action = try #require(held)
    let position = engine.snapshot(at: now).stepPosition
    let started = now
    if reason == "stop" { engine.requestStop(at: now) }
    if reason == "pause" { engine.requestPause(at: now) }
    now += reason == "late" ? 0.2 : 0.1
    safetyAt = started
    engine.recordSafetyRead(startedAt: started, finishedAt: now, accepted: reason != "rejected")
    var context = jointContext(now, safetyAt: safetyAt)
    if reason == "frame" { context.frameTimestamp = now - 3 }
    engine.observe(context, at: now)
    engine.finishScheduledRead(
        runID: action.runID, commandID: try #require(action.commandID),
        accepted: reason != "rejected", at: now)
    #expect(engine.nextAction(at: now).kind != "drive")
    if reason != "frame" { #expect(engine.snapshot(at: now).stepPosition == position) }
    if reason == "late" || reason == "rejected" {
        #expect(engine.snapshot(at: now).phase == "failed")
    }
    if reason == "pause" {
        // Real wall-clock freshness is not extended along with the trajectory epoch.
        now += 3
        engine.observe(jointContext(now, safetyAt: safetyAt), at: now)
        #expect(throws: FocusRackError.referenceUnavailable) { try engine.resume(at: now) }
    }
}

@Test(arguments: ["native", "late"])
func rackJointGrowthOrLatenessFailsBeforeAnotherActivationAndKeepsKnownPosition(cause: String)
    throws
{
    var (engine, now) = try jointEngine()
    let first = engine.nextAction(at: now)
    #expect(first.kind == "drive")
    let pulses = try #require(first.signedPulses)
    now += try #require(jointRackMaxima[abs(pulses)]) + (cause == "native" ? 0.03 : 0)
    engine.complete(
        runID: first.runID, commandID: try #require(first.commandID), outcome: 0, at: now)
    now = try #require(engine.nextCommandDeadline) + (cause == "late" ? 0.25 : 0)
    engine.observe(jointContext(now, safetyAt: now), at: now)
    let position = engine.snapshot(at: now).stepPosition
    #expect(engine.nextAction(at: now).kind == "idle")
    #expect(engine.snapshot(at: now).phase == "failed")
    #expect(engine.snapshot(at: now).stepPosition == position)
    #expect(engine.state(at: now).referenceValid)
    #expect(engine.calibrationTimings[abs(pulses)] ?? 0 >= jointRackMaxima[abs(pulses)] ?? 0)
}

@Test func rackJointSlowPreflightRefusesBeforeAnyActivation() throws {
    var (engine, now) = try jointEngine()
    let run = engine.snapshot(at: now).runID
    let start = now
    now += 0.2
    engine.recordSafetyRead(startedAt: start, finishedAt: now, accepted: true)
    engine.observe(jointContext(now, safetyAt: start), at: now)
    engine.finishPreflight(runID: run, at: now)
    #expect(engine.nextAction(at: now).kind == "idle")
    #expect(engine.snapshot(at: now).phase == "failed")
    #expect(engine.snapshot(at: now).stepPosition == 100)
    #expect(engine.state(at: now).referenceValid)
}

@Test func rackJointReadMeetingItsDeadlineStillRejectsInfeasibleLaterWindows() throws {
    // All gaps have room for 160ms reads, but a later read-to-read interval plus
    // that grown cost exceeds the unchanged 2s evidence lifetime.
    let maxima = [16: 0.13, 32: 0.06]
    var (engine, now) = try jointEngine(duration: 6.75, span: 60, maxima: maxima)
    var safetyAt = now - 0.099
    for _ in 0..<500 {
        engine.observe(jointContext(now, safetyAt: safetyAt), at: now)
        let action = engine.nextAction(at: now)
        if action.kind == "drive" {
            let pulses = try #require(action.signedPulses)
            now += try #require(maxima[abs(pulses)])
            engine.complete(
                runID: action.runID, commandID: try #require(action.commandID), outcome: 0, at: now)
        } else if action.kind == "readSafety" {
            let step = try #require(action.commandID)
            let position = engine.snapshot(at: now).stepPosition
            let deadline = try #require(engine.nextCommandDeadline)
            safetyAt = now
            now += 0.16
            engine.recordSafetyRead(startedAt: safetyAt, finishedAt: now, accepted: true)
            engine.observe(jointContext(now, safetyAt: safetyAt), at: now)
            engine.finishScheduledRead(
                runID: action.runID, commandID: step, accepted: true, at: now)
            #expect(step == 7)
            #expect(now < deadline)
            #expect(engine.snapshot(at: now).phase == "failed")
            #expect(engine.nextAction(at: now).kind == "idle")
            #expect(engine.snapshot(at: now).stepPosition == position)
            #expect(engine.state(at: now).referenceValid)
            return
        } else {
            now += try #require(action.waitSeconds)
        }
    }
    Issue.record("Expected to reach the selected maintenance window")
}

@Test func rackJointPauseUsesFreshWallClockEvidenceAndOldReadCannotCompleteANewRun() throws {
    var (engine, now) = try jointEngine()
    let first = engine.nextAction(at: now)
    let oldRun = first.runID
    now += 0.0874
    engine.complete(runID: oldRun, commandID: try #require(first.commandID), outcome: 0, at: now)
    engine.requestPause(at: now)
    let position = engine.snapshot(at: now).stepPosition
    now += 4
    engine.observe(jointContext(now, safetyAt: now - 0.1), at: now)
    try engine.resume(at: now)
    #expect(engine.snapshot(at: now).stepPosition == position)
    let next = engine.nextAction(at: now)
    #expect(next.kind == "wait")
    now += try #require(next.waitSeconds)
    engine.observe(jointContext(now, safetyAt: now - 0.1), at: now)
    #expect(engine.nextAction(at: now).kind == "drive")
    engine.requestStop(at: now)
    now += 0.0874
    engine.complete(runID: oldRun, commandID: 1, outcome: 0, at: now)
    engine.observe(jointContext(now, safetyAt: now), at: now)
    try engine.seek(markID: "B", at: now)
    let newRun = engine.snapshot(at: now).runID
    engine.finishScheduledRead(runID: oldRun, commandID: 1, accepted: true, at: now + 10)
    #expect(engine.snapshot(at: now).runID == newRun)
    #expect(engine.snapshot(at: now).busy)
    #expect(engine.nextAction(at: now).kind == "drive")
}

@Test(arguments: [0.0032, 0.01])
func rackJointSixSecondReplayAllowsObservedWakeLatenessAndStillStopsExcessiveDelay(
    wakeLateness: Double
) throws {
    // Captured iPhone maxima. The old 6s plan left only 1.311ms between its
    // reserved native cost and the next fixed deadline; observed wakes reached 3.091ms.
    let maxima = phoneJointMaxima
    var (engine, now) = try jointEngine(duration: 6, maxima: maxima)
    var safetyAt = now - 0.099
    for direction in [FocusRackDirection.bToA, .aToB] {
        if direction == .aToB {
            try engine.run(direction: direction, at: now)
            engine.finishPreflight(runID: engine.snapshot(at: now).runID, at: now)
        }
        var delivered = 0
        for _ in 0..<500 where engine.snapshot(at: now).busy {
            engine.observe(jointContext(now, safetyAt: safetyAt), at: now)
            let action = engine.nextAction(at: now)
            switch action.kind {
            case "drive":
                let pulses = try #require(action.signedPulses)
                delivered += pulses
                now += try #require(maxima[abs(pulses)])
                engine.complete(
                    runID: action.runID, commandID: try #require(action.commandID), outcome: 0,
                    at: now)
            case "readSafety":
                safetyAt = now
                now += 0.1
                engine.recordSafetyRead(startedAt: safetyAt, finishedAt: now, accepted: true)
                engine.observe(jointContext(now, safetyAt: safetyAt), at: now)
                engine.finishScheduledRead(
                    runID: action.runID, commandID: try #require(action.commandID), accepted: true,
                    at: now)
            case "wait": now += try #require(action.waitSeconds) + wakeLateness
            default: break
            }
        }
        #expect(engine.state(at: now).referenceValid)
        for (pulses, maximum) in maxima {
            #expect(engine.calibrationTimings[pulses] ?? 0 >= maximum)
        }
        if wakeLateness > 0.0032 {
            #expect(engine.snapshot(at: now).phase == "failed")
            #expect(delivered == -32)
            #expect(engine.snapshot(at: now).stepPosition == 98)
            return
        }
        #expect(engine.snapshot(at: now).phase == "complete")
        #expect(delivered == (direction == .bToA ? -1600 : 1600))
        #expect(engine.snapshot(at: now).stepPosition == (direction == .bToA ? 0 : 100))
        safetyAt = now
        engine.observe(jointContext(now, safetyAt: safetyAt), at: now)
    }
}

@Test func rackJointProfilesKeepFineThreeSecondsAndTheSixSecondHeadroomFix()
    throws
{
    let timings = phoneJointMaxima.reduce(into: [Int: FocusRackCommandTiming]()) { result, item in
        var timing = FocusRackCommandTiming()
        timing.record(item.value)
        result[item.key / 16] = timing
    }
    for steps in [100, -100] {
        var profiles: [Double: [Int]] = [:]
        for duration in [1.0, 3, 6] {
            let plan = try FocusRackPlanner.make(
                signedSteps: steps, duration: duration, delay: 0, easing: .linear, quiet: 0,
                timings: timings, adaptive: true, timed: true, grouped: true,
                profile: .calibratedFineExperiment, safetyReadBudget: 0.1)
            #expect(plan.chunks.reduce(0, +) == steps)
            profiles[duration] = plan.chunks.map { abs($0) * 16 }
        }
        #expect(profiles[1] == Array(repeating: 160, count: 10))
        #expect(
            profiles[3] == Array(repeating: 64, count: 11) + [128]
                + Array(repeating: 64, count: 10) + [128])
        #expect(profiles[6]?.count == 44)
        #expect(profiles[6]?.filter { $0 == 32 }.count == 40)
        #expect(profiles[6]?.filter { $0 == 64 }.count == 3)
        #expect(profiles[6]?.last == 128)
    }
}

@Test(arguments: [1.0, 3.0], [100, 110, 300])
func rackTargetDurationExecutesBothDirectionsWithCapturedPhoneCosts(
    duration: Double, span: Int
) throws {
    var maxima = phoneJointMaxima
    maxima[160] = 0.09154454153031111
    var (engine, now) = try jointEngine(duration: duration, span: span, maxima: maxima)
    var safetyAt = now - 0.099
    for direction in [FocusRackDirection.bToA, .aToB] {
        if direction == .aToB {
            try engine.run(direction: direction, at: now)
            engine.finishPreflight(runID: engine.snapshot(at: now).runID, at: now)
        }
        let planned = try #require(engine.state(at: now).estimatedDuration)
        #expect(engine.state(at: now).transition.duration == duration)
        #expect(planned >= duration)
        var delivered = 0
        var periodicReads = 0
        for _ in 0..<500 where engine.snapshot(at: now).busy {
            // Mirror the controller's periodic-read fallback with real elapsed read cost.
            // Never refresh safety for free, or borrow time beyond the next command deadline.
            if !engine.ownsMaintenanceSchedule(at: now), now - safetyAt >= 0.5,
                let deadline = engine.nextCommandDeadline, now + 0.1 <= deadline
            {
                safetyAt = now
                now += 0.1
                periodicReads += 1
                engine.recordSafetyRead(startedAt: safetyAt, finishedAt: now, accepted: true)
            }
            engine.observe(jointContext(now, safetyAt: safetyAt), at: now)
            let action = engine.nextAction(at: now)
            switch action.kind {
            case "drive":
                let pulses = try #require(action.signedPulses)
                delivered += pulses
                now += try #require(maxima[abs(pulses)])
                engine.complete(
                    runID: action.runID, commandID: try #require(action.commandID),
                    outcome: 0, at: now)
            case "readSafety":
                safetyAt = now
                now += 0.1
                engine.recordSafetyRead(startedAt: safetyAt, finishedAt: now, accepted: true)
                engine.observe(jointContext(now, safetyAt: safetyAt), at: now)
                engine.finishScheduledRead(
                    runID: action.runID, commandID: try #require(action.commandID),
                    accepted: true, at: now)
            case "wait": now += try #require(action.waitSeconds) + 0.001
            default: break
            }
        }
        if duration == 1, span == 300 { #expect(periodicReads > 0) }
        #expect(engine.snapshot(at: now).phase == "complete")
        #expect(delivered == (direction == .bToA ? -span : span) * 16)
        #expect(engine.state(at: now).referenceValid)
        let actual = try #require(engine.snapshot(at: now).actualMovementDuration)
        #expect(abs(actual - planned) < 0.01)
        safetyAt = now
        engine.observe(jointContext(now, safetyAt: safetyAt), at: now)
    }
}

@Test(arguments: [false, true])
func rackPreflightReadGrowthReplansFineMovesOnlyBeforeActivation(stopped: Bool) throws {
    var (engine, now) = try jointEngine(maxima: phoneJointMaxima)
    let runID = engine.snapshot(at: now).runID
    let readStarted = now
    now += 0.14
    engine.recordSafetyRead(startedAt: readStarted, finishedAt: now, accepted: true)
    engine.observe(jointContext(now, safetyAt: readStarted), at: now)
    if stopped { engine.requestStop(at: now) }
    engine.finishPreflight(runID: runID, at: now)
    let action = engine.nextAction(at: now)
    if stopped {
        #expect(action.kind == "idle")
        #expect(!engine.snapshot(at: now).busy)
        return
    }
    #expect(action.kind == "drive")
    #expect(action.signedPulses == -64)
    #expect(engine.state(at: now).transition.duration == 3)
    #expect(engine.state(at: now).estimatedDuration ?? 0 >= 3)
    #expect(engine.snapshot(at: now).events.isEmpty)
    #expect(engine.snapshot(at: now, includeEvents: true).events.last?.kind == "commandStarted")
}
