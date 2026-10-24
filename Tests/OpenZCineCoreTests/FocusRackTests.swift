import Foundation
import Testing

@testable import OpenZCineCore

private func rackContext(at timestamp: Double = 0) -> FocusRackContext {
    .init(
        sessionID: "test-session", connected: true, movieMode: true, foregroundOwner: true,
        focusMode: "AF-S",
        focus: .init(
            trackingAFActive: false, subjectDetectionActive: false, boxCount: 1,
            selectedBoxIndex: nil), frameTimestamp: timestamp,
        safetyTimestamp: timestamp, focusSettled: true,
        lens: "synthetic lens", focalLength: "70", recording: false)
}

private func probeWithMarks(delay: Double = 0, duration: Double = 1) throws -> FocusRackEngine {
    var probe = try FocusRackEngine(
        configuration: .init(
            pulsesPerStep: 8, commandInterval: 0.08,
            transition: .init(duration: duration, delay: delay, easing: .linear)))
    probe.observe(rackContext(), at: 0)
    try probe.capture(markID: "A", at: 0)
    for index in 0..<3 {
        let now = Double(index) * 0.1
        probe.observe(rackContext(at: now), at: now)
        try probe.nudge(towardNear: false, at: now)
        let action = probe.nextAction(at: now)
        probe.complete(runID: action.runID, commandID: 0, outcome: 0, at: now + 0.01)
    }
    probe.observe(rackContext(at: 0.3), at: 0.3)
    try probe.capture(markID: "B", at: 0.3)
    return probe
}

@Test func rackTrajectoryKeepsTheIncrementAndChangesOnlyItsTiming() throws {
    let linear = try FocusRackTrajectory(
        signedSteps: 11, duration: 3, delay: 2, easing: .linear, commandInterval: 0.08)
    let smooth = try FocusRackTrajectory(
        signedSteps: -11, duration: 3, delay: 2, easing: .easeInOut, commandInterval: 0.08)
    #expect(linear.offsets.count == 11)
    #expect(smooth.offsets.count == 11)
    #expect(abs((smooth.offsets.first ?? 0) - 2) < 1e-9)
    #expect(abs((smooth.offsets.last ?? 0) - 4.92) < 1e-9)
    let linearGaps = zip(linear.offsets, linear.offsets.dropFirst()).map { $1 - $0 }
    let smoothGaps = zip(smooth.offsets, smooth.offsets.dropFirst()).map { $1 - $0 }
    #expect(abs(linearGaps[0] - linearGaps[4]) < 1e-9)
    #expect(smoothGaps[0] > smoothGaps[4])
    #expect(smoothGaps.allSatisfy { $0 >= 0.08 })
}

@Test func rackRejectsTimingsThatWouldFloodTheCommandChannel() {
    #expect(throws: FocusRackError.self) {
        try FocusRackTrajectory(
            signedSteps: 100, duration: 1, delay: 0, easing: .easeInOut, commandInterval: 0.08)
    }
    for invalid in [Double.nan, .infinity, -1, 0] {
        #expect(throws: FocusRackError.self) {
            try FocusRackTrajectory(
                signedSteps: 5, duration: invalid, delay: 0, easing: .linear, commandInterval: 0.08)
        }
    }
}

@Test func rackRejectsPretendLongSingleStepMoves() {
    #expect(throws: FocusRackError.marksTooClose) {
        try FocusRackTrajectory(
            signedSteps: 1, duration: 3, delay: 0, easing: .linear, commandInterval: 0.08)
    }
}

@Test func rackDispatchCadenceSurvivesRapidSeparateNudges() throws {
    var probe = try FocusRackEngine()
    probe.observe(rackContext(), at: 0)
    try probe.nudge(towardNear: false, at: 0)
    let first = probe.nextAction(at: 0)
    probe.complete(runID: first.runID, commandID: 0, outcome: 0, at: 0.001)
    try probe.nudge(towardNear: false, at: 0.002)
    #expect(probe.nextAction(at: 0.002).kind == "wait")
    #expect(probe.nextAction(at: 0.079).kind == "wait")
    #expect(probe.nextAction(at: 0.08).kind == "wait")
    #expect(probe.nextAction(at: 0.082).kind == "drive")
}

@Test func rackLateCompletionNeverCompressesTheNextCommandInterval() throws {
    var probe = try probeWithMarks(duration: 0.27)
    try probe.run(reverse: true, at: 0.3)
    let first = probe.nextAction(at: 0.3)
    probe.complete(runID: first.runID, commandID: 0, outcome: 0, at: 0.45)
    #expect(probe.nextAction(at: 0.45).kind == "wait")
    #expect(probe.nextAction(at: 0.52).kind == "wait")
    let second = probe.nextAction(at: 0.531)
    #expect(second.kind == "drive")
    probe.complete(runID: second.runID, commandID: 1, outcome: 0, at: 0.54)
    #expect(probe.nextAction(at: 0.61).kind == "wait")
    #expect(probe.nextAction(at: 0.66).kind == "wait")
    #expect(probe.nextAction(at: 0.662).kind == "drive")
}

