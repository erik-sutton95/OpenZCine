import Foundation

/// Pulse units and command timing used by the deterministic rack engine.
public struct FocusRackConfiguration: Codable, Equatable, Sendable {
    /// Base pulse quantum used to measure session-relative marks.
    public var pulsesPerStep: Int
    /// Minimum quiet interval after confirmed command completion, swept during qualification.
    public var commandInterval: Double
    /// Requested A/B timing; marks are never stored in this value.
    public var transition: FocusRackTransition

    /// Creates a configuration without issuing camera commands.
    public init(
        pulsesPerStep: Int = 8, commandInterval: Double = 0.08,
        transition: FocusRackTransition = .init()
    ) {
        self.pulsesPerStep = pulsesPerStep
        self.commandInterval = commandInterval
        self.transition = transition
    }
}

/// Raw accepted-frame evidence; both shells use the Nikon tracking policy in Swift.
public struct FocusRackFocusObservation: Codable, Equatable, Sendable {
    /// Explicit target-tracking status from the live-view header.
    public var trackingAFActive: Bool
    /// Subject detection can be enabled without an active tracking lock.
    public var subjectDetectionActive: Bool
    /// Number of AF boxes in this frame.
    public var boxCount: Int
    /// Selected subject index, when the frame reports one.
    public var selectedBoxIndex: Int?

    /// Copies actual frame metadata without deciding eligibility in a shell.
    public init(
        trackingAFActive: Bool, subjectDetectionActive: Bool, boxCount: Int,
        selectedBoxIndex: Int?
    ) {
        self.trackingAFActive = trackingAFActive
        self.subjectDetectionActive = subjectDetectionActive
        self.boxCount = boxCount
        self.selectedBoxIndex = selectedBoxIndex
    }

    /// True for explicit tracking or the Nikon policy's latched-subject evidence.
    public var trackingActive: Bool {
        PTPLiveViewFocusInfo.isTrackingLatched(
            trackingAFActive: trackingAFActive, subjectDetectionActive: subjectDetectionActive,
            boxCount: boxCount, selectedBoxIndex: selectedBoxIndex)
    }
}

/// Shell observations used by the shared safety policy. Timestamps use one monotonic clock.
public struct FocusRackContext: Codable, Equatable, Sendable {
    public var sessionID: String
    public var connected: Bool
    public var movieMode: Bool
    public var foregroundOwner: Bool
    public var focusMode: String?
    public var focus: FocusRackFocusObservation?
    public var frameTimestamp: Double?
    public var safetyTimestamp: Double?
    public var focusSettled: Bool?
    public var lens: String?
    public var focalLength: String?
    public var recording: Bool
    public var frameSequence: Int64?
    public var focusArea: String?
    public var focusSubject: String?

    /// Creates an observation from actual session and accepted-frame state.
    public init(
        sessionID: String, connected: Bool, movieMode: Bool, foregroundOwner: Bool,
        focusMode: String?, focus: FocusRackFocusObservation?, frameTimestamp: Double?,
        safetyTimestamp: Double? = nil, focusSettled: Bool? = nil, lens: String?,
        focalLength: String?, recording: Bool, frameSequence: Int64? = nil,
        focusArea: String? = nil, focusSubject: String? = nil
    ) {
        self.sessionID = sessionID
        self.connected = connected
        self.movieMode = movieMode
        self.foregroundOwner = foregroundOwner
        self.focusMode = focusMode
        self.focus = focus
        self.frameTimestamp = frameTimestamp
        self.safetyTimestamp = safetyTimestamp
        self.focusSettled = focusSettled
        self.lens = lens
        self.focalLength = focalLength
        self.recording = recording
        self.frameSequence = frameSequence
        self.focusArea = focusArea
        self.focusSubject = focusSubject
    }

    /// Explains why movement is unavailable; unknown safety observations fail closed.
    public func unavailableReason(at timestamp: Double) -> String? {
        unavailableReason(at: timestamp, requiresFreshSafety: true)
    }

    // Observation-only checks may wait for an already serialized safety refresh to finish.
    func unavailableReason(at timestamp: Double, requiresFreshSafety: Bool) -> String? {
        if !connected { return "Connect a real camera." }
        if !movieMode { return "Use movie mode." }
        if !foregroundOwner { return "Keep the live monitor open with local camera control." }
        if focusMode != "AF-S" { return "Select AF-S in FOCUS before testing." }
        guard let focus else { return "Wait for camera focus metadata." }
        if focus.trackingActive { return "Turn tracking off in FOCUS before setting marks." }
        if focusSettled != true {
            return "Wait for autofocus and external focus commands to settle."
        }
        if requiresFreshSafety {
            guard let safetyTimestamp, safetyTimestamp.isFinite,
                timestamp >= safetyTimestamp, timestamp - safetyTimestamp <= 2
            else { return "Wait for fresh camera focus and lens readings." }
        }
        guard let frameTimestamp, frameTimestamp.isFinite,
            timestamp >= frameTimestamp, timestamp - frameTimestamp <= 2
        else { return "Wait for a fresh real camera frame." }
        return nil
    }
}

/// The next bounded action consumed only by the shared production controller.
public struct FocusRackEngineAction: Codable, Equatable, Sendable {
    public let kind: String
    public let runID: Int64
    public let commandID: Int?
    public let signedPulses: Int?
    public let waitSeconds: Double?
}

/// Execution ledger shared by the engine and its production controller.
struct FocusRackEngineSnapshot: Sendable {
    let phase: String
    let message: String
    /// Recovery guidance for an uncertain focus reference.
    let recoveryInstruction: String?
    let runID: Int64
    let stepPosition: Int?
    let marks: [FocusRackMark]
    let completedSteps: Int
    let totalSteps: Int
    let canCapture: Bool
    let busy: Bool
    let configuration: FocusRackConfiguration
    let context: FocusRackContext?
    /// Measured command costs currently used by the planner.
    let calibrationTimings: [Int: Double]
}

