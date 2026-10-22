import Foundation
import Testing

@testable import OpenZCineCore

private func productionContext(_ time: Double, sequence: Int64 = 1) -> FocusRackContext {
    .init(
        sessionID: "synthetic-session", connected: true, movieMode: true, foregroundOwner: true,
        focusMode: "AF-S",
        focus: .init(
            trackingAFActive: false, subjectDetectionActive: false,
            boxCount: 1, selectedBoxIndex: nil), frameTimestamp: time, safetyTimestamp: time,
        focusSettled: true, lens: "synthetic lens", focalLength: "70", recording: false,
        frameSequence: sequence, focusArea: "Single-point AF", focusSubject: "Off")
}

private func productionWithMarks(delay: Double = 0) throws -> FocusRackEngine {
    var config = FocusRackEngine.productionConfiguration
    config.transition = .init(duration: 2, delay: delay, easing: .easeInOut)
    var engine = try FocusRackEngine(configuration: config)
    engine.observe(productionContext(0), at: 0)
    try engine.capture(markID: "A", at: 0)
    try engine.nudge(towardNear: false, steps: 4, at: 0)
    for index in 0..<4 {
        let time = Double(index) * 0.05
        engine.observe(productionContext(time, sequence: Int64(index + 2)), at: time)
        let action = engine.nextAction(at: time)
        engine.complete(runID: action.runID, commandID: index, outcome: 0, at: time + 0.02)
    }
    engine.observe(productionContext(0.2, sequence: 7), at: 0.2)
    try engine.capture(markID: "B", at: 0.2)
    try engine.seek(markID: "A", at: 0.2)
    for index in 0..<4 {
        let time = 0.2 + Double(index) * 0.05
        let action = engine.nextAction(at: time)
        engine.complete(runID: action.runID, commandID: index, outcome: 0, at: time + 0.02)
    }
    engine.observe(productionContext(0.4, sequence: 8), at: 0.4)
    return engine
}

@Test func rackProductionProgramPrimaryAndCapturesShareTheCompletedLedger() throws {
    let engine = try productionWithMarks()
    let state = engine.state(at: 0.4)
    #expect(state.program.marks.map(\.stepPosition) == [0, 4])
    #expect(state.program.transitions.count == 1)
    #expect(state.primary.kind == "rehearse")
    #expect(state.primary.enabled)
    #expect(state.captures.map(\.frameSequence) == [1, 7])
    #expect(state.captures.map(\.revision) == [1, 2])
    #expect(!state.capabilities.canAutofocus)
    #expect(!state.capabilities.canCaptureB)
    #expect(FocusRackEngine.productionConfiguration.pulsesPerStep == 16)
    #expect(FocusRackEngine.productionConfiguration.commandInterval == 0)
}

@Test func rackPauseDuringCountdownResumesOnlyTheRemainingDelay() throws {
    var engine = try productionWithMarks(delay: 1)
    try engine.run(reverse: false, at: 0.4)
    let identity = engine.state(at: 0.4).runID
    engine.requestPause(at: 0.9)
    #expect(engine.state(at: 0.9).phase == .paused)
    #expect(abs(engine.state(at: 0.9).remainingDelay - 0.5) < 1e-9)
    #expect(engine.nextAction(at: 40).kind == "wait")
    engine.observe(productionContext(100, sequence: 9), at: 100)
    try engine.resume(at: 100)
    #expect(engine.nextAction(at: 100.499).kind == "wait")
    let first = engine.nextAction(at: 100.5)
    #expect(first.kind == "drive")
    #expect(first.runID == identity)
    #expect(first.commandID == 0)
}

@Test func rackPauseSettlesTheActiveChunkAndPreservesRemainingEasingAndTiming() throws {
    var engine = try productionWithMarks()
    try engine.run(reverse: false, at: 0.4)
    let first = engine.nextAction(at: 0.4)
    engine.requestPause(at: 0.41)
    #expect(engine.state(at: 0.41).phase == .pausing)
    engine.complete(runID: first.runID, commandID: 0, outcome: 0, at: 0.45)
    #expect(engine.state(at: 0.45).stepPosition == 1)
    #expect(engine.state(at: 0.45).phase == .paused)
    #expect(engine.nextAction(at: 50).kind == "wait")
    engine.observe(productionContext(100, sequence: 9), at: 100)
    try engine.resume(at: 100)
    let plan = try FocusRackTrajectory(
        signedSteps: 4, duration: 2, delay: 0,
        easing: .easeInOut, commandInterval: 0.02, finalCommandDuration: 0.02)
    for index in 1..<4 {
        let time = 0.4 + 99.55 + plan.offsets[index]
        engine.observe(productionContext(time, sequence: Int64(index + 10)), at: time)
        let action = engine.nextAction(at: time + 1e-8)
        #expect(action.kind == "drive")
        #expect(action.commandID == index)
        #expect(action.runID == first.runID)
        #expect(action.signedPulses == 16)
        engine.complete(runID: action.runID, commandID: index, outcome: 0, at: time + 0.02)
    }
    #expect(engine.state(at: 102).phase == .complete)
    #expect(engine.state(at: 102).stepPosition == 4)
}

@Test func rackStopWhilePausedDiscardsTheTrajectoryWithoutReturning() throws {
    var engine = try productionWithMarks()
    try engine.run(reverse: false, at: 0.4)
    engine.requestPause(at: 0.41)
    engine.requestStop(at: 0.42)
    #expect(engine.state(at: 0.42).phase == .stopped)
    #expect(engine.state(at: 0.42).stepPosition == 0)
    #expect(engine.nextAction(at: 50).kind == "idle")
    #expect(throws: FocusRackError.self) { try engine.resume(at: 50) }
}

@Test func rackTemplatesAreTimingOnlyClearMarksAndPreserveUnconfirmedRecovery() throws {
    var engine = try productionWithMarks()
    let template = FocusRackTemplate(
        name: "  Slow reverse  ",
        transition: .init(
            fromMark: "B", toMark: "A", duration: 24, delay: 2, easing: .linear))
    let encoded = try FocusRackTemplateCodec.encode([template])
    let restored = try FocusRackTemplateCodec.decode(encoded)
    #expect(restored[0].name == "Slow reverse")
    let json = try #require(JSONSerialization.jsonObject(with: encoded) as? [[String: Any]])
    #expect(Set(json[0].keys) == Set(["name", "transition"]))
    try engine.run(reverse: false, at: 0.4)
    let action = engine.nextAction(at: 0.4)
    engine.requestStop(at: 0.41)
    engine.complete(runID: action.runID, commandID: 0, outcome: 4, at: 0.42)
    try engine.applyTemplate(restored[0], at: 0.43)
    let state = engine.state(at: 0.43)
    #expect(state.program.marks.isEmpty)
    #expect(state.captures.isEmpty)
    #expect(!state.referenceValid)
    #expect(state.recoveryInstruction == "Reconnect camera, then reset marks.")
    #expect(state.direction == .bToA)
    #expect(throws: FocusRackError.reconnectRequired) { try engine.reset(at: 0.44) }
}