@Test func rackPositioningWaitsForReadinessWithoutPretendingToBeATimedPull() throws {
    var probe = try probeWithMarks()
    try probe.seek(markID: "A", at: 0.3)
    probe.observe(rackContext(at: 0.8), at: 0.8)
    let first = probe.nextAction(at: 0.8)
    #expect(first.kind == "drive")
    probe.complete(runID: first.runID, commandID: 0, outcome: 0, at: 0.9)
    #expect(probe.nextAction(at: 0.9).kind == "wait")
    #expect(probe.nextAction(at: 0.979).kind == "wait")
    #expect(probe.nextAction(at: 0.981).kind == "drive")

    var nudge = try FocusRackEngine()
    nudge.observe(rackContext(), at: 0)
    try nudge.nudge(towardNear: false, at: 0)
    nudge.observe(rackContext(at: 0.5), at: 0.5)
    #expect(nudge.nextAction(at: 0.5).kind == "drive")

    var timed = try probeWithMarks()
    try timed.run(reverse: true, at: 0.3)
    timed.observe(rackContext(at: 0.8), at: 0.8)
    #expect(timed.nextAction(at: 0.8).kind == "drive")
    #expect(timed.snapshot(at: 0.8).phase == "moving")
}

@Test func rackInitialAutofocusRequiresSettlingAndASubsequentFrame() throws {
    var probe = try FocusRackEngine()
    probe.observe(rackContext(), at: 0)
    probe.externalFocusAction(at: 0.1)
    var context = rackContext(at: 0.2)
    context.focusSettled = false
    probe.observe(context, at: 0.2)
    #expect(!probe.snapshot(at: 0.2).canCapture)
    #expect(throws: FocusRackError.movementPending) { try probe.reset(at: 0.2) }
    context = rackContext(at: 0.3)
    probe.observe(context, at: 0.3)
    #expect(throws: FocusRackError.freshFrameRequired) { try probe.capture(markID: "A", at: 0.3) }
    probe.observe(rackContext(at: 0.4), at: 0.4)
    try probe.capture(markID: "A", at: 0.4)
    probe.externalFocusAction(at: 0.5)
    #expect(probe.snapshot(at: 0.5).stepPosition == nil)
}

@Test func rackOldUnconfirmedStopDoesNotTaintTheReplacementSession() throws {
    var probe = try FocusRackEngine()
    probe.observe(rackContext(), at: 0)
    try probe.nudge(towardNear: false, at: 0)
    let action = probe.nextAction(at: 0)
    var replacement = rackContext(at: 0.1)
    replacement.sessionID = "replacement"
    probe.observe(replacement, at: 0.1)
    probe.complete(runID: action.runID, commandID: 0, outcome: 4, at: 0.2)
    try probe.reset(at: 0.2)
    replacement.frameTimestamp = 0.3
    probe.observe(replacement, at: 0.3)
    #expect(probe.snapshot(at: 0.3).canCapture)
}

@Test func rackCannotResetAnUnconfirmedStopUntilReconnect() throws {
    var probe = try FocusRackEngine()
    probe.observe(rackContext(), at: 0)
    try probe.nudge(towardNear: false, at: 0)
    let first = probe.nextAction(at: 0)
    probe.requestStop(at: 0.01)
    probe.complete(runID: first.runID, commandID: 0, outcome: 4, at: 0.02)
    probe.observe(rackContext(at: 0.03), at: 0.03)
    #expect(throws: FocusRackError.reconnectRequired) { try probe.reset(at: 0.03) }
    #expect(probe.snapshot(at: 0.03).recoveryInstruction == "Reconnect camera, then reset marks.")
    var reconnected = rackContext(at: 0.04)
    reconnected.sessionID = "new-session"
    probe.observe(reconnected, at: 0.04)
    #expect(probe.snapshot(at: 0.04).recoveryInstruction == "Reset marks before moving focus.")
    try probe.reset(at: 0.04)
    #expect(probe.snapshot(at: 0.04).recoveryInstruction == nil)
    #expect(!probe.snapshot(at: 0.04).canCapture)
    reconnected.frameTimestamp = 0.05
    probe.observe(reconnected, at: 0.05)
    #expect(probe.snapshot(at: 0.05).canCapture)
}

@Test func rackRepeatedIdleInvalidationPreservesTheFirstEvidenceUntilReset() throws {
    var probe = try probeWithMarks()
    var changed = rackContext(at: 0.4)
    changed.sessionID = "replacement"
    for index in 0..<1_000 {
        let now = 0.4 + Double(index) * 0.001
        changed.frameTimestamp = now
        changed.safetyTimestamp = now
        probe.observe(changed, at: now)
    }
    let invalid = probe.snapshot(at: 1.4, includeEvents: true)
    #expect(invalid.stepPosition == nil)
    #expect(invalid.events.filter { $0.kind == "invalidated" }.count == 1)
    #expect(invalid.omittedEvents == 0)
    #expect(throws: FocusRackError.referenceUnavailable) {
        try probe.nudge(towardNear: false, at: 1.4)
    }
    #expect(throws: FocusRackError.referenceUnavailable) {
        try probe.capture(markID: "A", at: 1.4)
    }
    try probe.reset(at: 1.4)
    #expect(!probe.snapshot(at: 1.4).canCapture)
    changed.frameTimestamp = 1.5
    changed.safetyTimestamp = 1.5
    probe.observe(changed, at: 1.5)
    try probe.capture(markID: "A", at: 1.5)
    changed.connected = false
    probe.observe(changed, at: 1.6)
    let interruptedAgain = probe.snapshot(at: 1.6, includeEvents: true)
    #expect(interruptedAgain.stepPosition == 0)
    #expect(!interruptedAgain.canCapture)
    #expect(interruptedAgain.events.filter { $0.kind == "invalidated" }.count == 1)
}