/// Deterministic session-local rack state machine, advanced by the production controller.
public struct FocusRackEngine: Sendable {
    private var configuration: FocusRackConfiguration
    private var context: FocusRackContext?
    private var referenceContext: FocusRackContext?
    private var configurationChanged = false
    private(set) var configurationRevision = 0
    private var readinessFrameAfter: Double?
    private var program = FocusRackProgram(marks: [], transitions: [.init()])
    private var marks: [FocusRackMark] {
        get { program.marks }
        set { program.marks = newValue }
    }
    private var captureRevision: Int64 = 0
    private var position: Int? = 0
    private var phase = "idle"
    private var message = "Focus the first subject, then set A."
    private var runID: Int64
    private var trajectory: FocusRackMovementPlan?
    private var plannedDuration: Double?
    private var lastRunTransition: FocusRackTransition?
    private var firstCommandAt: Double?
    private var lastCommandFinishedAt: Double?
    private let adaptive: Bool
    private let profile: FocusRackProfile
    private var completedUnits = 0
    private var totalUnits = 0
    private var activeNudge: (towardNear: Bool, steps: Int)?
    private var preparingLens = false
    private(set) var safetyReadBudget = 0.0
    private var runSafetyReadBudget = 0.0
    private var startedAt = 0.0
    private var enforcesTiming = false
    private var nextStep = 0
    private var completedMaintenanceReads: Set<Int> = []
    private var pendingMaintenanceRead: (step: Int, configuration: Int)?
    private var inFlight:
        (
            id: Int, signedStep: Int, sessionID: String, startedAt: Double,
            configurationRevision: Int
        )?
    private var commandTimings: [Int: FocusRackCommandTiming] = [:]
    private var calibrationKey: FocusRackCalibrationKey?
    private var lastMovementAt: Double?
    private var lastCommandSettledAt: Double?
    private var unconfirmedSession: String?
    private var awaitingExternalFocus = false
    private var stopRequested = false
    private var pauseRequested = false
    private var pausedAt: Double?
    private var accumulatedPause = 0.0
    private var timingSlip = 0.0
    private var finishedAt: Double?
    private var hasStarted = false

    /// Creates an inert state machine; the controller seeds run IDs from monotonic microseconds.
    public init(
        configuration: FocusRackConfiguration = .init(), initialRunID: Int64 = 0,
        adaptive: Bool = false, profile: FocusRackProfile = .adaptive
    )
        throws
    {
        guard (1...32767).contains(configuration.pulsesPerStep),
            configuration.commandInterval.isFinite, configuration.commandInterval >= 0,
            initialRunID >= 0, initialRunID < .max - 100_000,
            !adaptive || configuration.pulsesPerStep == 16
        else { throw FocusRackError.invalidConfiguration }
        self.configuration = configuration
        self.adaptive = adaptive
        self.profile = profile
        program.transitions = [configuration.transition]
        runID = initialRunID
    }

    /// Updates motion admission without discarding idle marks when evidence is unavailable.
    public mutating func observe(_ observation: FocusRackContext, at timestamp: Double) {
        let previous = context
        context = observation
        if awaitingExternalFocus, observation.focusSettled == true {
            lastMovementAt = timestamp
            awaitingExternalFocus = false
        }
        if let reference = referenceContext, reference.sessionID != observation.sessionID,
            !marks.isEmpty || trajectory != nil || inFlight != nil
        {
            interrupt(reason: "Camera session changed. Reset both marks.", at: timestamp)
            return
        }
        if let reference = referenceContext, !marks.isEmpty,
            let safetyAt = observation.safetyTimestamp,
            safetyAt.isFinite, timestamp >= safetyAt, timestamp - safetyAt <= 2,
            reference.movieMode != observation.movieMode
                || [
                    (reference.lens, observation.lens),
                    (reference.focalLength, observation.focalLength),
                    (reference.focusMode, observation.focusMode),
                    (reference.focusArea, observation.focusArea),
                    (reference.focusSubject, observation.focusSubject),
                ].contains(where: { old, new in
                    guard let old, let new else { return false }
                    return old != new
                })
        {
            clearPreparation()
            configurationChanged = true
            configurationRevision += 1
            referenceContext = observation
            commandTimings = [:]
            requestStop(at: timestamp)
        }
        if observation.unavailableReason(at: timestamp) != nil {
            requestStop(at: timestamp)
        } else if preparingLens && observation.recording
            || previous?.recording == true && !observation.recording && trajectory != nil
        {
            requestStop(at: timestamp)
        }
    }

    // Fresh readiness requires a later accepted image, without implying that focus moved.
    mutating func requireReadinessFrame(at timestamp: Double) {
        lastMovementAt = timestamp
        if !marks.isEmpty { readinessFrameAfter = timestamp }
    }

    /// Discards the old relative reference. An unsettled transaction must finish first.
    public mutating func reset(at timestamp: Double) throws {
        guard inFlight == nil, trajectory == nil else { throw FocusRackError.movementPending }
        guard context?.focusSettled == true else { throw FocusRackError.movementPending }
        if let unconfirmedSession,
            context?.sessionID == unconfirmedSession || context?.connected != true
        {
            throw FocusRackError.reconnectRequired
        }
        position = 0
        clearPreparation()
        activeNudge = nil
        commandTimings = [:]
        marks = []
        pauseRequested = false
        pausedAt = nil
        referenceContext = context
        configurationChanged = false
        readinessFrameAfter = nil
        lastMovementAt = timestamp
        unconfirmedSession = nil
        awaitingExternalFocus = false
        phase = "idle"
        nextStep = 0
        completedUnits = 0
        totalUnits = 0
        hasStarted = false
        plannedDuration = nil
        firstCommandAt = nil
        lastCommandFinishedAt = nil
        finishedAt = nil
        message = "Focus A, set A, then use Near/Far to focus B."
    }