@Test func rackDiscardingIdleMarksPreservesUnconfirmedStopUntilANewSession() throws {
    var engine = try productionWithMarks()
    try engine.run(reverse: false, at: 0.4)
    let action = engine.nextAction(at: 0.4)
    #expect(throws: FocusRackError.movementPending) { try engine.discardMarks(at: 0.405) }
    engine.requestStop(at: 0.41)
    engine.complete(runID: action.runID, commandID: 0, outcome: 4, at: 0.42)
    var disconnected = productionContext(0.43, sequence: 9)
    disconnected.connected = false
    disconnected.focusSettled = false
    engine.observe(disconnected, at: 0.43)
    try engine.discardMarks(at: 0.44)
    #expect(engine.state(at: 0.44).program.marks.isEmpty)
    #expect(engine.state(at: 0.44).captures.isEmpty)
    #expect(!engine.state(at: 0.44).referenceValid)
    #expect(engine.state(at: 0.44).recoveryInstruction == "Reconnect camera, then reset marks.")
    engine.observe(productionContext(0.5, sequence: 10), at: 0.5)
    #expect(throws: FocusRackError.reconnectRequired) { try engine.reset(at: 0.5) }
    var reconnected = productionContext(0.6, sequence: 1)
    reconnected.sessionID = "synthetic-new-session"
    engine.observe(reconnected, at: 0.6)
    try engine.reset(at: 0.6)
    #expect(throws: FocusRackError.freshFrameRequired) { try engine.capture(markID: "A", at: 0.6) }
    reconnected.frameTimestamp = 0.7
    reconnected.frameSequence = 2
    engine.observe(reconnected, at: 0.7)
    try engine.capture(markID: "A", at: 0.7)
    #expect(engine.state(at: 0.7).captures.first?.sessionID == "synthetic-new-session")
}

@Test func rackTransitionValidationIsAtomicAndIncludesDelayAndDirection() throws {
    var engine = try productionWithMarks()
    let original = engine.currentProgram
    var invalid = original.transitions[0]
    invalid.delay = .nan
    #expect(throws: FocusRackError.self) { try engine.setTransition(invalid, at: 0.4) }
    #expect(engine.currentProgram == original)
    let transition = FocusRackTransition(
        fromMark: "B", toMark: "A", duration: 24, delay: 2, easing: .linear)
    try engine.setTransition(transition, at: 0.4)
    #expect(engine.currentProgram.marks == original.marks)
    #expect(engine.state(at: 0.4).primary.kind == "rehearse")
    #expect(!engine.state(at: 0.4).primary.enabled)
    #expect(engine.state(at: 0.4).primary.detail == "24 s pull")
    #expect(engine.state(at: 0.4).primary.disabledReason == "Go to B first")
    #expect(engine.state(at: 0.4).capabilities.canGoToB)
    #expect(engine.nextAction(at: 0.4).kind == "idle")
}

@Test func rackObservedFocusSettingChangesLeaveResetToTheOperator() throws {
    for changesArea in [true, false] {
        var engine = try productionWithMarks()
        var observation = productionContext(0.5, sequence: 9)
        if changesArea {
            observation.focusArea = "Wide-area AF"
        } else {
            observation.focusSubject = "People"
        }
        engine.observe(observation, at: 0.5)
        #expect(engine.state(at: 0.5).referenceValid)
        #expect(engine.state(at: 0.5).capabilities.canNudge)
        #expect(engine.state(at: 0.5).message.contains("reset marks if needed"))
    }
}

private final class RackFakeCamera: @unchecked Sendable {
    private let lock = NSLock()
    private let prepareCondition = NSCondition()
    private var instant = 0.0
    private var reads = 0
    private var drives: [UInt32] = []
    private var stops: [Int64] = []
    private var continuation: CheckedContinuation<NikonFocusRackDriveOutcome, Never>?
    private var hold = false
    private var blocksPrepare = false
    private var insidePrepare = false
    private var safetyLatency = 0.0
    private var holdsSafety = false
    private var safetyContinuation: CheckedContinuation<Void, Never>?
    private var sleeps = 0

    var readCount: Int { lock.withLock { reads } }
    var driveCount: Int { lock.withLock { drives.count } }
    var stopCount: Int { lock.withLock { stops.count } }
    var isPreparing: Bool { prepareCondition.withLock { insidePrepare } }

    // Unrelated CPU-heavy tests must not age this synthetic camera's accepted frames.
    var clock: FocusRackClock {
        .init(
            now: { [self] in
                lock.withLock {
                    instant += 0.000_001
                    return instant
                }
            },
            sleep: { [self] _ in
                lock.withLock { sleeps += 1 }
                try await Task.sleep(for: .milliseconds(1))
            })
    }

    func holdNextSafetyRead(latency: Double = 0) {
        lock.withLock {
            holdsSafety = true
            safetyLatency = latency
        }
    }
    func releaseSafetyRead() {
        let pending = lock.withLock {
            holdsSafety = false
            let pending = safetyContinuation
            safetyContinuation = nil
            return pending
        }
        pending?.resume()
    }
    func setSafetyLatency(_ seconds: Double) { lock.withLock { safetyLatency = seconds } }
    func advanceClockBeforeNextSleep(_ seconds: Double) -> Int {
        lock.withLock {
            instant += seconds
            return sleeps
        }
    }
    func slept(after count: Int) -> Bool { lock.withLock { sleeps > count } }
    private func waitForSafety() async {
        await withCheckedContinuation { pending in
            let waiting = lock.withLock {
                reads += 1
                if holdsSafety { safetyContinuation = pending }
                return holdsSafety
            }
            if !waiting { pending.resume() }
        }
        lock.withLock { instant += safetyLatency }
    }
    func holdNextDrive() { lock.withLock { hold = true } }
    func blockPrepare() { prepareCondition.withLock { blocksPrepare = true } }
    func releasePrepare() {
        prepareCondition.withLock {
            blocksPrepare = false
            prepareCondition.broadcast()
        }
    }
    func finish(_ outcome: NikonFocusRackDriveOutcome) {
        let pending = lock.withLock {
            let c = continuation
            continuation = nil
            return c
        }
        pending?.resume(returning: outcome)
    }

    private func prepare() -> Bool {
        prepareCondition.lock()
        insidePrepare = true
        while blocksPrepare { prepareCondition.wait() }
        prepareCondition.unlock()
        return true
    }