@Test func rackRepeatedInflightInvalidationStopsOnceAndCannotRestorePosition() throws {
    var probe = try probeWithMarks()
    try probe.run(reverse: true, at: 0.3)
    let command = probe.nextAction(at: 0.3)
    for index in 0..<100 {
        probe.interrupt(reason: "External focus changed.", at: 0.31 + Double(index) * 0.0001)
    }
    let stopping = probe.snapshot(at: 0.33, includeEvents: true)
    #expect(stopping.phase == "stopping")
    #expect(stopping.events.filter { $0.kind == "stopRequested" }.count == 1)
    #expect(stopping.events.filter { $0.kind == "invalidated" }.count == 1)
    probe.complete(runID: command.runID, commandID: 0, outcome: 0, at: 0.4)
    #expect(probe.snapshot(at: 0.4).stepPosition == nil)
    #expect(probe.nextAction(at: 0.4).kind == "idle")
}

@Test(arguments: [4, 5])
func rackRepeatedInvalidationPreservesUnconfirmedNativeRecovery(outcome: Int) throws {
    var probe = try FocusRackEngine()
    probe.observe(rackContext(), at: 0)
    try probe.nudge(towardNear: false, at: 0)
    let command = probe.nextAction(at: 0)
    probe.complete(runID: command.runID, commandID: 0, outcome: outcome, at: 0.1)
    probe.observe(rackContext(at: 0.2), at: 0.2)
    let failed = probe.snapshot(at: 0.2)
    probe.interrupt(reason: "An additional stale observation.", at: 0.21)
    let repeated = probe.snapshot(at: 0.21, includeEvents: true)
    #expect(repeated.phase == failed.phase)
    #expect(repeated.message == failed.message)
    #expect(repeated.message.contains("Reconnect"))
    #expect(repeated.recoveryInstruction == "Reconnect camera, then reset marks.")
    #expect(repeated.events.filter { $0.kind == "invalidated" }.isEmpty)
    #expect(throws: FocusRackError.reconnectRequired) { try probe.reset(at: 0.21) }
}

@Test func rackCapturesOnlyAcknowledgedMovementAndFreshFrames() throws {
    var probe = try FocusRackEngine()
    probe.observe(rackContext(), at: 0)
    try probe.capture(markID: "A", at: 0)
    try probe.nudge(towardNear: false, at: 0)
    let command = probe.nextAction(at: 0)
    #expect(probe.snapshot(at: 0).stepPosition == 0)
    #expect(throws: FocusRackError.movementPending) { try probe.capture(markID: "B", at: 0) }
    probe.complete(runID: command.runID, commandID: 0, outcome: 0, at: 0.05)
    #expect(probe.snapshot(at: 0.05).stepPosition == 1)
    #expect(throws: FocusRackError.freshFrameRequired) { try probe.capture(markID: "B", at: 0.05) }
    probe.observe(rackContext(at: 0.1), at: 0.1)
    try probe.capture(markID: "B", at: 0.1)
    #expect(probe.snapshot(at: 0.1).marks.map(\.stepPosition) == [0, 1])
}

@Test func rackDelayAndRepositionAreExplicit() throws {
    var probe = try probeWithMarks(delay: 2)
    #expect(throws: FocusRackError.notAtStart) { try probe.run(reverse: false, at: 0.3) }
    try probe.run(reverse: true, at: 0.3)
    #expect(probe.nextAction(at: 0.3).kind == "wait")
    #expect(probe.snapshot(at: 0.3).phase == "countdown")
    probe.observe(rackContext(at: 2.3), at: 2.3)
    let action = probe.nextAction(at: 2.3)
    #expect(action.kind == "drive")
    #expect(action.signedPulses == -8)
}

@Test func rackStopDuringDelayNeverDrivesOrReturns() throws {
    var probe = try probeWithMarks(delay: 1)
    try probe.run(reverse: true, at: 0.3)
    probe.requestStop(at: 0.4)
    probe.observe(rackContext(at: 1.4), at: 1.4)
    #expect(probe.nextAction(at: 1.4).kind == "idle")
    #expect(probe.snapshot(at: 1.4).phase == "stopped")
    #expect(probe.snapshot(at: 1.4).stepPosition == 3)
}