    /// Captures/replaces A or B only after acknowledged movement and a new live frame.
    public mutating func capture(markID: String, at timestamp: Double) throws {
        try requireReady(at: timestamp)
        guard markID == "A" || markID == "B", let position else {
            throw FocusRackError.referenceUnavailable
        }
        guard isFrameAfterMovement else { throw FocusRackError.freshFrameRequired }
        if let other = marks.first(where: { $0.id != markID }), other.stepPosition == position {
            throw FocusRackError.samePosition
        }
        clearPreparation()
        if marks.isEmpty { referenceContext = context }
        marks.removeAll { $0.id == markID }
        captureRevision += 1
        let identity = context?.frameSequence.map {
            FocusRackCaptureIdentity(
                markID: markID, revision: captureRevision,
                sessionID: context?.sessionID ?? "", frameSequence: $0)
        }
        marks.append(.init(id: markID, stepPosition: position, captureIdentity: identity))
        marks.sort { $0.id < $1.id }
        message = "Set \(markID) at relative step \(position)."
    }

    /// Starts one to one hundred identical increments after an explicit operator action.
    /// Each increment is acknowledged separately; Stop discards the remaining ones.
    public mutating func nudge(towardNear: Bool, steps: Int = 1, at timestamp: Double) throws {
        guard (1...100).contains(steps) else { throw FocusRackError.invalidConfiguration }
        try begin(
            signedSteps: towardNear ? -steps : steps,
            duration: 1,
            delay: 0, easing: .linear, enforcesTiming: false, at: timestamp)
        activeNudge = (towardNear, steps)
    }

    /// Explicitly repositions using bounded chunks while retaining the original mark units.
    public mutating func seek(markID: String, at timestamp: Double) throws {
        guard let target = marks.first(where: { $0.id == markID }), let position else {
            throw FocusRackError.marksRequired
        }
        let steps = target.stepPosition - position
        guard steps != 0 else { throw FocusRackError.samePosition }
        try begin(
            signedSteps: steps,
            duration: 1,
            delay: 0,
            easing: .linear, enforcesTiming: false, grouped: true, at: timestamp)
    }

    /// Measures bounded command sizes in one explicit traversal between the current marks.
    /// Preparation requires recording stopped and never moves beyond either endpoint.
    public mutating func calibrate(at timestamp: Double) throws {
        try requireReady(at: timestamp)
        guard context?.recording != true else { throw FocusRackError.recordingInProgress }
        guard profile == .calibratedFineExperiment, marks.count == 2 else {
            throw FocusRackError.marksRequired
        }
        guard let current = marks.first(where: { $0.stepPosition == position }) else {
            throw FocusRackError.notAtStart
        }
        guard let target = marks.first(where: { $0.id != current.id }), let position else {
            throw FocusRackError.marksRequired
        }
        try begin(
            signedSteps: target.stepPosition - position, duration: 1, delay: 0,
            easing: .linear, enforcesTiming: false, preparingLens: true, at: timestamp)
    }

    private mutating func clearPreparation() {
        preparingLens = false
    }

    /// Runs the requested transition only from its start mark; it never silently repositions.
    public mutating func run(reverse: Bool, at timestamp: Double) throws {
        let move = program.transitions[0]
        let startID = reverse ? move.toMark : move.fromMark
        let endID = reverse ? move.fromMark : move.toMark
        guard let start = marks.first(where: { $0.id == startID }),
            let end = marks.first(where: { $0.id == endID })
        else { throw FocusRackError.marksRequired }
        guard position == start.stepPosition else { throw FocusRackError.notAtStart }
        try begin(
            signedSteps: end.stepPosition - start.stepPosition, duration: move.duration,
            delay: move.delay, easing: move.easing,
            enforcesTiming: move.durationMode == .timed, grouped: true, at: timestamp)
    }

    /// Runs the selected duration in an explicit direction, preserving marks and delay.
    public mutating func run(direction: FocusRackDirection, at timestamp: Double) throws {
        let previous = program.transitions[0]
        var transition = previous
        transition.fromMark = direction == .aToB ? "A" : "B"
        transition.toMark = direction == .aToB ? "B" : "A"
        transition.durationMode = .timed
        try setTransition(transition, at: timestamp)
        do { try run(reverse: false, at: timestamp) } catch {
            program.transitions[0] = previous
            throw error
        }
    }