    private func drive(_ pulses: UInt32) async -> NikonFocusRackDriveOutcome {
        return await withCheckedContinuation { pending in
            let shouldFinish = lock.withLock {
                drives.append(pulses)
                if hold { continuation = pending }
                return !hold
            }
            if shouldFinish { pending.resume(returning: .complete) }
        }
    }

    var access: NikonFocusRackAccess {
        .init(
            isCurrent: { true }, prepareRun: { [self] _ in prepare() },
            requestStop: { [self] run in lock.withLock { stops.append(run) } },
            driveChunk: { [self] _, _, pulses in await drive(pulses) },
            refreshSafety: { [self] in
                await waitForSafety()
                return try .init(
                    reported: .init(
                        focalLength: "70", focalMinX100: 3500,
                        focalMaxX100: 10000, apertureMinX100: 280, focusMode: "AF-S",
                        focusArea: "Single-point AF", focusSubject: "Off", captureSelector: .video))
            })
    }
}

private func cameraObservation(_ sequence: Int64, result: String = "unknown", age: Double = 0)
    -> FocusRackObservation
{
    .init(
        sessionID: "synthetic-camera", connected: true, foregroundOwner: true, recording: false,
        frameSequence: sequence,
        focus: .init(
            trackingAFActive: false, subjectDetectionActive: false,
            boxCount: 1, selectedBoxIndex: nil), frameAgeSeconds: age, focusResult: result)
}

private func waitForRack(_ condition: () async -> Bool) async throws {
    for _ in 0..<100 {
        if await condition() { return }
        try await Task.sleep(for: .milliseconds(5))
    }
    Issue.record("Timed out waiting for the simulated focus-rack state")
}

@Test func rackControllerRequiresANewFrameAfterInitialReadinessAndKeepsFrameIdentity() async throws
{
    let camera = RackFakeCamera()
    let controller = FocusRackController(driver: camera.access, clock: camera.clock)
    await controller.observe(cameraObservation(1))
    try await waitForRack { await controller.snapshot().capabilities.canNudge }
    #expect(!(await controller.snapshot()).capabilities.canCaptureA)
    await controller.observe(cameraObservation(1))
    #expect(!(await controller.snapshot()).capabilities.canCaptureA)
    try await controller.handle(
        .capture(markID: "A", expectedFrameSequence: 2), observation: cameraObservation(2))
    let captured = await controller.snapshot()
    #expect(captured.captures.first?.frameSequence == 2)
    #expect(captured.captures.first?.sessionID == "synthetic-camera")
    await controller.close()
}

@Test func rackControllerPauseDoesNotCancelAndStopPublishesBeforeNativeCompletion() async throws {
    let camera = RackFakeCamera()
    camera.holdNextDrive()
    let controller = FocusRackController(driver: camera.access, clock: camera.clock)
    await controller.observe(cameraObservation(1))
    try await waitForRack { await controller.snapshot().capabilities.canNudge }
    await controller.observe(cameraObservation(2))
    try await controller.handle(.nudge(towardNear: false, steps: 10))
    try await waitForRack { camera.driveCount == 1 }
    try await controller.handle(.pause)
    #expect((await controller.snapshot()).phase == .pausing)
    #expect(camera.stopCount == 0)
    controller.requestStop()
    #expect(camera.stopCount == 1)
    camera.finish(.cancelledReady)
    try await waitForRack { !(await controller.snapshot()).busy }
    #expect(!(await controller.snapshot()).referenceValid)
    #expect(camera.driveCount == 1)
    await controller.close()
}

@Test func rackControllerBodyAFInvalidatesAndInvalidationSurvivesImmediateStop() async throws {
    let camera = RackFakeCamera()
    let controller = FocusRackController(driver: camera.access, clock: camera.clock)
    await controller.observe(cameraObservation(1))
    try await waitForRack { await controller.snapshot().capabilities.canNudge }
    try await controller.handle(
        .capture(markID: "A", expectedFrameSequence: 2), observation: cameraObservation(2))
    await controller.observe(cameraObservation(3, result: "focused"))
    #expect(!(await controller.snapshot()).referenceValid)
    try await waitForRack { await controller.snapshot().capabilities.canReset }
    try await controller.handle(.reset)
    try await controller.handle(
        .capture(markID: "A", expectedFrameSequence: 4), observation: cameraObservation(4))
    camera.blockPrepare()
    try await controller.handle(.nudge(towardNear: false, steps: 4))
    try await waitForRack { camera.isPreparing }
    controller.invalidate(reason: "Synthetic source was replaced.")
    controller.requestStop()
    camera.releasePrepare()
    try await waitForRack { !(await controller.snapshot()).referenceValid }
    #expect(!(await controller.snapshot()).referenceValid)
    #expect(camera.driveCount == 0)
    await controller.close()
}

@Test(arguments: [NikonFocusRackDriveOutcome.cancelledReady, .cancelledUnconfirmed, .uncertain])
func rackControllerCloseWaitsForTheNativeOutcomeWithoutLosingUncertainty(
    outcome: NikonFocusRackDriveOutcome
) async throws {
    let camera = RackFakeCamera()
    camera.holdNextDrive()
    defer { camera.finish(.uncertain) }
    let controller = FocusRackController(driver: camera.access, clock: camera.clock)
    await controller.observe(cameraObservation(1))
    try await waitForRack { await controller.snapshot().capabilities.canNudge }
    try await controller.handle(
        .capture(markID: "A", expectedFrameSequence: 2), observation: cameraObservation(2))
    try await controller.handle(.nudge(towardNear: false, steps: 10))
    try await waitForRack { camera.driveCount == 1 }

    let closing = Task {
        await controller.close()
        return await controller.diagnostics()
    }
    try await waitForRack { camera.stopCount > 0 }
    #expect((await controller.snapshot()).phase == .stopping)
    camera.finish(outcome)
    let final = await closing.value
    #expect(final.phase == (outcome == .cancelledUnconfirmed ? "stopUnconfirmed" : "uncertain"))
    #expect(final.stepPosition == nil)
    #expect(!final.busy)
    #expect(camera.driveCount == 1)
    await #expect(throws: FocusRackError.referenceUnavailable) {
        try await controller.handle(.nudge(towardNear: false, steps: 1))
    }
    #expect(camera.driveCount == 1)
}