@Test func rackCancelledPartialMovementInvalidatesBothMarks() throws {
    var probe = try probeWithMarks()
    try probe.run(reverse: true, at: 0.3)
    let command = probe.nextAction(at: 0.3)
    probe.requestStop(at: 0.31)
    #expect(probe.snapshot(at: 0.31).phase == "stopping")
    #expect(probe.nextAction(at: 0.32).kind == "idle")
    probe.complete(runID: command.runID, commandID: 0, outcome: 3, at: 0.4)
    #expect(probe.snapshot(at: 0.4).stepPosition == nil)
    #expect(!probe.snapshot(at: 0.4).canCapture)
    #expect(throws: FocusRackError.referenceUnavailable) {
        try probe.nudge(towardNear: true, at: 0.4)
    }
    try probe.reset(at: 0.4)
    #expect(probe.snapshot(at: 0.4).marks.isEmpty)
    #expect(probe.snapshot(at: 0.4).stepPosition == 0)
}

@Test func rackStopKeepsPositionWhenTheWholeChunkSettles() throws {
    var probe = try probeWithMarks()
    try probe.run(reverse: true, at: 0.3)
    let command = probe.nextAction(at: 0.3)
    probe.requestStop(at: 0.31)
    probe.complete(runID: command.runID, commandID: 0, outcome: 0, at: 0.35)
    #expect(probe.snapshot(at: 0.35).phase == "stopped")
    #expect(probe.snapshot(at: 0.35).stepPosition == 2)
    #expect(probe.nextAction(at: 0.8).kind == "idle")
}

@Test func rackRejectsStaleCallbacksAndNeverAdvancesForInsufficientSteps() throws {
    var probe = try FocusRackEngine()
    probe.observe(rackContext(), at: 0)
    try probe.nudge(towardNear: false, at: 0)
    let command = probe.nextAction(at: 0)
    probe.complete(runID: command.runID - 1, commandID: 0, outcome: 0, at: 0.01)
    #expect(probe.snapshot(at: 0.01).busy)
    probe.complete(runID: command.runID, commandID: 0, outcome: 2, at: 0.02)
    #expect(probe.snapshot(at: 0.02).stepPosition == 0)
    #expect(probe.snapshot(at: 0.02).phase == "stepTooSmall")
}

@Test func rackRefusalDoesNotRetryButUnknownMovementLosesReference() throws {
    for outcome in [1, 4, 5, 0x12019] {
        var probe = try FocusRackEngine()
        probe.observe(rackContext(), at: 0)
        try probe.nudge(towardNear: false, at: 0)
        let command = probe.nextAction(at: 0)
        probe.complete(runID: command.runID, commandID: 0, outcome: outcome, at: 0.1)
        #expect(probe.nextAction(at: 0.2).kind == "idle")
        #expect(probe.snapshot(at: 0.2).stepPosition == (outcome >= 0x10000 ? 0 : nil))
    }
}

@Test func rackDoesNotBurstAfterMissingADeadline() throws {
    var probe = try probeWithMarks()
    try probe.run(reverse: true, at: 0.3)
    probe.observe(rackContext(at: 0.6), at: 0.6)
    let first = probe.nextAction(at: 0.6)
    #expect(first.kind == "drive")
    probe.complete(runID: first.runID, commandID: 0, outcome: 0, at: 0.61)
    #expect(probe.nextAction(at: 0.7).kind == "wait")
    #expect(probe.snapshot(at: 0.7).busy)
    #expect(probe.snapshot(at: 0.7).stepPosition == 2)
    probe.observe(rackContext(at: 1.096), at: 1.096)
    #expect(probe.nextAction(at: 1.096).kind == "drive")
}

@Test func rackRetainsIdleMarksWhileUnavailableAndWarnsForKnownSetupChanges() throws {
    for kind in [
        "zoom", "tracking", "metadata", "ownership", "session", "stale", "safety", "settling",
    ] {
        var probe = try probeWithMarks()
        var context = rackContext(at: 0.4)
        switch kind {
        case "zoom": context.focalLength = "100"
        case "tracking": context.focus?.trackingAFActive = true
        case "metadata": context.focus = nil
        case "ownership": context.foregroundOwner = false
        case "session": context.sessionID = "replacement"
        case "safety": context.safetyTimestamp = -10
        case "settling": context.focusSettled = false
        default: context.frameTimestamp = -10
        }
        probe.observe(context, at: 0.4)
        #expect(probe.snapshot(at: 0.4).marks.map(\.stepPosition) == [0, 3])
        #expect(probe.snapshot(at: 0.4).stepPosition == (kind == "session" ? nil : 3))
        #expect(probe.state(at: 0.4).capabilities.canNudge == (kind == "zoom"))
        if kind == "zoom" {
            #expect(probe.state(at: 0.4).message.contains("reset marks if needed"))
        } else {
            #expect(!probe.snapshot(at: 0.4).canCapture)
        }
    }
}