    /// Returns one serialized adapter action. Timing growth extends the remaining cadence.
    public mutating func nextAction(at timestamp: Double) -> FocusRackEngineAction {
        let idle = FocusRackEngineAction(
            kind: "idle", runID: runID, commandID: nil, signedPulses: nil, waitSeconds: nil)
        guard let trajectory, inFlight == nil, pendingMaintenanceRead == nil, !stopRequested
        else { return idle }
        if pauseRequested {
            return .init(
                kind: "wait", runID: runID, commandID: nil, signedPulses: nil, waitSeconds: 0.1)
        }
        let unavailable =
            context?.unavailableReason(at: timestamp)
            ?? (hasReadinessFrame ? nil : "Wait for a fresh real camera frame.")
        guard let reason = unavailable else {
            if enforcesTiming, commandCost(trajectory) >= 2 {
                failMaintenance(at: timestamp)
                return idle
            }
            var due = commandTime(trajectory.offsets[nextStep])
            if let offset = trajectory.maintenanceReadOffsets?[nextStep],
                !completedMaintenanceReads.contains(nextStep)
            {
                let readAt = max(
                    commandTime(offset),
                    (lastCommandSettledAt ?? -.infinity) + configuration.commandInterval)
                let refreshAt = min(readAt, safetyRefreshAt(for: trajectory, at: timestamp))
                if timestamp < refreshAt {
                    return .init(
                        kind: "wait", runID: runID, commandID: nil, signedPulses: nil,
                        waitSeconds: min(0.1, refreshAt - timestamp))
                }
                extendTiming(by: max(0, timestamp - readAt))
                return beginSafetyRead()
            }
            if timestamp >= safetyRefreshAt(for: trajectory, at: timestamp) {
                return beginSafetyRead()
            }
            due = commandTime(trajectory.offsets[nextStep])
            if timestamp < due {
                return .init(
                    kind: "wait", runID: runID, commandID: nil, signedPulses: nil,
                    waitSeconds: min(
                        0.1, due - timestamp,
                        safetyRefreshAt(for: trajectory, at: timestamp) - timestamp))
            }
            extendTiming(by: max(0, timestamp - due))
            // Native admission may lag host dispatch. Space from confirmed completion so queued
            // commands cannot compress physical activations, even across separate nudges.
            if let lastCommandSettledAt,
                timestamp < lastCommandSettledAt + configuration.commandInterval
            {
                return .init(
                    kind: "wait", runID: runID, commandID: nil, signedPulses: nil,
                    waitSeconds: min(
                        0.1, lastCommandSettledAt + configuration.commandInterval - timestamp))
            }
            let signedUnits = trajectory.chunks[nextStep]
            if firstCommandAt == nil { firstCommandAt = timestamp }
            inFlight = (
                nextStep, signedUnits, context?.sessionID ?? "", timestamp, configurationRevision
            )
            phase = "moving"
            return .init(
                kind: "drive", runID: runID, commandID: nextStep,
                signedPulses: signedUnits * configuration.pulsesPerStep, waitSeconds: nil)
        }
        requestStop(at: timestamp)
        message = reason
        return idle
    }

    /// Records the additive native rack outcome wire value; stale callbacks are ignored.
    public mutating func complete(
        runID completedRun: Int64, commandID: Int, outcome: Int, at timestamp: Double
    ) {
        guard completedRun == runID, let command = inFlight, command.id == commandID else { return }
        inFlight = nil
        lastCommandFinishedAt = timestamp
        lastCommandSettledAt = timestamp
        if outcome == 0 {
            if command.configurationRevision == configurationRevision {
                commandTimings[abs(command.signedStep), default: .init()].record(
                    max(0, timestamp - command.startedAt))
            }
            completedUnits += abs(command.signedStep)
            if let position { self.position = position + command.signedStep }
            lastMovementAt = timestamp
            nextStep += 1
            if stopRequested {
                activeNudge = nil
                trajectory = nil
                finishedAt = timestamp
                phase = position == nil ? "uncertain" : "stopped"
                return
            }
            if let trajectory, nextStep == trajectory.offsets.count {
                activeNudge = nil
                self.trajectory = nil
                finishedAt = timestamp
                phase = "complete"
                message = "Complete."
                preparingLens = false
            } else if pauseRequested {
                pausedAt = timestamp
                phase = "paused"
                message = "Paused. Resume continues the remaining move."
            }
        } else {
            activeNudge = nil
            preparingLens = false
            trajectory = nil
            finishedAt = timestamp
            switch outcome {
            case 2, 6:
                phase = outcome == 2 ? "stepTooSmall" : "stopped"
                message =
                    outcome == 2
                    ? "The camera could not make this small adjustment."
                    : "Stopped before activation."
            case 0x10000...:
                phase = "refused"
                message =
                    "Camera refused activation (\(String(format: "0x%04X", outcome & 0xFFFF)))."
            default:
                position = nil
                if outcome == 4 || outcome == 5 { unconfirmedSession = command.sessionID }
                phase = outcome == 4 ? "stopUnconfirmed" : "uncertain"
                message =
                    switch outcome {
                    case 3: "Stopped and ready; partial movement is unknown. Reset both marks."
                    case 4, 5:
                        "Camera readiness is unconfirmed. Reconnect the camera before resetting marks."
                    default: "Movement or stop is unconfirmed. Reset both marks."
                    }
            }
        }
    }

    /// Stops future scheduling immediately. The adapter also requests native cancellation.
    public mutating func requestStop(at timestamp: Double) {
        guard !stopRequested, trajectory != nil || inFlight != nil else { return }
        preparingLens = false
        stopRequested = true
        pauseRequested = false
        if let pausedAt {
            accumulatedPause += timestamp - pausedAt
            self.pausedAt = nil
        }
        finishedAt = timestamp
        if inFlight == nil {
            activeNudge = nil
            trajectory = nil
            phase = "stopped"
            message = "Stopped. Focus will not return automatically."
        } else {
            phase = "stopping"
            message = "Stopping - waiting for the camera."
        }
    }

    /// Invalidates the reference after an observed external action or safety-evidence loss.
    public mutating func interrupt(reason: String, at timestamp: Double) {
        guard position != nil else { return }
        requestStop(at: timestamp)
        position = nil
        phase = inFlight == nil ? "uncertain" : "stopping"
        message = reason
    }

    /// Allows initial AF acquisition; established marks are invalidated by outside focus moves.
    public mutating func externalFocusAction(at timestamp: Double) {
        guard marks.isEmpty, trajectory == nil, inFlight == nil, position != nil else {
            interrupt(reason: "External focus changed. Reset both marks.", at: timestamp)
            return
        }
        position = 0
        lastMovementAt = timestamp
        awaitingExternalFocus = true
        message = "Wait for focus to settle, then set A from a fresh live frame."
    }

    /// Returns the current execution ledger without triggering camera work.
    func snapshot(at timestamp: Double) -> FocusRackEngineSnapshot {
        let unavailable =
            context?.unavailableReason(at: timestamp)
            ?? (context == nil ? "Connect a real camera." : nil)
        return .init(
            phase: phase, message: unavailable ?? message,
            recoveryInstruction: recoveryInstruction, runID: runID, stepPosition: position,
            marks: marks, completedSteps: completedUnits,
            totalSteps: totalUnits,
            canCapture: unavailable == nil && position != nil && trajectory == nil
                && inFlight == nil && isFrameAfterMovement,
            busy: trajectory != nil || inFlight != nil, configuration: currentConfiguration,
            context: context, calibrationTimings: calibrationTimings)
    }