@Test func rackControllerRejectsOlderFrameLifecycleButAcceptsSameFrameLifecycle() async throws {
    let camera = RackFakeCamera()
    let controller = FocusRackController(driver: camera.access, clock: camera.clock)
    #expect(camera.readCount == 0)
    await controller.observe(cameraObservation(1))
    try await waitForRack { await controller.snapshot().capabilities.canNudge }
    try await controller.handle(
        .capture(markID: "A", expectedFrameSequence: 3), observation: cameraObservation(3))
    var old = cameraObservation(2)
    old.foregroundOwner = false
    await controller.observe(old)
    #expect((await controller.snapshot()).referenceValid)
    old.frameSequence = 3
    await controller.observe(old)
    #expect((await controller.snapshot()).referenceValid)
    #expect(!(await controller.snapshot()).capabilities.canNudge)
    let reads = camera.readCount
    try await Task.sleep(for: .milliseconds(70))
    #expect(camera.readCount == reads)
    await controller.close()
}

@Test func rackTemplateStorageRoundTripsEveryAdmittedCollectionAndRejectsOversizeInput() throws {
    let boundary = FocusRackTemplate(name: String(repeating: "a", count: 60), transition: .init())
    #expect(
        try FocusRackTemplateCodec.decode(FocusRackTemplateCodec.encode([boundary])) == [boundary])
    let longName = FocusRackTemplate(name: boundary.name + "a", transition: .init())
    #expect(throws: FocusRackError.invalidTemplateName) {
        try FocusRackTemplateCodec.validate(longName)
    }
    #expect(throws: FocusRackError.invalidTemplateName) {
        try FocusRackTemplateCodec.encode([boundary, boundary])
    }
    let large = (0..<2_000).map { FocusRackTemplate(name: "Timing \($0)", transition: .init()) }
    #expect(throws: FocusRackError.templateStorageFull) { try FocusRackTemplateCodec.encode(large) }
    let oversizedStored = try JSONEncoder().encode(large)
    #expect(throws: FocusRackError.templateStorageFull) {
        try FocusRackTemplateCodec.decode(oversizedStored)
    }
}

@Test func rackControllerBodyAFStopsTheNativeChunkBeforeItsOutcomeReturns() async throws {
    let camera = RackFakeCamera()
    camera.holdNextDrive()
    let controller = FocusRackController(driver: camera.access, clock: camera.clock)
    await controller.observe(cameraObservation(1))
    try await waitForRack { await controller.snapshot().capabilities.canNudge }
    try await controller.handle(
        .capture(markID: "A", expectedFrameSequence: 2), observation: cameraObservation(2))
    try await controller.handle(.nudge(towardNear: false, steps: 4))
    try await waitForRack { camera.driveCount == 1 }
    await controller.observe(cameraObservation(3, result: "focused"))
    #expect(camera.stopCount == 1)
    #expect((await controller.snapshot()).phase == .stopping)
    camera.finish(.cancelledReady)
    try await waitForRack { !(await controller.snapshot()).busy }
    #expect(camera.driveCount == 1)
    #expect(!(await controller.snapshot()).referenceValid)
    await controller.close()
}

@Test func rackRecordingStopObservationRevokesAnAtomicQueuedMovementIntent() async throws {
    let camera = RackFakeCamera()
    let controller = FocusRackController(driver: camera.access, clock: camera.clock)
    var recording = cameraObservation(1)
    recording.recording = true
    await controller.observe(recording)
    try await waitForRack { await controller.snapshot().capabilities.canNudge }
    recording.frameSequence = 2
    try await controller.handle(
        .capture(markID: "A", expectedFrameSequence: 2), observation: recording)
    await #expect(throws: FocusRackError.referenceUnavailable) {
        try await controller.handle(
            .nudge(towardNear: false, steps: 4), observation: cameraObservation(3))
    }
    #expect(camera.driveCount == 0)
    #expect((await controller.snapshot()).stepPosition == 0)
    await controller.close()
}

@Test func rackDisplayedMinimumRoundsUpWithoutChangingTrajectoryAdmission() throws {
    let required = 16.602
    #expect(
        FocusRackError.durationTooShort(minimum: required).localizedDescription.contains("16.61"))
    #expect(throws: FocusRackError.self) {
        try FocusRackTrajectory(
            signedSteps: 3, duration: 16.60, delay: 0, easing: .linear,
            commandInterval: 8.201, finalCommandDuration: 0.2)
    }
    let admitted = try FocusRackTrajectory(
        signedSteps: 3, duration: 16.61, delay: 0, easing: .linear,
        commandInterval: 8.201, finalCommandDuration: 0.2)
    #expect(abs(admitted.minimumDuration - required) < 1e-9)
    var engine = try productionWithMarks()
    let exact = try FocusRackTrajectory(
        signedSteps: 4, duration: 2, delay: 0, easing: .easeInOut,
        commandInterval: 0.02, finalCommandDuration: 0.02
    ).minimumDuration
    let displayed = try #require(engine.state(at: 0.4).minimumDuration)
    #expect(displayed >= exact)
    var transition = engine.currentProgram.transitions[0]
    transition.duration = exact - 0.001
    try engine.setTransition(transition, at: 0.4)
    #expect(engine.state(at: 0.4).minimumDuration == displayed)
    #expect(engine.state(at: 0.4).admissionMessage != nil)
    transition.duration = displayed
    try engine.setTransition(transition, at: 0.4)
    #expect(engine.state(at: 0.4).admissionMessage == nil)
    try engine.run(reverse: false, at: 0.4)
    #expect(engine.state(at: 0.4).busy)
    #expect(
        FocusRackError.marksTooClose.localizedDescription
            == "These marks are too close for a timed pull. Set new marks farther apart.")
}

@Test func rackAdapterTaskQueuedBeforeStopCannotRearmAfterItsTaskHop() async throws {
    let camera = RackFakeCamera()
    camera.holdNextDrive()
    let controller = FocusRackController(driver: camera.access, clock: camera.clock)
    await controller.observe(cameraObservation(1))
    try await waitForRack { await controller.snapshot().capabilities.canNudge }
    await controller.observe(cameraObservation(2))
    let ticket = controller.makeIntentTicket()
    let release = AsyncStream<Void>.makeStream()
    let queued = Task { () -> FocusRackError? in
        for await _ in release.stream { break }
        do {
            try await controller.handle(.nudge(towardNear: false, steps: 1), ticket: ticket)
            return nil
        } catch { return error as? FocusRackError ?? .invalidConfiguration }
    }
    controller.requestStop()
    release.continuation.yield(())
    release.continuation.finish()
    let failure = await queued.value
    #expect(failure == .referenceUnavailable)
    if failure == nil { try await waitForRack { camera.driveCount == 1 } }
    #expect(camera.driveCount == 0)
    camera.finish(.cancelledReady)
    await controller.close()
}