@Test func rackRecordingStopCancelsFutureMovement() throws {
    var probe = try probeWithMarks(delay: 1)
    var context = rackContext(at: 0.3)
    context.recording = true
    probe.observe(context, at: 0.3)
    try probe.run(reverse: true, at: 0.3)
    context.recording = false
    context.frameTimestamp = 0.4
    probe.observe(context, at: 0.4)
    #expect(probe.nextAction(at: 1.4).kind == "idle")
    #expect(probe.snapshot(at: 0.4).phase == "stopped")
}

@Test func rackReplacingADoesNotMoveBIntoANewReference() throws {
    var probe = try probeWithMarks()
    try probe.nudge(towardNear: true, at: 0.3)
    let command = probe.nextAction(at: 0.3)
    probe.complete(runID: command.runID, commandID: 0, outcome: 0, at: 0.31)
    probe.observe(rackContext(at: 0.4), at: 0.4)
    try probe.capture(markID: "A", at: 0.4)
    #expect(probe.snapshot(at: 0.4).marks.map(\.stepPosition) == [2, 3])
}

@Test func rackTemplatesCannotSerializeMarksOrArmedState() throws {
    let template = FocusRackTemplate(name: "Slow", transition: .init(duration: 5, delay: 2))
    let data = try JSONEncoder().encode(template)
    #expect(try JSONDecoder().decode(FocusRackTemplate.self, from: data) == template)
    let json = try #require(String(data: data, encoding: .utf8))
    #expect(!json.contains("stepPosition"))
    #expect(!json.contains("runID"))
}

@Test func rackUsesSharedTrackingEvidenceWithoutBlockingDetectionAlone() throws {
    for (evidence, allowed): (FocusRackFocusObservation?, Bool) in [
        (
            .init(
                trackingAFActive: false, subjectDetectionActive: true, boxCount: 1,
                selectedBoxIndex: 0), true
        ),
        (
            .init(
                trackingAFActive: true, subjectDetectionActive: false, boxCount: 1,
                selectedBoxIndex: nil), false
        ),
        (
            .init(
                trackingAFActive: false, subjectDetectionActive: true, boxCount: 2,
                selectedBoxIndex: 0), false
        ),
        (
            .init(
                trackingAFActive: false, subjectDetectionActive: true, boxCount: 1,
                selectedBoxIndex: 1), false
        ),
        (nil, false),
    ] {
        var context = rackContext()
        context.focus = evidence
        var probe = try FocusRackEngine()
        probe.observe(context, at: 0)
        #expect(probe.snapshot(at: 0).canCapture == allowed)
        if allowed {
            try probe.capture(markID: "A", at: 0)
            #expect(probe.snapshot(at: 0).marks.count == 1)
        } else {
            #expect(throws: FocusRackError.self) { try probe.capture(markID: "A", at: 0) }
        }
    }
}

@Test(arguments: [false, true], [1, 4, 10, 11, 100])
func rackSetupUsesIdenticalAcknowledgedChunks(towardNear: Bool, steps: Int) throws {
    var probe = try FocusRackEngine(configuration: .init(pulsesPerStep: 16, commandInterval: 0.01))
    probe.observe(rackContext(), at: 0)
    try probe.capture(markID: "A", at: 0)
    try probe.nudge(towardNear: towardNear, steps: steps, at: 0)
    let sign = towardNear ? -1 : 1
    for index in 0..<steps {
        let time = Double(index) * 0.06
        probe.observe(rackContext(at: time), at: time)
        let action = probe.nextAction(at: time)
        #expect(action.kind == "drive")
        #expect(action.commandID == index)
        #expect(action.signedPulses == sign * 16)
        #expect(probe.snapshot(at: time).stepPosition == sign * index)
        #expect(probe.nextAction(at: time).kind == "idle")
        probe.complete(runID: action.runID, commandID: index, outcome: 0, at: time + 0.03)
        #expect(probe.snapshot(at: time + 0.03).stepPosition == sign * (index + 1))
        if index < steps - 1 {
            #expect(probe.nextAction(at: time + 0.039).kind == "wait")
        }
    }
    let lastCompletion = Double(steps - 1) * 0.06 + 0.03
    probe.observe(rackContext(at: lastCompletion), at: lastCompletion)
    #expect(!probe.snapshot(at: lastCompletion).canCapture)
    let captureTime = lastCompletion + 0.01
    probe.observe(rackContext(at: captureTime), at: captureTime)
    try probe.capture(markID: "B", at: captureTime)
    #expect(probe.snapshot(at: captureTime).marks.map(\.stepPosition) == [0, sign * steps])
    let starts = probe.snapshot(at: captureTime, includeEvents: true).events.filter {
        $0.kind == "commandStarted"
    }
    #expect(starts.map(\.signedPulses) == Array(repeating: sign * 16, count: steps))
}

@Test(arguments: [0, -1, 101, Int.min, Int.max])
func rackSetupRejectsUnboundedStepCounts(steps: Int) throws {
    var probe = try FocusRackEngine()
    probe.observe(rackContext(), at: 0)
    #expect(throws: FocusRackError.invalidConfiguration) {
        try probe.nudge(towardNear: true, steps: steps, at: 0)
    }
    #expect(probe.nextAction(at: 0).kind == "idle")
    #expect(probe.snapshot(at: 0).stepPosition == 0)
}