    var calibrationTimings: [Int: Double] {
        Dictionary(
            uniqueKeysWithValues: commandTimings.map {
                ($0.key * configuration.pulsesPerStep, $0.value.longest)
            }.filter { $0.1 > 0 })
    }

    mutating func detachCalibrationKey(at timestamp: Double) {
        guard calibrationKey != nil else { return }
        calibrationKey = nil
        commandTimings = [:]
        clearPreparation()
        configurationRevision += 1
        interrupt(reason: "Camera control path changed. Reset marks.", at: timestamp)
    }

    mutating func bindCalibrationKey(_ key: FocusRackCalibrationKey, at timestamp: Double) {
        guard calibrationKey != key else { return }
        let previous = calibrationKey
        calibrationKey = key
        commandTimings = [:]
        clearPreparation()
        configurationRevision += 1
        if let previous, previous.cameraID != key.cameraID || previous.transport != key.transport {
            interrupt(reason: "Camera control path changed. Reset marks.", at: timestamp)
        } else if trajectory != nil || inFlight != nil {
            requestStop(at: timestamp)
        }
    }

    func canRestoreCalibration(at timestamp: Double) -> Bool {
        profile == .calibratedFineExperiment && trajectory == nil && inFlight == nil
            && position != nil && context?.unavailableReason(at: timestamp) == nil
            && hasReadinessFrame
    }

    mutating func restoreCalibration(_ calibration: FocusRackCalibration, at timestamp: Double) {
        guard canRestoreCalibration(at: timestamp), let context, calibration.key.matches(context)
        else { return }
        for (pulses, seconds) in calibration.commandDurations.sorted(by: { $0.key < $1.key }) {
            let units = pulses / configuration.pulsesPerStep
            guard seconds > commandTimings[units, default: .init()].longest else { continue }
            commandTimings[units, default: .init()].record(seconds)
        }
    }

    private var recoveryInstruction: String? {
        guard position == nil else { return nil }
        if let unconfirmedSession,
            context?.sessionID == unconfirmedSession || context?.connected != true
        {
            return "Reconnect camera, then reset marks."
        }
        return "Reset marks before moving focus."
    }

    private var hasReadinessFrame: Bool {
        guard let readinessFrameAfter else { return true }
        return (context?.frameTimestamp ?? -.infinity) > readinessFrameAfter
    }

    private var isFrameAfterMovement: Bool {
        guard !awaitingExternalFocus else { return false }
        guard let lastMovementAt else { return true }
        return (context?.frameTimestamp ?? -.infinity) > lastMovementAt
    }

    private func requireReady(at timestamp: Double) throws {
        guard trajectory == nil, inFlight == nil else { throw FocusRackError.movementPending }
        guard position != nil, let context, context.unavailableReason(at: timestamp) == nil,
            hasReadinessFrame
        else {
            throw FocusRackError.referenceUnavailable
        }
    }

    private mutating func begin(
        signedSteps: Int, duration: Double, delay: Double, easing: FocusRackEasing,
        enforcesTiming: Bool, grouped: Bool = false, preparingLens: Bool = false,
        at timestamp: Double
    ) throws {
        try requireReady(at: timestamp)
        let planned =
            preparingLens
            ? try FocusRackPreparation.make(signedSteps: signedSteps)
            : try FocusRackPlanner.make(
                signedSteps: signedSteps, duration: duration, delay: delay, easing: easing,
                quiet: configuration.commandInterval, timings: commandTimings, adaptive: adaptive,
                timed: enforcesTiming, grouped: grouped, profile: profile,
                safetyReadBudget: safetyReadBudget)
        runID += 1
        activeNudge = nil
        self.preparingLens = preparingLens
        trajectory = planned
        plannedDuration = planned.duration
        lastRunTransition = program.transitions[0]
        firstCommandAt = nil
        lastCommandFinishedAt = nil
        completedMaintenanceReads = []
        pendingMaintenanceRead = nil
        runSafetyReadBudget = safetyReadBudget
        if marks.isEmpty { referenceContext = context }
        startedAt = timestamp
        pauseRequested = false
        pausedAt = nil
        accumulatedPause = 0
        timingSlip = 0
        finishedAt = nil
        hasStarted = true
        self.enforcesTiming = enforcesTiming
        completedUnits = 0
        totalUnits = abs(signedSteps)
        nextStep = 0
        stopRequested = false
        phase = delay > 0 ? "countdown" : "ready"
        message = "Moving focus."
    }

    /// Current session program, including its selected transition.
    public var currentProgram: FocusRackProgram { program }

    /// Production settings: fine mark units; native Ready confirmation supplies the movement barrier.
    public static var productionConfiguration: FocusRackConfiguration {
        .init(pulsesPerStep: 16, commandInterval: 0)
    }

    // The controller performs fresh safety reads before this run's timing epoch begins.
    mutating func finishPreflight(runID expected: Int64, at timestamp: Double) {
        guard expected == runID, let previous = trajectory, nextStep == 0, inFlight == nil,
            pendingMaintenanceRead == nil, firstCommandAt == nil, !stopRequested
        else { return }
        if enforcesTiming {
            do {
                let move = program.transitions[0]
                let adjusted = try FocusRackPlanner.make(
                    signedSteps: previous.signedSteps, duration: move.duration,
                    delay: previous.delay, easing: move.easing,
                    quiet: configuration.commandInterval,
                    timings: commandTimings, adaptive: adaptive, timed: true, grouped: true,
                    profile: profile, safetyReadBudget: runSafetyReadBudget)
                trajectory = adjusted
                plannedDuration = adjusted.duration
                completedMaintenanceReads = []
            } catch {
                trajectory = nil
                phase = "failed"
                finishedAt = timestamp
                message = error.localizedDescription
                return
            }
        }
        startedAt = timestamp
        accumulatedPause = 0
        timingSlip = 0
        if pausedAt != nil { pausedAt = timestamp }
    }