@Test func rackIntentTicketsCannotAuthorizeAnotherController() async throws {
    let camera = RackFakeCamera()
    let otherCamera = RackFakeCamera()
    let controller = FocusRackController(driver: camera.access, clock: camera.clock)
    let other = FocusRackController(driver: otherCamera.access, clock: otherCamera.clock)
    await controller.observe(cameraObservation(1))
    await other.observe(cameraObservation(1))
    try await waitForRack { await other.snapshot().capabilities.canNudge }
    await other.observe(cameraObservation(2))
    let ticket = controller.makeIntentTicket()
    await #expect(throws: FocusRackError.referenceUnavailable) {
        try await other.handle(.nudge(towardNear: false, steps: 1), ticket: ticket)
    }
    #expect(otherCamera.driveCount == 0)
    await controller.close()
    await other.close()
}

@Test func rackFreshIntentTicketAfterStopCanStartAnExplicitNewMove() async throws {
    let camera = RackFakeCamera()
    let controller = FocusRackController(driver: camera.access, clock: camera.clock)
    await controller.observe(cameraObservation(1))
    try await waitForRack { await controller.snapshot().capabilities.canNudge }
    await controller.observe(cameraObservation(2))
    let stale = controller.makeIntentTicket()
    controller.requestStop()
    let fresh = controller.makeIntentTicket()
    await #expect(throws: FocusRackError.referenceUnavailable) {
        try await controller.handle(.nudge(towardNear: false, steps: 1), ticket: stale)
    }
    try await controller.handle(.nudge(towardNear: false, steps: 1), ticket: fresh)
    try await waitForRack {
        let state = await controller.snapshot()
        return camera.driveCount == 1 && !state.busy
    }
    #expect((await controller.snapshot()).stepPosition == 1)
    await controller.close()
}

@Test func rackQueuedTimingEditsMergeAgainstLatestActorStateWithoutSnapshots() async throws {
    let camera = RackFakeCamera()
    let controller = FocusRackController(driver: camera.access, clock: camera.clock)
    try await controller.handle(.updateTiming(.init(durationMode: .fastest)))
    try await controller.handle(.updateTiming(.init(delay: 2)))
    try await controller.handle(.updateTiming(.init(direction: .bToA)))
    let state = await controller.snapshot()
    #expect(state.transition.durationMode == .fastest)
    #expect(state.transition.duration == 3)
    #expect(state.transition.delay == 2)
    #expect(state.transition.fromMark == "B")
    #expect(state.transition.toMark == "A")
    #expect(state.transition.easing == .linear)
    #expect(camera.driveCount == 0)
    await controller.close()
}

@Test func rackTimingChangesKeepPositioningSeparateFromLabelledPlayback() throws {
    var engine = try productionWithMarks()
    let marks = engine.currentProgram.marks
    var transition = engine.currentProgram.transitions[0]
    transition.duration = 10
    try engine.setTransition(transition, at: 0.4)
    var state = engine.state(at: 0.4)
    #expect(state.primary.kind == "rehearse")
    #expect(state.primary.detail == "10 s pull")
    #expect(state.primary.enabled)
    #expect(state.capabilities.canGoToB)
    transition.duration = 0.001
    try engine.setTransition(transition, at: 0.4)
    state = engine.state(at: 0.4)
    #expect(!state.primary.enabled)
    #expect(state.primary.disabledReason == "Adjust timing")
    #expect(state.admissionMessage != nil)
    #expect(state.capabilities.canGoToB)
    #expect(engine.currentProgram.marks == marks)
    try engine.seek(markID: "B", at: 0.4)
    #expect(engine.nextAction(at: 0.4).kind == "drive")
}

@Test func rackPlaybackLabelIncludesModeDirectionAndRecordingState() throws {
    var engine = try productionWithMarks()
    var transition = engine.currentProgram.transitions[0]
    transition.durationMode = .fastest
    transition.fromMark = "B"
    transition.toMark = "A"
    try engine.setTransition(transition, at: 0.4)
    var context = productionContext(0.5, sequence: 9)
    context.recording = true
    engine.observe(context, at: 0.5)
    let state = engine.state(at: 0.5)
    #expect(state.primary.title == "Run B→A")
    #expect(state.primary.detail == "Fastest")
    #expect(state.primary.disabledReason == "Go to B first")
    #expect(!state.primary.enabled)
    #expect(state.capabilities.canGoToB)
}

@Test func directTimedActionsShareDurationAndKeepPositioningIndependent() throws {
    var engine = try productionWithMarks(delay: 1)
    var state = engine.state(at: 0.4)
    #expect(state.pullAToB?.enabled == true)
    #expect(state.pullBToA?.enabled == false)
    #expect(state.pullAToB?.detail == "2 s pull")
    #expect(state.pullBToA?.detail == "2 s pull")
    state.stepPosition = 4
    state.updateTimedActions(recording: true, ready: true)
    #expect(state.pullAToB?.enabled == false)
    #expect(state.pullBToA?.enabled == true)
    #expect(state.pullBToA?.title == "Run B→A")
    #expect(state.playbackInstruction == nil)
    state.admissionMessage = "Unsupported timing"
    state.updateTimedActions(recording: true, ready: true)
    #expect(state.pullAToB?.enabled == false && state.pullBToA?.enabled == false)
    #expect(state.playbackInstruction == "Adjust timing")
    #expect(state.capabilities.canGoToB)
    let previous = engine.currentProgram
    #expect(throws: FocusRackError.notAtStart) { try engine.run(direction: .bToA, at: 0.4) }
    #expect(engine.currentProgram.transitions == previous.transitions)
    #expect(engine.currentProgram.marks == previous.marks)
    var legacy = previous.transitions[0]
    legacy.durationMode = .fastest
    try engine.setTransition(legacy, at: 0.4)
    try engine.run(direction: .aToB, at: 0.4)
    #expect(engine.currentProgram.transitions[0].durationMode == .timed)
    #expect(engine.currentProgram.transitions[0].delay == 1)
    #expect(engine.currentProgram.marks == previous.marks)
    #expect(engine.nextAction(at: 1).kind == "wait")
}

private func controllerWithTwoMarks(_ camera: RackFakeCamera) async throws -> FocusRackController {
    let controller = FocusRackController(driver: camera.access, clock: camera.clock)
    await controller.observe(cameraObservation(1))
    try await waitForRack { await controller.snapshot().capabilities.canNudge }
    try await controller.handle(
        .capture(markID: "A", expectedFrameSequence: 2), observation: cameraObservation(2))
    try await controller.handle(.nudge(towardNear: false, steps: 2))
    try await waitForRack {
        let state = await controller.snapshot()
        return camera.driveCount == 2 && !state.busy
    }
    try await controller.handle(
        .capture(markID: "B", expectedFrameSequence: 3), observation: cameraObservation(3))
    try await controller.handle(.updateTiming(.init(duration: 0.2, delay: 0, easing: .linear)))
    return controller
}