@Test(arguments: [0, 2, 3, 0x12019], [10, 100])
func rackSetupHaltsWithoutLosingAcknowledgedPrefix(outcome: Int, steps: Int) throws {
    var probe = try FocusRackEngine(configuration: .init(pulsesPerStep: 16, commandInterval: 0.01))
    probe.observe(rackContext(), at: 0)
    try probe.nudge(towardNear: false, steps: steps, at: 0)
    for index in 0..<2 {
        let time = Double(index) * 0.06
        let action = probe.nextAction(at: time)
        probe.complete(runID: action.runID, commandID: index, outcome: 0, at: time + 0.03)
    }
    if outcome == 0 {
        probe.requestStop(at: 0.1)
    } else {
        let third = probe.nextAction(at: 0.12)
        #expect(third.signedPulses == 16)
        if outcome == 3 { probe.requestStop(at: 0.13) }
        probe.complete(runID: third.runID, commandID: 2, outcome: outcome, at: 0.15)
    }
    #expect(probe.nextAction(at: 0.3).kind == "idle")
    let snapshot = probe.snapshot(at: 0.3, includeEvents: true)
    #expect(snapshot.stepPosition == (outcome == 3 ? nil : 2))
    #expect(snapshot.events.filter { $0.kind == "commandStarted" }.count == (outcome == 0 ? 2 : 3))
    #expect(!snapshot.events.contains { $0.kind == "runCompleted" })
}

@Test(arguments: [false, true], [10, 100])
func rackSetupStopKeepsOnlyTheCompletedPrefix(towardNear: Bool, steps: Int) throws {
    var probe = try FocusRackEngine(configuration: .init(pulsesPerStep: 16, commandInterval: 0.01))
    probe.observe(rackContext(), at: 0)
    try probe.nudge(towardNear: towardNear, steps: steps, at: 0)
    for index in 0..<3 {
        let time = Double(index) * 0.06
        let action = probe.nextAction(at: time)
        #expect(action.kind == "drive")
        if index == 2 { probe.requestStop(at: time + 0.01) }
        probe.complete(runID: action.runID, commandID: index, outcome: 0, at: time + 0.03)
    }
    #expect(probe.nextAction(at: 1).kind == "idle")
    let snapshot = probe.snapshot(at: 1, includeEvents: true)
    #expect(snapshot.phase == "stopped")
    #expect(snapshot.stepPosition == (towardNear ? -3 : 3))
    #expect(snapshot.events.filter { $0.kind == "commandStarted" }.count == 3)
}

@Test func rackTimingAdmissionIncludesObservedCommandCostAndResetClearsIt() throws {
    var probe = try probeWithMarks(duration: 0.18)
    #expect(throws: FocusRackError.self) { try probe.run(reverse: true, at: 0.3) }
    #expect(!probe.snapshot(at: 0.3).busy)
    try probe.reset(at: 0.4)
    probe.observe(rackContext(at: 0.41), at: 0.41)
    try probe.capture(markID: "A", at: 0.41)
    for index in 0..<3 {
        let time = 0.5 + Double(index) * 0.1
        probe.observe(rackContext(at: time), at: time)
        try probe.nudge(towardNear: false, at: time)
        let action = probe.nextAction(at: time)
        probe.complete(runID: action.runID, commandID: 0, outcome: 0, at: time + 0.001)
    }
    probe.observe(rackContext(at: 0.8), at: 0.8)
    try probe.capture(markID: "B", at: 0.8)
    try probe.run(reverse: true, at: 0.8)
    #expect(probe.snapshot(at: 0.8).busy)
}

@Test(arguments: [3.5, 3.501])
func rackWarnsAboutFinalTimingWhileCompletingTheAcknowledgedEndpoint(completedAt: Double) throws {
    var probe = try probeWithMarks(delay: 2)
    try probe.run(reverse: true, at: 0.3)
    for (index, time) in [2.3, 2.795, 3.29].enumerated() {
        probe.observe(rackContext(at: time), at: time)
        let action = probe.nextAction(at: time)
        #expect(action.kind == "drive")
        probe.complete(
            runID: action.runID, commandID: index, outcome: 0,
            at: index == 2 ? completedAt : time + 0.01)
    }
    let result = probe.snapshot(at: completedAt, includeEvents: true)
    #expect(result.stepPosition == 0)
    #expect(result.completedSteps == 3)
    #expect(result.phase == "complete")
    #expect(probe.state(at: completedAt).timingWarning != nil)
    #expect(!result.events.contains { $0.kind == "missedDeadline" })
    #expect(
        result.events.contains { $0.runID == result.runID && $0.kind == "runCompleted" })
    #expect(probe.nextAction(at: completedAt).kind == "idle")
    probe.observe(rackContext(at: completedAt + 0.01), at: completedAt + 0.01)
    #expect(probe.snapshot(at: completedAt + 0.01).canCapture)
}

