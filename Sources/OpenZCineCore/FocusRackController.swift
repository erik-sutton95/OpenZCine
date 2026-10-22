import Foundation

/// The native camera integration owns wire transactions and revocable command authority.
public protocol FocusRackDriver: Sendable {
    /// Whether the captured native connection still owns admitted local camera control.
    var isCurrent: @Sendable () -> Bool { get }
    /// Prepares a fresh, revocable receipt without activating the lens.
    var prepareRun: @Sendable (Int64) -> Bool { get }
    /// Stops a receipt synchronously without waiting for the actor or camera command queue.
    var requestStop: @Sendable (Int64) -> Void { get }
    /// Delivers one bounded pulse chunk; the Boolean selects near and the outcome accounts for uncertainty.
    var driveChunk: @Sendable (Int64, Bool, UInt32) async -> NikonFocusRackDriveOutcome { get }
    /// Reads complete fresh focus/lens evidence and confirms native readiness before returning.
    var refreshSafety: @Sendable () async throws -> NikonFocusRackSafetySnapshot { get }
}

extension NikonFocusRackAccess: FocusRackDriver {}

/// One monotonic clock for scheduling, accepted images, readback, and deterministic tests.
public struct FocusRackClock: Sendable {
    /// Current seconds in this controller's monotonic epoch.
    public let now: @Sendable () -> Double
    /// Suspends for a duration in seconds, remaining cancellable.
    public let sleep: @Sendable (Double) async throws -> Void

    /// Creates a clock whose timestamps share an epoch across every callback.
    public init(
        now: @escaping @Sendable () -> Double,
        sleep: @escaping @Sendable (Double) async throws -> Void
    ) {
        self.now = now
        self.sleep = sleep
    }

    /// Process-local monotonic timestamps; no platform epoch enters the controller.
    public static let monotonic = FocusRackClock(
        now: { ProcessInfo.processInfo.systemUptime },
        sleep: { try await Task.sleep(for: .seconds($0)) })
}

/// Opaque admission frozen synchronously before an adapter queues an operator intent.
public struct FocusRackIntentTicket: Sendable {
    fileprivate let controllerID: UUID
    fileprivate let generation: UInt64
}

private enum FocusRackControlAction {
    case stop, suspend
    case invalidate(String)

    var priority: Int {
        switch self {
        case .stop: 0
        case .suspend: 1
        case .invalidate: 2
        }
    }
}

private final class FocusRackControlGate: @unchecked Sendable {
    private let lock = NSLock()
    private let identity = UUID()
    private var generation: UInt64 = 0
    private var runID: Int64?
    private var action = FocusRackControlAction.stop
    private var cancellationRequested = false

    func makeIntentTicket() -> FocusRackIntentTicket {
        lock.withLock { .init(controllerID: identity, generation: generation) }
    }

    func admits(_ ticket: FocusRackIntentTicket) -> Bool {
        lock.withLock { ticket.controllerID == identity && ticket.generation == generation }
    }

    func snapshot() -> (
        generation: UInt64, runID: Int64?, action: FocusRackControlAction,
        cancellationRequested: Bool
    ) {
        lock.withLock { (generation, runID, action, cancellationRequested) }
    }

    func stop(_ action: FocusRackControlAction = .stop) -> (generation: UInt64, runID: Int64?) {
        lock.withLock {
            generation &+= 1
            if action.priority >= self.action.priority { self.action = action }
            cancellationRequested = true
            return (generation, runID)
        }
    }

    func register(_ runID: Int64, generation expected: UInt64) -> Bool {
        lock.withLock {
            guard generation == expected else { return false }
            self.runID = runID
            cancellationRequested = false
            return true
        }
    }

    func acknowledge(_ expected: UInt64) {
        lock.withLock { if generation == expected { action = .stop } }
    }

    func retire(_ runID: Int64) {
        lock.withLock { if self.runID == runID { self.runID = nil } }
    }
}