    var isTimedRun: Bool { trajectory != nil && enforcesTiming }

    private var actualMovementDuration: Double? {
        guard let firstCommandAt, let lastCommandFinishedAt else { return nil }
        return max(0, lastCommandFinishedAt - firstCommandAt)
    }

    private func commandTime(_ offset: Double) -> Double {
        startedAt + accumulatedPause + timingSlip + offset
    }

    private mutating func extendTiming(by seconds: Double) {
        guard enforcesTiming, seconds > 1e-9, let trajectory else { return }
        timingSlip += seconds
        plannedDuration = trajectory.duration + timingSlip
    }

    private func commandCost(_ plan: FocusRackMovementPlan) -> Double {
        commandTimings[abs(plan.chunks[nextStep])]?.longest
            ?? commandTimings.values.map(\.longest).max() ?? 0
    }

    // Reserve a rolling refresh even when growth has displaced a planned read window.
    private func safetyRefreshAt(for plan: FocusRackMovementPlan, at timestamp: Double) -> Double {
        guard enforcesTiming, let safetyAt = context?.safetyTimestamp else { return .infinity }
        let cost = commandCost(plan)
        if completedMaintenanceReads.contains(nextStep),
            commandTime(plan.offsets[nextStep]) <= timestamp, timestamp + cost < safetyAt + 2
        {
            return .infinity
        }
        return safetyAt + 2 - cost - 0.05
    }

    private mutating func beginSafetyRead() -> FocusRackEngineAction {
        pendingMaintenanceRead = (nextStep, configurationRevision)
        return .init(
            kind: "readSafety", runID: runID, commandID: nextStep,
            signedPulses: nil, waitSeconds: nil)
    }

    // A paused or untimed run cannot justify deferring the periodic safety refresh.
    var scheduledFinish: Double? {
        guard enforcesTiming, let trajectory, !pauseRequested, pausedAt == nil else { return nil }
        return commandTime(trajectory.delay + trajectory.duration)
    }

    // Countdown refreshes remain periodic, including a final read within the initial-age reserve.
    var initialMaintenanceDeadline: Double? {
        guard trajectory?.maintenanceReadOffsets != nil, nextStep == 0 else { return nil }
        return nextCommandDeadline
    }

    func ownsMaintenanceSchedule(at timestamp: Double) -> Bool {
        guard let trajectory, trajectory.maintenanceReadOffsets != nil,
            !pauseRequested, pausedAt == nil
        else { return false }
        return nextStep > 0 || timestamp >= commandTime(trajectory.offsets[0])
    }

    mutating func finishScheduledRead(
        runID expected: Int64, commandID: Int, accepted: Bool, at timestamp: Double
    ) {
        guard expected == runID, let pending = pendingMaintenanceRead,
            pending.step == commandID, pending.configuration == configurationRevision
        else { return }
        pendingMaintenanceRead = nil
        guard let trajectory, !stopRequested, !pauseRequested else { return }
        guard accepted else {
            failMaintenance(at: timestamp)
            return
        }
        guard let safetyAt = context?.safetyTimestamp,
            timestamp + commandCost(trajectory) < safetyAt + 2
        else {
            failMaintenance(at: timestamp)
            return
        }
        completedMaintenanceReads.insert(commandID)
        if let deadline = nextCommandDeadline {
            extendTiming(by: max(0, timestamp - deadline))
        }
    }

    // Late work shifts the remaining cadence instead of sending compressed catch-up commands.
    var nextCommandDeadline: Double? {
        guard enforcesTiming, let trajectory, !pauseRequested, pausedAt == nil,
            !stopRequested, inFlight == nil
        else { return nil }
        return commandTime(trajectory.offsets[nextStep])
    }

    // The read drains before this check. Pause/Resume may deliberately extend the same run's epoch.
    mutating func finishMaintenanceRead(runID expected: Int64, at timestamp: Double) {
        guard expected == runID, let deadline = nextCommandDeadline,
            timestamp > deadline + 1e-9
        else { return }
        extendTiming(by: timestamp - deadline)
    }

    private mutating func failMaintenance(at timestamp: Double) {
        preparingLens = false
        trajectory = nil
        finishedAt = timestamp
        phase = "failed"
        message =
            "Fresh camera readings could not be confirmed. Wait for the camera before retrying."
    }

    var maintenanceReadBudget: Double {
        max(0.1, isTimedRun ? runSafetyReadBudget : safetyReadBudget)
    }

    mutating func recordSafetyRead(startedAt: Double, finishedAt: Double, accepted: Bool) {
        let elapsed = finishedAt - startedAt
        // Qualification is per run, not a permanent prediction from an unrelated idle stall.
        // Late successful reads extend the remaining cadence; their evidence must still be fresh.
        if accepted {
            safetyReadBudget = max(0.1, elapsed)
            if isTimedRun { runSafetyReadBudget = max(runSafetyReadBudget, safetyReadBudget) }
        }
    }

    /// Updates the entire idle transition atomically, preserving session marks.
    public mutating func setTransition(_ transition: FocusRackTransition, at timestamp: Double)
        throws
    {
        guard trajectory == nil, inFlight == nil else { throw FocusRackError.movementPending }
        try FocusRackTemplateCodec.validate(transition)
        program.transitions[0] = transition
    }

    /// Loads timing only, discarding marks while preserving an uncertain-stop latch.
    public mutating func applyTemplate(_ template: FocusRackTemplate, at timestamp: Double) throws {
        let template = try FocusRackTemplateCodec.validate(template)
        try setTransition(template.transition, at: timestamp)
        clearMarks(at: timestamp)
    }