@Test func rackStopTakesPriorityOverALateFinalAcknowledgment() throws {
    var probe = try probeWithMarks()
    try probe.run(reverse: true, at: 0.3)
    for (index, time) in [0.3, 0.795, 1.29].enumerated() {
        probe.observe(rackContext(at: time), at: time)
        let action = probe.nextAction(at: time)
        if index == 2 { probe.requestStop(at: time + 0.01) }
        probe.complete(
            runID: action.runID, commandID: index, outcome: 0,
            at: index == 2 ? 1.6 : time + 0.01)
    }
    let result = probe.snapshot(at: 1.6, includeEvents: true)
    #expect(result.phase == "stopped")
    #expect(result.stepPosition == 0)
    #expect(
        !result.events.contains {
            $0.runID == result.runID && ($0.kind == "runCompleted" || $0.kind == "missedDeadline")
        })
}

@Test func rackFinalCompletionDoesNotReserveAnUnusedQuietGap() throws {
    let trajectory = try FocusRackTrajectory(
        signedSteps: 3, duration: 2, delay: 0, easing: .linear,
        commandInterval: 0.4, finalCommandDuration: 0.1)
    #expect(abs((trajectory.offsets.last ?? 0) + 0.1 - 2) < 1e-9)
    #expect(zip(trajectory.offsets, trajectory.offsets.dropFirst()).allSatisfy { $1 - $0 >= 0.4 })
    for invalid in [-0.1, Double.nan, .infinity, 0.5] {
        #expect(throws: FocusRackError.invalidConfiguration) {
            try FocusRackTrajectory(
                signedSteps: 3, duration: 2, delay: 0, easing: .linear,
                commandInterval: 0.4, finalCommandDuration: invalid)
        }
    }
}

private func denseRackProbe(nativeDuration: Double) throws -> (FocusRackEngine, Double) {
    var probe = try FocusRackEngine(
        configuration: .init(
            pulsesPerStep: 16, commandInterval: 0.01,
            transition: .init(duration: 8, delay: 2, easing: .easeInOut)))
    var time = 0.0
    probe.observe(rackContext(at: time), at: time)
    try probe.capture(markID: "A", at: time)
    for _ in 0..<23 {
        try probe.nudge(towardNear: false, steps: 4, at: time)
        for index in 0..<4 {
            let action = probe.nextAction(at: time)
            #expect(action.kind == "drive")
            probe.complete(
                runID: action.runID, commandID: index, outcome: 0, at: time + nativeDuration)
            time += nativeDuration + 0.010001
            probe.observe(rackContext(at: time), at: time)
        }
    }
    try probe.capture(markID: "B", at: time)
    return (probe, time)
}

@Test(arguments: [0.04, 0.05])
func rackDenseSixteenPulseProfileUsesMeasuredPeakCadence(nativeDuration: Double) throws {
    let setup = try denseRackProbe(nativeDuration: nativeDuration)
    var probe = setup.0
    var time = setup.1
    #expect(probe.snapshot(at: time).marks.map(\.stepPosition) == [0, 92])
    if nativeDuration == 0.05 {
        #expect(throws: FocusRackError.self) { try probe.run(reverse: true, at: time) }
        #expect(probe.nextAction(at: time).kind == "idle")
        return
    }
    let startedAt = time
    try probe.run(reverse: true, at: time)
    let runID = probe.snapshot(at: time).runID
    var commands = 0
    for _ in 0..<1_000 {
        probe.observe(rackContext(at: time), at: time)
        let action = probe.nextAction(at: time)
        if action.kind == "wait" {
            time += try #require(action.waitSeconds) + 1e-9
        } else if action.kind == "drive" {
            #expect(action.commandID == commands)
            #expect(action.signedPulses == -16)
            time += nativeDuration
            probe.complete(runID: action.runID, commandID: commands, outcome: 0, at: time)
            commands += 1
        } else {
            break
        }
    }
    let result = probe.snapshot(at: time, includeEvents: true)
    #expect(commands == 92)
    #expect(result.phase == "complete")
    #expect(result.stepPosition == 0)
    #expect(abs(time - startedAt - 2 - 8) < 0.4)
    let events = result.events.filter { $0.runID == runID }
    let starts = events.filter { $0.kind == "commandStarted" }
    let completions = events.filter { $0.kind == "commandCompleted" }
    #expect(starts.count == 92 && completions.count == 92)
    for index in 1..<starts.count {
        #expect(starts[index].timestamp - completions[index - 1].timestamp >= 0.01 - 1e-9)
    }
}

@Test func rackTimingChangesKeepMarksAndDoNotStartOrReposition() throws {
    var probe = try probeWithMarks()
    let before = probe.snapshot(at: 0.3)
    try probe.setTiming(duration: 24, easing: .linear, at: 0.3)
    let after = probe.snapshot(at: 0.3, includeEvents: true)
    #expect(after.marks == before.marks)
    #expect(after.stepPosition == before.stepPosition)
    #expect(after.configuration.pulsesPerStep == before.configuration.pulsesPerStep)
    #expect(after.configuration.commandInterval == before.configuration.commandInterval)
    #expect(after.configuration.transition.delay == before.configuration.transition.delay)
    #expect(after.configuration.transition.duration == 24)
    #expect(after.configuration.transition.easing == .linear)
    #expect(after.runID == before.runID)
    #expect(probe.nextAction(at: 0.3).kind == "idle")
    #expect(after.events.last?.kind == "timingChanged")
    try probe.run(reverse: true, at: 0.3)
    #expect(
        probe.snapshot(at: 0.3, includeEvents: true).events.last?.note?.contains("duration=24")
            == true)
}