/// Shared production runner. The shells submit observations and semantic intents only.
public actor FocusRackController {
    private let driver: any FocusRackDriver
    private let clock: FocusRackClock
    private nonisolated let gate = FocusRackControlGate()
    private nonisolated let stopNative: @Sendable (Int64) -> Void
    private var handledGeneration: UInt64 = 0
    private var engine: FocusRackEngine
    private var observation: FocusRackObservation?
    private var acceptedSequence: Int64?
    private var acceptedAt: Double?
    private var acceptedFocus: FocusRackFocusObservation?
    private var acceptedFocusResult: String?
    private var safety: NikonFocusRackSafetySnapshot?
    private var safetyAt: Double?
    private var nextSafetyAt = 0.0
    private var needsReadinessFrameBarrier = true
    private var nativeRun: Int64?
    private var preparedRun: Int64?
    private var pumpTask: Task<Void, Never>?
    private var closed = false
    private var referenceWasValid = true
    private var contextWasAvailable = false
    private var subscribers: [UUID: AsyncStream<FocusRackState>.Continuation] = [:]

    /// Creates an inert runner with fine 16-pulse mark units and adaptive bounded playback.
    public init(
        driver: any FocusRackDriver, transition: FocusRackTransition = .init(),
        clock: FocusRackClock = .monotonic, profile: FocusRackProfile = .adaptive
    ) {
        self.driver = driver
        self.stopNative = driver.requestStop
        self.clock = clock
        var configuration = FocusRackEngine.productionConfiguration
        configuration.transition = Self.linearTransition(transition)
        // The fixed quantum and quiet interval satisfy the engine constructor's invariants.
        guard
            let engine = try? FocusRackEngine(
                configuration: configuration,
                initialRunID: max(1, Int64(clock.now() * 1_000_000)), adaptive: true,
                profile: profile)
        else {
            preconditionFailure("Invalid fixed focus-rack configuration")
        }
        self.engine = engine
    }

    /// Freezes this controller's admission before any Task, actor, or facade queue hop.
    public nonisolated func makeIntentTicket() -> FocusRackIntentTicket { gate.makeIntentTicket() }

    /// Applies an intent and optional frozen image observation atomically. Adapters pass a ticket
    /// captured at intent receipt; omitting it preserves the existing direct-call API.
    public nonisolated func handle(
        _ intent: FocusRackIntent,
        observation: FocusRackObservation? = nil,
        ticket: FocusRackIntentTicket? = nil
    ) async throws {
        var admission = ticket ?? gate.makeIntentTicket()
        guard gate.admits(admission) else { throw FocusRackError.referenceUnavailable }
        if case .stop = intent {
            requestStop()
            admission = gate.makeIntentTicket()
        }
        try await apply(intent, observation: observation, generation: admission.generation)
    }

    /// Publishes native Stop immediately, before an actor, sleep, or command queue can wait.
    public nonisolated func requestStop() {
        let stopped = gate.stop()
        if let runID = stopped.runID { stopNative(runID) }
        Task { await self.drainControlAndPublish() }
    }

    /// Revokes queued movement immediately while retaining acknowledged position and marks.
    public nonisolated func suspend() {
        let stopped = gate.stop(.suspend)
        if let runID = stopped.runID { stopNative(runID) }
        Task { await self.drainControlAndPublish() }
    }

    /// Revokes queued movement and invalidates its reference after an unknown external change.
    public nonisolated func invalidate(reason: String) {
        let stopped = gate.stop(.invalidate(reason))
        if let runID = stopped.runID { stopNative(runID) }
        Task { await self.drainControlAndPublish() }
    }

    /// Accepts raw lifecycle/focus observations and stamps each new real image exactly once.
    public func observe(_ value: FocusRackObservation) {
        guard !closed else { return }
        synchronizeControl()
        accept(value)
        refreshEngineContext()
        publish()
        ensurePump()
    }

    /// Returns the current typed state without triggering movement.
    public func snapshot() -> FocusRackState {
        var state = engine.state(at: clock.now())
        if engine.isTimedRun, preparedRun != state.runID {
            state.activeElapsed = 0
            state.remainingDelay = state.transition.delay
            state.remainingDuration = state.transition.duration
        }
        return state
    }

    /// Bounded local timing evidence, excluding images, credentials and camera serial numbers.
    public func diagnostics() -> FocusRackDiagnostics {
        engine.snapshot(at: clock.now(), includeEvents: true)
    }

    /// Subscribes to state, including an immediate initial value; subscription starts no movement.
    public func states() -> AsyncStream<FocusRackState> {
        let id = UUID()
        let pair = AsyncStream<FocusRackState>.makeStream(bufferingPolicy: .bufferingNewest(1))
        subscribers[id] = pair.continuation
        pair.continuation.yield(snapshot())
        pair.continuation.onTermination = { [weak self] _ in
            Task { await self?.removeSubscriber(id) }
        }
        if closed { pair.continuation.finish() }
        return pair.stream
    }

    /// Retires an actual native connection. Accessory dismissal uses discardMarks instead,
    /// preserving uncertainty and reconnect requirements when the panel is reopened.
    public func close() async {
        guard !closed else { return }
        invalidate(reason: "Camera controller retired. Reset marks.")
        synchronizeControl()
        closed = true
        pumpTask?.cancel()
        await pumpTask?.value
        pumpTask = nil
        for subscriber in subscribers.values { subscriber.finish() }
        subscribers.removeAll()
    }

    private func apply(
        _ intent: FocusRackIntent, observation value: FocusRackObservation?,
        generation: UInt64
    ) throws {
        guard !closed else { throw FocusRackError.referenceUnavailable }
        synchronizeControl()
        guard generation == gate.snapshot().generation else {
            throw FocusRackError.referenceUnavailable
        }
        if let value { accept(value) }
        refreshEngineContext()
        let now = clock.now()
        defer {
            publish()
            ensurePump()
        }
        guard generation == gate.snapshot().generation else {
            throw FocusRackError.referenceUnavailable
        }
        switch intent {
        case .capture(let markID, let expected):
            guard acceptedSequence == expected else { throw FocusRackError.freshFrameRequired }
            try engine.capture(markID: markID, at: now)
        case .nudge(let near, let steps): try engine.nudge(towardNear: near, steps: steps, at: now)
        case .goTo(let mark): try engine.seek(markID: mark, at: now)
        case .calibrate: try engine.calibrate(at: now)
        case .run(let direction): try engine.run(direction: direction, at: now)
        case .setTransition(let transition):
            try engine.setTransition(Self.linearTransition(transition), at: now)
        case .updateTiming(let update):
            let transition = try engine.currentProgram.transitions[0].applying(update)
            try engine.setTransition(Self.linearTransition(transition), at: now)
        case .setDirection(let direction):
            var transition = engine.currentProgram.transitions[0]
            transition.fromMark = direction == .aToB ? "A" : "B"
            transition.toMark = direction == .aToB ? "B" : "A"
            try engine.setTransition(transition, at: now)
        case .start: try engine.run(reverse: false, at: now)
        case .pause: engine.requestPause(at: now)
        case .resume: try engine.resume(at: now)
        case .stop: engine.requestStop(at: now)
        case .reset: try engine.reset(at: now)
        case .discardMarks: try engine.discardMarks(at: now)
        case .applyTemplate(let template):
            try engine.applyTemplate(
                .init(name: template.name, transition: Self.linearTransition(template.transition)),
                at: now)
        case .externalFocusAction:
            safety = nil
            safetyAt = nil
            nextSafetyAt = 0
            needsReadinessFrameBarrier = true
            engine.externalFocusAction(at: now)
        case .performPrimary, .primary:
            let primary = engine.state(at: now).primary
            guard primary.enabled else { throw FocusRackError.referenceUnavailable }
            switch primary.kind {
            case "goTo": try engine.seek(markID: primary.markID ?? "", at: now)
            case "run", "rehearse": try engine.run(reverse: false, at: now)
            case "pause": engine.requestPause(at: now)
            case "resume": try engine.resume(at: now)
            case "reset": try engine.reset(at: now)
            default: throw FocusRackError.invalidConfiguration
            }
        }
    }

    private static func linearTransition(_ transition: FocusRackTransition) -> FocusRackTransition {
        var transition = transition
        transition.easing = .linear
        return transition
    }

    private func accept(_ value: FocusRackObservation) {
        let previous = observation
        if previous?.sessionID == value.sessionID,
            let sequence = value.frameSequence, let acceptedSequence, sequence < acceptedSequence
        {
            return
        }
        let now = clock.now()
        if previous?.sessionID != value.sessionID {
            acceptedSequence = nil
            acceptedAt = nil
            acceptedFocus = nil
            acceptedFocusResult = nil
            safety = nil
            safetyAt = nil
            nextSafetyAt = 0
            needsReadinessFrameBarrier = true
        } else if previous?.externalFocusRevision != value.externalFocusRevision {
            safety = nil
            safetyAt = nil
            nextSafetyAt = 0
            needsReadinessFrameBarrier = true
            engine.externalFocusAction(at: now)
        }
        observation = value
        if let sequence = value.frameSequence, sequence >= 0,
            acceptedSequence == nil || sequence > (acceptedSequence ?? -1)
        {
            let oldResult = acceptedFocusResult
            acceptedSequence = sequence
            acceptedAt =
                value.frameAgeSeconds.isFinite && value.frameAgeSeconds >= 0
                ? now - value.frameAgeSeconds : nil
            acceptedFocus = value.focus
            acceptedFocusResult = value.focusResult?.lowercased()
            if oldResult == "unknown", let result = acceptedFocusResult, result != "unknown" {
                engine.externalFocusAction(at: now)
                safety = nil
                safetyAt = nil
                nextSafetyAt = 0
                needsReadinessFrameBarrier = true
            }
        } else if value.frameSequence == nil {
            acceptedAt = nil
            acceptedFocus = nil
        }
        if !value.connected || !value.foregroundOwner {
            safety = nil
            safetyAt = nil
            nextSafetyAt = 0
            needsReadinessFrameBarrier = true
        }
        if previous?.recording == true, !value.recording {
            let stopped = gate.stop()
            if let run = stopped.runID { stopNative(run) }
            synchronizeControl()
        }
    }

    private func refreshEngineContext() {
        guard let observation else { return }
        let now = clock.now()
        let context = FocusRackContext(
            sessionID: observation.sessionID,
            connected: observation.connected && driver.isCurrent(),
            movieMode: safety?.movieMode ?? false,
            foregroundOwner: observation.foregroundOwner, focusMode: safety?.focusMode,
            focus: acceptedFocus, frameTimestamp: acceptedAt, safetyTimestamp: safetyAt,
            focusSettled: safety != nil && observation.externalFocusIdle,
            lens: safety?.lens, focalLength: safety?.focalLength,
            recording: observation.recording,
            frameSequence: acceptedSequence, focusArea: safety?.focusArea,
            focusSubject: safety?.focusSubject)
        let available = context.unavailableReason(at: now) == nil
        let previousRevision = engine.configurationRevision
        engine.observe(context, at: now)
        if (contextWasAvailable && !available)
            || engine.configurationRevision != previousRevision
        {
            safety = nil
            safetyAt = nil
            needsReadinessFrameBarrier = true
            nextSafetyAt = 0
            let alreadyCancelled = gate.snapshot().cancellationRequested
            let stopped = gate.stop()
            if !alreadyCancelled, let runID = stopped.runID { stopNative(runID) }
            synchronizeControl()
            var pending = context
            pending.safetyTimestamp = nil
            pending.focusSettled = false
            engine.observe(pending, at: now)
            contextWasAvailable = false
            return
        }
        contextWasAvailable = available
    }

    private func ensurePump() {
        guard pumpTask == nil, !closed, observation != nil else { return }
        pumpTask = Task { [weak self] in await self?.pump() }
    }

    private func pump() async {
        defer {
            if let run = nativeRun {
                stopNative(run)
                gate.retire(run)
                nativeRun = nil
            }
            pumpTask = nil
        }
        while !closed, !Task.isCancelled {
            synchronizeControl()
            refreshEngineContext()
            let pending = engine.snapshot(at: clock.now())
            let requiresPreflight = engine.isTimedRun && pending.busy && nativeRun != pending.runID
            if !requiresPreflight, let observation, observation.connected,
                observation.foregroundOwner,
                observation.externalFocusIdle, driver.isCurrent(), shouldRefreshSafety
            {
                await readSafety(observation)
                synchronizeControl()
                refreshEngineContext()
            }
            let before = engine.snapshot(at: clock.now())
            if before.busy, nativeRun != before.runID {
                let generation = gate.snapshot().generation
                guard gate.register(before.runID, generation: generation),
                    driver.prepareRun(before.runID)
                else {
                    engine.interrupt(
                        reason: "Camera control is unavailable. Reset marks.", at: clock.now())
                    publish()
                    continue
                }
                nativeRun = before.runID
                synchronizeControl()
                refreshEngineContext()
                if engine.isTimedRun {
                    if let observation { await readSafety(observation) }
                    synchronizeControl()
                    refreshEngineContext()
                    guard engine.snapshot(at: clock.now()).runID == before.runID else { continue }
                    engine.finishPreflight(runID: before.runID, at: clock.now())
                    preparedRun = before.runID
                }
            }
            let action = engine.nextAction(at: clock.now())
            publish()
            if action.kind == "drive", let pulses = action.signedPulses,
                let command = action.commandID
            {
                let outcome = await driver.driveChunk(action.runID, pulses < 0, UInt32(abs(pulses)))
                synchronizeControl()
                engine.complete(
                    runID: action.runID, commandID: command,
                    outcome: Int(outcome.wireValue), at: clock.now())
                refreshEngineContext()
                publish()
                continue
            }
            if !engine.snapshot(at: clock.now()).busy, let run = nativeRun {
                stopNative(run)
                gate.retire(run)
                nativeRun = nil
            }
            if !engine.snapshot(at: clock.now()).busy,
                observation?.connected != true || observation?.foregroundOwner != true
            {
                return
            }
            do { try await clock.sleep(min(0.05, action.waitSeconds ?? 0.05)) } catch { break }
        }
    }

    private var shouldRefreshSafety: Bool {
        let now = clock.now()
        guard now >= nextSafetyAt else { return false }
        if let safetyAt, let finish = engine.scheduledFinish,
            max(now, finish) + max(0.1, engine.safetyReadBudget) < safetyAt + 2
        {
            return false
        }
        if let deadline = engine.nextCommandDeadline {
            return now + max(0.1, engine.safetyReadBudget) <= deadline
        }
        return true
    }

    private func readSafety(_ initial: FocusRackObservation) async {
        let started = clock.now()
        defer {
            let finished = clock.now()
            engine.recordSafetyRead(
                startedAt: started, finishedAt: finished, accepted: safetyAt == started)
        }
        let generation = gate.snapshot().generation
        do {
            let fresh = try await driver.refreshSafety()
            // A superseded read cannot erase still-valid evidence after Stop before movement.
            guard gate.snapshot().generation == generation else { return }
            guard !closed, !Task.isCancelled, driver.isCurrent(),
                observation?.sessionID == initial.sessionID,
                observation?.externalFocusRevision == initial.externalFocusRevision,
                observation?.externalFocusIdle == true, observation?.foregroundOwner == true,
                clock.now() - started <= 2
            else {
                safety = nil
                safetyAt = nil
                return
            }
            safety = fresh
            safetyAt = started
            if needsReadinessFrameBarrier {
                engine.requireReadinessFrame(at: clock.now())
                needsReadinessFrameBarrier = false
            }
        } catch {
            guard gate.snapshot().generation == generation else { return }
            safety = nil
            safetyAt = nil
        }
        nextSafetyAt = clock.now() + 0.5
    }

    private func synchronizeControl() {
        let value = gate.snapshot()
        guard value.generation != handledGeneration else { return }
        handledGeneration = value.generation
        switch value.action {
        case .invalidate(let reason):
            safety = nil
            safetyAt = nil
            needsReadinessFrameBarrier = true
            engine.interrupt(reason: reason, at: clock.now())
            referenceWasValid = false
        case .suspend:
            safety = nil
            safetyAt = nil
            nextSafetyAt = 0
            needsReadinessFrameBarrier = true
            engine.requestStop(at: clock.now())
        case .stop:
            engine.requestStop(at: clock.now())
        }
        gate.acknowledge(value.generation)
    }

    private func drainControlAndPublish() {
        synchronizeControl()
        refreshEngineContext()
        publish()
    }
    private func publish() {
        let raw = engine.snapshot(at: clock.now())
        if referenceWasValid, raw.stepPosition == nil {
            let alreadyCancelled = gate.snapshot().cancellationRequested
            let stopped = gate.stop(.invalidate(raw.message))
            if !alreadyCancelled, let run = stopped.runID { stopNative(run) }
            synchronizeControl()
        }
        if raw.phase == "stopping", !gate.snapshot().cancellationRequested {
            let stopped = gate.stop()
            if let runID = stopped.runID { stopNative(runID) }
            synchronizeControl()
        }
        referenceWasValid = raw.stepPosition != nil
        let state = snapshot()
        for subscriber in subscribers.values { subscriber.yield(state) }
    }
    private func removeSubscriber(_ id: UUID) { subscribers.removeValue(forKey: id) }
}