    /// Discards idle session marks without requiring a connection or clearing stop uncertainty.
    public mutating func discardMarks(at timestamp: Double) throws {
        guard trajectory == nil, inFlight == nil else { throw FocusRackError.movementPending }
        clearMarks(at: timestamp)
    }

    private mutating func clearMarks(at timestamp: Double) {
        clearPreparation()
        activeNudge = nil
        marks = []
        nextStep = 0
        completedUnits = 0
        totalUnits = 0
        hasStarted = false
        finishedAt = nil
        if position != nil { position = 0 }
        commandTimings = [:]
        lastMovementAt = timestamp
        referenceContext = context
        configurationChanged = false
        readinessFrameAfter = nil
        if position != nil { phase = "idle" }
    }

    /// Stops scheduling and lets an already admitted increment settle normally.
    public mutating func requestPause(at timestamp: Double) {
        guard trajectory != nil, !stopRequested, !pauseRequested else { return }
        pauseRequested = true
        if inFlight == nil {
            pausedAt = timestamp
            phase = "paused"
        } else {
            phase = "pausing"
        }
        message = "Pausing after the current increment settles."
    }

    /// Continues the same trajectory and run identity, excluding paused wall time.
    public mutating func resume(at timestamp: Double) throws {
        guard let pausedAt, phase == "paused", trajectory != nil, inFlight == nil,
            position != nil, context?.unavailableReason(at: timestamp) == nil, hasReadinessFrame
        else { throw FocusRackError.referenceUnavailable }
        accumulatedPause += timestamp - pausedAt
        self.pausedAt = nil
        pauseRequested = false
        phase = "ready"
        message = "Resuming the remaining move."
    }