@Test func rackActiveMovementRejectsTimingChangesAndKeepsItsPlan() throws {
    var probe = try probeWithMarks()
    try probe.run(reverse: true, at: 0.3)
    let before = probe.snapshot(at: 0.3)
    #expect(throws: FocusRackError.movementPending) {
        try probe.setTiming(duration: 32, easing: .easeInOut, at: 0.31)
    }
    let after = probe.snapshot(at: 0.31)
    #expect(after.configuration == before.configuration)
    #expect(after.runID == before.runID)
    #expect(after.totalSteps == before.totalSteps)
}

@Test(arguments: [Double.nan, .infinity, -1, 0, 120.01])
func rackTimingRejectsInvalidDurationsAtomically(duration: Double) throws {
    var probe = try probeWithMarks()
    let before = probe.snapshot(at: 0.3)
    #expect(throws: FocusRackError.invalidConfiguration) {
        try probe.setTiming(duration: duration, easing: .easeInOut, at: 0.3)
    }
    #expect(probe.snapshot(at: 0.3).configuration == before.configuration)
    #expect(probe.snapshot(at: 0.3).marks == before.marks)
}

@Test func rackCurveOnlyChangePreservesDurationAndWorksBeforeMarks() throws {
    var probe = try FocusRackEngine()
    try probe.setTiming(easing: .linear, at: 0)
    #expect(probe.snapshot(at: 0).configuration.transition.duration == 3)
    #expect(probe.snapshot(at: 0).configuration.transition.easing == .linear)
    #expect(probe.snapshot(at: 0).marks.isEmpty)
    #expect(probe.nextAction(at: 0).kind == "idle")
    #expect(throws: FocusRackError.invalidConfiguration) { try probe.setTiming(at: 0) }
}

@Test func rackConfigurationWarningSurvivesExplicitMovesUntilOperatorReset() throws {
    var engine = try probeWithMarks()
    let original = engine.currentProgram.marks
    var changed = rackContext(at: 0.4)
    changed.focalLength = "100"
    engine.observe(changed, at: 0.4)
    #expect(engine.state(at: 0.4).capabilities.canNudge)
    try engine.nudge(towardNear: false, at: 0.4)
    let drive = engine.nextAction(at: 0.4)
    #expect(drive.kind == "drive")
    engine.complete(runID: drive.runID, commandID: 0, outcome: 0, at: 0.41)
    changed.frameTimestamp = 0.5
    changed.safetyTimestamp = 0.5
    engine.observe(changed, at: 0.5)
    try engine.capture(markID: "B", at: 0.5)
    #expect(engine.state(at: 0.5).message.contains("reset marks if needed"))
    #expect(engine.currentProgram.marks.first == original.first)
    #expect(engine.state(at: 0.5).stepPosition == 4)
    try engine.reset(at: 0.5)
    #expect(engine.currentProgram.marks.isEmpty)
    #expect(!engine.state(at: 0.5).message.contains("setup changed"))
}

@Test func rackMissingEvidenceDoesNotPretendThatTheSetupChanged() throws {
    var engine = try probeWithMarks()
    var missing = rackContext(at: 0.4)
    missing.lens = nil
    missing.focalLength = nil
    missing.focusArea = nil
    missing.focusSubject = nil
    missing.safetyTimestamp = nil
    engine.observe(missing, at: 0.4)
    #expect(engine.state(at: 0.4).referenceValid)
    #expect(!engine.state(at: 0.4).capabilities.canNudge)
    engine.observe(rackContext(at: 0.5), at: 0.5)
    #expect(engine.state(at: 0.5).capabilities.canNudge)
    #expect(!engine.state(at: 0.5).message.contains("setup changed"))
}

@Test func rackReadinessBarrierGatesAllMovementWithoutDiscardingMarks() throws {
    var engine = try probeWithMarks()
    engine.requireReadinessFrame(at: 0.4)
    engine.observe(rackContext(at: 0.4), at: 0.4)
    let waiting = engine.state(at: 0.4)
    #expect(waiting.referenceValid)
    #expect(!waiting.capabilities.canNudge)
    #expect(!waiting.capabilities.canGoToA)
    #expect(!waiting.capabilities.canCaptureA)
    #expect(waiting.pullBToA?.enabled == false)
    #expect(throws: FocusRackError.referenceUnavailable) {
        try engine.nudge(towardNear: true, at: 0.4)
    }
    engine.observe(rackContext(at: 0.5), at: 0.5)
    #expect(engine.state(at: 0.5).capabilities.canGoToA)
    #expect(engine.currentProgram.marks.count == 2)
}