@Test func rackControllerExcludesFullSafetyPreflightFromTheMovementEpoch() async throws {
    let camera = RackFakeCamera()
    let controller = try await controllerWithTwoMarks(camera)
    #expect(camera.readCount == 1)
    camera.holdNextDrive()
    camera.setSafetyLatency(0.5)
    try await controller.handle(.run(direction: .bToA))
    try await waitForRack { camera.driveCount == 3 }
    let trace = await controller.diagnostics()
    let began = try #require(trace.events.last { $0.kind == "runStarted" })
    let prepared = try #require(trace.events.last { $0.kind == "preflightCompleted" })
    let dispatched = try #require(trace.events.last { $0.kind == "commandStarted" })
    #expect(prepared.timestamp - began.timestamp >= 0.5)
    #expect(dispatched.timestamp - prepared.timestamp < 0.001)
    #expect(
        trace.events.contains {
            $0.kind == "safetyRead" && $0.note?.contains("accepted=true") == true
        })
    controller.requestStop()
    camera.finish(.cancelledReady)
    await controller.close()
}

@Test(arguments: [false, true])
func rackStopOrControlLossDuringHeldPreflightCannotActivateTheLens(controlLoss: Bool) async throws {
    let camera = RackFakeCamera()
    let controller = try await controllerWithTwoMarks(camera)
    camera.holdNextSafetyRead()
    let reads = camera.readCount
    try await controller.handle(.run(direction: .bToA))
    try await waitForRack { camera.readCount > reads }
    if controlLoss {
        var lost = cameraObservation(4)
        lost.foregroundOwner = false
        await controller.observe(lost)
    } else {
        controller.requestStop()
    }
    camera.releaseSafetyRead()
    try await waitForRack { !(await controller.snapshot()).busy }
    #expect(camera.driveCount == 2)
    #expect(camera.stopCount >= 1)
    let state = await controller.snapshot()
    #expect(state.referenceValid)
    #expect(state.stepPosition == 2)
    let trace = await controller.diagnostics()
    #expect(!trace.events.contains { $0.runID == state.runID && $0.kind == "commandStarted" })
    await controller.close()
}

@Test(arguments: [1.0, 10.0])
func rackSafetyRefreshDefersOnlyWhenTheRemainingPullFitsFreshness(duration: Double) async throws {
    let camera = RackFakeCamera()
    let controller = FocusRackController(driver: camera.access, clock: camera.clock)
    await controller.observe(cameraObservation(1))
    try await waitForRack { await controller.snapshot().capabilities.canNudge }
    try await controller.handle(
        .capture(markID: "A", expectedFrameSequence: 2), observation: cameraObservation(2))
    var sequence: Int64 = 3
    var remaining = duration == 1 ? 10 : 94
    while remaining > 0 {
        let steps = min(10, remaining)
        try await controller.handle(.nudge(towardNear: false, steps: steps))
        try await waitForRack { !(await controller.snapshot()).busy }
        await controller.observe(cameraObservation(sequence))
        sequence += 1
        remaining -= steps
    }
    try await controller.handle(
        .capture(markID: "B", expectedFrameSequence: sequence),
        observation: cameraObservation(sequence))
    try await controller.handle(.updateTiming(.init(duration: duration, delay: 0, easing: .linear)))
    camera.setSafetyLatency(0.05)
    let reads = camera.readCount
    try await controller.handle(.run(direction: .bToA))
    try await waitForRack { camera.readCount > reads }
    for _ in 0..<250 {
        if !(await controller.snapshot()).busy { break }
        let sleep = camera.advanceClockBeforeNextSleep(0.05)
        sequence += 1
        await controller.observe(cameraObservation(sequence))
        // Advance again only after the pump has settled the current fake command/read.
        try await waitForRack {
            if camera.slept(after: sleep) { return true }
            return !(await controller.snapshot()).busy
        }
    }
    let state = await controller.snapshot()
    #expect(state.phase == .complete)
    #expect(state.stepPosition == 0)
    let trace = await controller.diagnostics()
    let commands = trace.events.filter { $0.runID == state.runID && $0.kind == "commandStarted" }
    let start = try #require(commands.first).timestamp
    let end = try #require(trace.events.last { $0.kind == "commandCompleted" }).timestamp
    let midPullReads = trace.events.filter {
        $0.kind == "safetyRead" && ($0.scheduledAt ?? 0) > start && $0.timestamp < end
    }
    #expect(duration == 1 ? midPullReads.isEmpty : !midPullReads.isEmpty)
    for read in midPullReads {
        let next = try #require(commands.first { ($0.scheduledAt ?? 0) > (read.scheduledAt ?? 0) })
        #expect(read.timestamp <= (next.scheduledAt ?? 0) + 1e-9)
    }
    #expect(!trace.events.contains { $0.kind == "invalidated" || $0.kind == "missedDeadline" })
    await controller.close()
}

@Test func rackSetupGuidanceUsesTheVisibleNearFarControls() throws {
    var engine = try FocusRackEngine(configuration: FocusRackEngine.productionConfiguration)
    engine.observe(productionContext(0), at: 0)
    try engine.capture(markID: "A", at: 0)
    let state = engine.state(at: 0)
    #expect(state.message == "Use Near/Far to focus the other subject, then set the second mark.")
    #expect(!state.capabilities.canStop)
    #expect(state.capabilities.canNudge)
    #expect(FocusRackError.samePosition.localizedDescription.contains("Near/Far"))
}