    /// Typed production state and control admission derived from the same execution ledger.
    public func state(at timestamp: Double) -> FocusRackState {
        let raw = snapshot(at: timestamp)
        var state = FocusRackState.initial
        state.phase = FocusRackPhase(rawValue: phase) ?? .failed
        state.message = raw.message
        state.recoveryInstruction = raw.recoveryInstruction
        state.runID = runID
        state.program = program
        state.transition = program.transitions[0]
        state.estimatedDuration = plannedDuration
        state.actualMovementDuration = actualMovementDuration
        state.direction = state.transition.fromMark == "A" ? .aToB : .bToA
        state.stepPosition = position
        state.completedSteps = raw.completedSteps
        state.totalSteps = raw.totalSteps
        state.busy = raw.busy
        if let activeNudge, state.busy {
            state.nudgeProgress = .init(
                towardNear: activeNudge.towardNear, steps: activeNudge.steps,
                percent: completedUnits * 100 / totalUnits)
        }
        state.referenceValid = position != nil
        state.captures = marks.compactMap(\.captureIdentity)
        state.activeElapsed =
            hasStarted
            ? max(0, (pausedAt ?? finishedAt ?? timestamp) - startedAt - accumulatedPause) : 0
        state.remainingDelay = max(0, state.transition.delay - state.activeElapsed)
        let expectedDuration =
            state.transition.durationMode == .timed
            ? plannedDuration ?? state.transition.duration : trajectory?.estimatedDuration ?? 0
        state.remainingDuration = max(
            0, expectedDuration - max(0, state.activeElapsed - state.transition.delay))
        let ready =
            context?.unavailableReason(at: timestamp) == nil && context != nil && position != nil
            && hasReadinessFrame
        let idle = trajectory == nil && inFlight == nil
        var caps = FocusRackCapabilities()
        caps.canCaptureA =
            raw.canCapture && !marks.contains { $0.id == "B" && $0.stepPosition == position }
        caps.canCaptureB =
            raw.canCapture && !marks.contains { $0.id == "A" && $0.stepPosition == position }
        caps.canNudge = idle && ready
        caps.canEditTiming = idle
        caps.canReset =
            idle && context?.focusSettled == true && context?.connected == true
            && (unconfirmedSession == nil || unconfirmedSession != context?.sessionID)
        caps.canPause = trajectory != nil && !pauseRequested && !stopRequested
        caps.canResume = phase == "paused" && ready
        caps.canStop = trajectory != nil || inFlight != nil
        caps.canAutofocus = idle && marks.isEmpty && ready
        caps.canGoToA =
            idle && ready && marks.contains { $0.id == "A" && $0.stepPosition != position }
        caps.canGoToB =
            idle && ready && marks.contains { $0.id == "B" && $0.stepPosition != position }
        state.capabilities = caps
        state.calibration = calibrationAction(ready: ready, idle: idle)
        state.preparingLens = preparingLens
        state.preparationRecommended = false
        if state.referenceValid, state.calibration != nil,
            let preparation = try? FocusRackPreparation.make(
                signedSteps: marks[1].stepPosition - marks[0].stepPosition)
        {
            state.preparationRecommended = preparation.chunks.contains {
                commandTimings[abs($0)]?.count ?? 0 == 0
            }
        }
        if idle { state.estimatedDuration = nil }
        var admissionInstruction: String?
        if idle, let from = marks.first(where: { $0.id == state.transition.fromMark }),
            let to = marks.first(where: { $0.id == state.transition.toMark })
        {
            do {
                let plan = try FocusRackPlanner.make(
                    signedSteps: to.stepPosition - from.stepPosition,
                    duration: state.transition.duration, delay: state.transition.delay,
                    easing: state.transition.easing, quiet: configuration.commandInterval,
                    timings: commandTimings, adaptive: adaptive,
                    timed: true, grouped: true, profile: profile,
                    safetyReadBudget: safetyReadBudget)
                state.minimumDuration = focusRackMinimumForDisplay(plan.minimumDuration)
                state.maximumDuration = plan.maximumDuration
                if idle { state.estimatedDuration = plan.estimatedDuration }
            } catch FocusRackError.calibrationRequired {
                state.admissionMessage = FocusRackError.calibrationRequired.localizedDescription
                admissionInstruction = "Prepare lens in Options"
            } catch FocusRackError.safetyReadUnavailable {
                state.admissionMessage = FocusRackError.safetyReadUnavailable.localizedDescription
                admissionInstruction = "Camera not ready"
            } catch FocusRackError.durationTooShort(let minimum) {
                state.minimumDuration = focusRackMinimumForDisplay(minimum)
                state.admissionMessage =
                    FocusRackError.durationTooShort(minimum: minimum).localizedDescription
            } catch FocusRackError.durationTooLong(let maximum) {
                state.maximumDuration = focusRackMaximumForDisplay(maximum)
                state.admissionMessage =
                    FocusRackError.durationTooLong(maximum: maximum).localizedDescription
            } catch { state.admissionMessage = error.localizedDescription }
        }
        if phase == "paused" {
            state.primary = .init(kind: "resume", title: "Resume", enabled: caps.canResume)
        } else if caps.canPause {
            state.primary = .init(kind: "pause", title: "Pause", enabled: true)
        } else if !idle {
            state.primary = .init(title: phase == "stopping" ? "Stopping…" : "Pausing…")
        } else if position == nil {
            state.primary = .init(kind: "reset", title: "Reset marks", enabled: caps.canReset)
        } else if let start = marks.first(where: { $0.id == state.transition.fromMark }),
            marks.count == 2
        {
            let recording = context?.recording == true
            let direction = state.transition.fromMark + "→" + state.transition.toMark
            let atStart = position == start.stepPosition
            let admissionReason = admissionInstruction ?? "Adjust timing"
            let reason: String? =
                state.admissionMessage != nil
                ? admissionReason
                : !atStart
                    ? "Go to " + start.id + " first"
                    : !ready ? "Camera not ready" : nil
            state.primary = .init(
                kind: recording ? "run" : "rehearse",
                title: (recording ? "Run " : "Rehearse ") + direction,
                enabled: ready && atStart && state.admissionMessage == nil,
                detail: state.playbackDetail, disabledReason: reason)
        }
        state.updateTimedActions(
            recording: context?.recording == true, ready: ready,
            admissionInstruction: admissionInstruction)
        state.admissionMessage = state.admissionMessage?.replacingOccurrences(
            of: "test cadence", with: "current camera cadence")
        let completedCurrentTarget =
            state.phase == .complete && enforcesTiming
            && lastRunTransition == state.transition
        let elapsed =
            completedCurrentTarget ? state.actualMovementDuration : state.estimatedDuration
        if idle || enforcesTiming, state.transition.durationMode == .timed, let elapsed,
            elapsed > state.transition.duration + 0.0005
                || idle && elapsed < state.transition.duration - 0.0005
        {
            let target = state.transition.duration.formatted(
                .number.precision(.fractionLength(0...2)))
            let measured = elapsed.formatted(.number.precision(.fractionLength(0...2)))
            state.timingWarning =
                completedCurrentTarget
                ? "\(target) s target; completed in \(measured) s."
                : "\(target) s target · ~\(measured) s estimated. Timing is advisory."
            state.timingWarningIsEstimate = !completedCurrentTarget
        } else if let maximum = state.maximumDuration, state.transition.duration > maximum {
            state.timingWarning = "This duration may show pauses between focus adjustments."
            state.timingWarningIsEstimate = false
        }
        if context?.unavailableReason(at: timestamp) == nil, position != nil {
            switch state.phase {
            case .idle, .ready:
                if marks.isEmpty {
                    state.message = "Focus the first subject, then set A."
                } else if marks.count == 1 {
                    state.message =
                        "Use Near/Far to focus the other subject, then set the second mark."
                } else {
                    state.message = "Ready to move between your marks."
                }
            case .countdown: state.message = "Starting after the delay."
            case .moving: state.message = "Moving focus."
            case .pausing: state.message = "Pausing after the current adjustment settles."
            case .paused: state.message = "Paused. Resume continues the remaining move."
            case .stopping: state.message = "Stopping. Waiting for the camera."
            case .stopped: state.message = "Stopped. Focus stays where it stopped."
            case .complete: state.message = ""
            case .failed: break
            case .stepTooSmall: state.message = "The camera could not make this small adjustment."
            case .refused:
                state.message =
                    "The camera refused the focus move. Wait until it is ready, then try again."
            case .uncertain, .stopUnconfirmed: break
            }
        }
        if context?.unavailableReason(at: timestamp) == nil, position != nil {
            if !hasReadinessFrame {
                state.message = "Wait for a fresh real camera frame."
            } else if configurationChanged,
                [.idle, .ready, .stopped, .complete].contains(state.phase)
            {
                state.message = "Camera setup changed. Check A and B; reset marks if needed."
            }
        }
        state.message = state.message.replacingOccurrences(
            of: "before testing.", with: "to use Focus Rack.")
        return state
    }

    private func calibrationAction(ready: Bool, idle: Bool) -> FocusRackPrimaryAction? {
        guard profile == .calibratedFineExperiment, marks.count == 2,
            FocusRackPreparation.supports(span: abs(marks[1].stepPosition - marks[0].stepPosition))
        else { return nil }
        let current = marks.first(where: { $0.stepPosition == position })
        let target = marks.first(where: { $0.id != current?.id })
        let recording = context?.recording == true
        return .init(
            kind: "calibrate", title: "Prepare lens",
            enabled: ready && idle && current != nil && !recording,
            detail: recording
                ? "Stop recording before preparing the lens"
                : current.flatMap { start in
                    target.map { "One pass \(start.id)→\($0.id) · recording stopped" }
                }
                    ?? "Go to A or B first",
            disabledReason: recording
                ? "Stop recording before preparing the lens"
                : current == nil ? "Go to A or B first" : !ready ? "Camera not ready" : nil)
    }

    private var currentConfiguration: FocusRackConfiguration {
        var value = configuration
        value.transition = program.transitions[0]
        return value
    }
}