@Test(arguments: [false, true])
func rackHeldMaintenanceReadCannotSendLateCommands(stopDuringRead: Bool) async throws {
    let camera = RackFakeCamera()
    let controller = FocusRackController(driver: camera.access, clock: camera.clock)
    await controller.observe(cameraObservation(1))
    try await waitForRack { await controller.snapshot().capabilities.canNudge }
    try await controller.handle(
        .capture(markID: "A", expectedFrameSequence: 2), observation: cameraObservation(2))
    for sequence in 3...4 {
        try await controller.handle(.nudge(towardNear: false, steps: 10))
        try await waitForRack { !(await controller.snapshot()).busy }
        await controller.observe(cameraObservation(Int64(sequence)))
    }
    try await controller.handle(
        .capture(markID: "B", expectedFrameSequence: 5), observation: cameraObservation(5))
    try await controller.handle(.updateTiming(.init(duration: 3)))
    let reads = camera.readCount
    try await controller.handle(.run(direction: .bToA))
    try await waitForRack { camera.readCount > reads && camera.driveCount > 20 }
    camera.holdNextSafetyRead(latency: 0.3)
    defer { camera.releaseSafetyRead() }
    let preflightReads = camera.readCount
    var sequence: Int64 = 6
    for _ in 0..<50 {
        if camera.readCount > preflightReads { break }
        let sleep = camera.advanceClockBeforeNextSleep(0.02)
        await controller.observe(cameraObservation(sequence))
        sequence += 1
        try await waitForRack {
            camera.slept(after: sleep) || camera.readCount > preflightReads
        }
    }
    #expect(camera.readCount > preflightReads)
    let before = await controller.snapshot()
    let drives = camera.driveCount
    #expect(before.busy)
    if stopDuringRead {
        let stops = camera.stopCount
        controller.requestStop()
        #expect(camera.stopCount > stops)
        try await waitForRack { (await controller.snapshot()).phase == .stopped }
    }
    camera.releaseSafetyRead()
    try await waitForRack { !(await controller.snapshot()).busy }
    let after = await controller.snapshot()
    #expect(camera.driveCount == drives)
    #expect(after.stepPosition == before.stepPosition)
    #expect(after.program.marks == before.program.marks)
    #expect(after.referenceValid)
    #expect(after.phase == (stopDuringRead ? .stopped : .failed))
    let events = await controller.diagnostics().events
    #expect(
        events.contains { $0.runID == before.runID && $0.kind == "maintenanceBudgetExceeded" }
            == !stopDuringRead)
    await controller.close()
}

private func progressNudge(towardNear: Bool = false) throws -> FocusRackEngine {
    var engine = try FocusRackEngine(
        configuration: FocusRackEngine.productionConfiguration, adaptive: true,
        profile: .tenBy160Experiment)
    engine.observe(productionContext(0), at: 0)
    try engine.nudge(towardNear: towardNear, steps: 10, at: 0)
    return engine
}

@Test(arguments: [true, false])
func rackNudgeProgressCountsAcknowledgedFineStepsAndIgnoresElapsedTime(towardNear: Bool) throws {
    var engine = try progressNudge(towardNear: towardNear)
    var now = 0.0
    #expect(
        engine.state(at: now).nudgeProgress == .init(towardNear: towardNear, steps: 10, percent: 0))
    for index in 0..<10 {
        let action = engine.nextAction(at: now)
        #expect(action.signedPulses == (towardNear ? -16 : 16))
        if index == 3 {
            engine.complete(runID: action.runID - 1, commandID: index, outcome: 0, at: now)
            engine.complete(runID: action.runID, commandID: index - 1, outcome: 0, at: now)
            #expect(engine.state(at: now + 1).nudgeProgress?.percent == 30)
        }
        now += 0.02
        engine.complete(runID: action.runID, commandID: index, outcome: 0, at: now)
        if index < 9 {
            #expect(engine.state(at: now).nudgeProgress?.percent == (index + 1) * 10)
            #expect(engine.state(at: now).capabilities.canStop)
            #expect(!engine.state(at: now).capabilities.canNudge)
        }
    }
    let completed = engine.state(at: now)
    #expect(completed.nudgeProgress == nil)
    #expect(completed.completedSteps == 10)
    #expect(completed.stepPosition == (towardNear ? -10 : 10))
    #expect(completed.phase == .complete)
    #expect(completed.message.isEmpty)
}

@Test(arguments: [0, 3, 4])
func rackNudgeProgressRemainsDuringStopSettlementWithoutCreditingUnknownMovement(outcome: Int)
    throws
{
    var engine = try progressNudge()
    var now = 0.0
    for index in 0..<3 {
        let action = engine.nextAction(at: now)
        now += 0.02
        engine.complete(runID: action.runID, commandID: index, outcome: 0, at: now)
    }
    let held = engine.nextAction(at: now)
    engine.requestStop(at: now + 0.001)
    #expect(engine.state(at: now).phase == .stopping)
    #expect(engine.state(at: now).nudgeProgress?.percent == 30)
    #expect(engine.state(at: now).capabilities.canStop)
    engine.complete(runID: held.runID, commandID: 3, outcome: outcome, at: now + 0.02)
    let settled = engine.state(at: now + 0.02)
    #expect(settled.nudgeProgress == nil)
    #expect(settled.completedSteps == (outcome == 0 ? 4 : 3))
    #expect(settled.stepPosition == (outcome == 0 ? 4 : nil))
    if outcome != 0 { #expect(!settled.message.isEmpty) }
    engine.complete(runID: held.runID, commandID: 3, outcome: 0, at: now + 0.03)
    #expect(engine.state(at: now + 0.03).nudgeProgress == nil)
    #expect(engine.state(at: now + 0.03).stepPosition == settled.stepPosition)
}

@Test func rackNudgeProgressClearsOnReferenceLossAndDoesNotDescribeOtherMoves() throws {
    var interrupted = try progressNudge()
    for index in 0..<3 {
        let time = Double(index) * 0.02
        let action = interrupted.nextAction(at: time)
        interrupted.complete(runID: action.runID, commandID: index, outcome: 0, at: time + 0.02)
    }
    let held = interrupted.nextAction(at: 0.06)
    interrupted.interrupt(reason: "Synthetic reference lost.", at: 0.061)
    #expect(interrupted.state(at: 0.061).busy)
    #expect(interrupted.state(at: 0.061).nudgeProgress?.percent == 30)
    #expect(!interrupted.state(at: 0.061).referenceValid)
    interrupted.complete(runID: held.runID, commandID: 3, outcome: 0, at: 0.08)
    #expect(interrupted.state(at: 0.08).nudgeProgress == nil)
    #expect(!interrupted.state(at: 0.08).referenceValid)

    var engine = try productionWithMarks()
    try engine.seek(markID: "B", at: 0.4)
    #expect(engine.state(at: 0.4).busy)
    #expect(engine.state(at: 0.4).totalSteps == 4)
    #expect(engine.state(at: 0.4).nudgeProgress == nil)
    for index in 0..<4 {
        let time = 0.4 + Double(index) * 0.03
        engine.observe(productionContext(time), at: time)
        let action = engine.nextAction(at: time)
        engine.complete(runID: action.runID, commandID: index, outcome: 0, at: time + 0.02)
    }
    #expect(engine.state(at: 0.51).message.isEmpty)
    try engine.run(reverse: true, at: 0.51)
    #expect(engine.state(at: 0.51).busy)
    #expect(engine.state(at: 0.51).nudgeProgress == nil)
    engine.requestStop(at: 0.52)
    try engine.reset(at: 0.53)
    #expect(engine.state(at: 0.53).nudgeProgress == nil)
}

@Test func rackNudgeProgressRoundTripsAndOldStateWithoutMetadataStillDecodes() throws {
    var state = FocusRackState.initial
    state.nudgeProgress = .init(towardNear: true, steps: 10, percent: 30)
    let data = try JSONEncoder().encode(state)
    #expect(
        try JSONDecoder().decode(FocusRackState.self, from: data).nudgeProgress
            == state.nudgeProgress)
    var object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    let progress = try #require(object.removeValue(forKey: "nudgeProgress") as? [String: Any])
    #expect(Set(progress.keys) == ["towardNear", "steps", "percent"])
    let oldData = try JSONSerialization.data(withJSONObject: object)
    #expect(try JSONDecoder().decode(FocusRackState.self, from: oldData).nudgeProgress == nil)
}

@Test func rackControllerNormalizesProductionEasingWithoutChangingLegacyTemplateDecode()
    async throws
{
    let camera = RackFakeCamera()
    let controller = FocusRackController(
        driver: camera.access, transition: .init(duration: 3, easing: .easeInOut),
        clock: camera.clock)
    #expect((await controller.snapshot()).transition.easing == .linear)
    try await controller.handle(.setTransition(.init(duration: 4, delay: 2, easing: .easeInOut)))
    #expect((await controller.snapshot()).transition.easing == .linear)
    try await controller.handle(.updateTiming(.init(duration: 5, easing: .easeInOut)))
    let edited = await controller.snapshot()
    #expect(edited.transition.easing == .linear)
    #expect(edited.transition.duration == 5 && edited.transition.delay == 2)
    let saved =
        #"[{"name":"Saved ease","transition":{"fromMark":"A","toMark":"B","duration":6,"delay":1,"easing":"easeInOut"}}]"#
    let templates = try FocusRackTemplateCodec.decode(Data(saved.utf8))
    let legacy = try #require(templates.first)
    #expect(legacy.transition.easing == .easeInOut)
    try await controller.handle(.applyTemplate(legacy))
    let loaded = await controller.snapshot()
    #expect(loaded.transition.easing == .linear)
    #expect(loaded.program.transitions.first?.easing == .linear)
    #expect(loaded.transition.duration == 6 && loaded.transition.delay == 1)
    #expect(legacy.transition.easing == .easeInOut)
    #expect(camera.driveCount == 0)
    await controller.close()
}

@Test func rackIdleSuspensionKeepsMarksAndRevokesQueuedMovementUntilFreshResume() async throws {
    let camera = RackFakeCamera()
    let controller = try await controllerWithTwoMarks(camera)
    let before = await controller.snapshot()
    let queued = controller.makeIntentTicket()
    controller.suspend()
    controller.requestStop()
    await #expect(throws: FocusRackError.referenceUnavailable) {
        try await controller.handle(.nudge(towardNear: true, steps: 1), ticket: queued)
    }
    var hidden = cameraObservation(4)
    hidden.foregroundOwner = false
    await controller.observe(hidden)
    let suspended = await controller.snapshot()
    #expect(suspended.referenceValid)
    #expect(suspended.program.marks == before.program.marks)
    #expect(suspended.stepPosition == before.stepPosition)
    #expect(!suspended.capabilities.canNudge)
    let reads = camera.readCount
    await controller.observe(cameraObservation(4))
    try await waitForRack { camera.readCount > reads }
    #expect(!(await controller.snapshot()).capabilities.canNudge)
    await controller.observe(cameraObservation(5))
    try await waitForRack { await controller.snapshot().capabilities.canNudge }
    let resumed = await controller.snapshot()
    #expect(resumed.program.marks == before.program.marks)
    #expect(resumed.stepPosition == before.stepPosition)
    #expect(!resumed.busy)
    #expect(camera.driveCount == 2)
    #expect(!resumed.message.contains("setup changed"))
    await controller.close()
}

@Test(arguments: [NikonFocusRackDriveOutcome.complete, .cancelledReady, .cancelledUnconfirmed])
func rackContextLossCancelsNativeMovementAndAccountsForItsActualOutcome(
    outcome: NikonFocusRackDriveOutcome
) async throws {
    let camera = RackFakeCamera()
    let controller = try await controllerWithTwoMarks(camera)
    camera.holdNextDrive()
    defer { camera.finish(.uncertain) }
    try await controller.handle(.nudge(towardNear: false, steps: 10))
    try await waitForRack { camera.driveCount == 3 }
    let stops = camera.stopCount
    await controller.observe(cameraObservation(5, age: 3))
    #expect(camera.stopCount > stops)
    #expect((await controller.snapshot()).phase == .stopping)
    camera.finish(outcome)
    try await waitForRack { !(await controller.snapshot()).busy }
    let settled = await controller.snapshot()
    #expect(settled.referenceValid == (outcome == .complete))
    #expect(settled.stepPosition == (outcome == .complete ? 3 : nil))
    #expect(camera.driveCount == 3)
    await controller.close()
}

@Test func rackUnavailableObservationRevokesTicketsWithoutErasingIdleMarks() async throws {
    let camera = RackFakeCamera()
    let controller = try await controllerWithTwoMarks(camera)
    let queued = controller.makeIntentTicket()
    await controller.observe(cameraObservation(4, age: 3))
    #expect((await controller.snapshot()).referenceValid)
    let reads = camera.readCount
    await controller.observe(cameraObservation(5))
    try await waitForRack { camera.readCount > reads }
    #expect(!(await controller.snapshot()).capabilities.canNudge)
    await controller.observe(cameraObservation(6))
    try await waitForRack { await controller.snapshot().capabilities.canNudge }
    await #expect(throws: FocusRackError.referenceUnavailable) {
        try await controller.handle(.nudge(towardNear: true, steps: 1), ticket: queued)
    }
    #expect(camera.driveCount == 2)
    await controller.close()
}

@Test func rackPendingRevalidationCannotAdmitANewIntentBeforeTheReadReturns() async throws {
    let camera = RackFakeCamera()
    let controller = try await controllerWithTwoMarks(camera)
    camera.holdNextSafetyRead()
    let reads = camera.readCount
    await controller.observe(cameraObservation(4, age: 3))
    try await waitForRack { camera.readCount > reads }
    await controller.observe(cameraObservation(5))
    await #expect(throws: FocusRackError.referenceUnavailable) {
        try await controller.handle(.nudge(towardNear: true, steps: 1))
    }
    #expect(camera.driveCount == 2)
    camera.releaseSafetyRead()
    try await Task.sleep(for: .milliseconds(20))
    #expect(!(await controller.snapshot()).capabilities.canNudge)
    await controller.observe(cameraObservation(6))
    try await waitForRack { await controller.snapshot().capabilities.canNudge }
    #expect(!(await controller.snapshot()).busy)
    #expect(camera.driveCount == 2)
    await controller.close()
}
