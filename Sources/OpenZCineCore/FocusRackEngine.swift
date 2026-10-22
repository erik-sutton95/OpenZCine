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
        if !connected { return "Connect a real camera." }
        if !movieMode { return "Use movie mode." }
        if !foregroundOwner { return "Keep the live monitor open with local camera control." }
        if focusMode != "AF-S" { return "Select AF-S in FOCUS before testing." }
        guard let focus else { return "Wait for camera focus metadata." }
        if focus.trackingActive { return "Turn tracking off in FOCUS before setting marks." }
        if focusSettled != true {
            return "Wait for autofocus and external focus commands to settle."
        }
        guard let safetyTimestamp, safetyTimestamp.isFinite,
            timestamp >= safetyTimestamp, timestamp - safetyTimestamp <= 2
        else { return "Wait for fresh camera focus and lens readings." }
        guard let frameTimestamp, frameTimestamp.isFinite,
            timestamp >= frameTimestamp, timestamp - frameTimestamp <= 2
        else { return "Wait for a fresh real camera frame." }
        return nil
    }
}

/// One bounded diagnostic event. No credentials, camera serial numbers, or image data are stored.
public struct FocusRackDiagnosticEvent: Codable, Equatable, Sendable {
    public let kind: String
    public let timestamp: Double
    public let runID: Int64
    public let commandID: Int?
    public let signedPulses: Int?
    public let scheduledAt: Double?
    public let outcome: Int?
    public let note: String?
}

/// The next bounded action consumed only by the shared production controller.
public struct FocusRackEngineAction: Codable, Equatable, Sendable {
    public let kind: String
    public let runID: Int64
    public let commandID: Int?
    public let signedPulses: Int?
    public let waitSeconds: Double?
}

/// Bounded diagnostic values exported by the production controller.
public struct FocusRackDiagnostics: Codable, Sendable {
    public let phase: String
    public let message: String
    /// Short recovery guidance that must remain visible outside scrolling diagnostic details.
    public let recoveryInstruction: String?
    public let runID: Int64
    public let stepPosition: Int?
    public let marks: [FocusRackMark]
    public let completedSteps: Int
    public let totalSteps: Int
    public let canCapture: Bool
    public let busy: Bool
    public let configuration: FocusRackConfiguration
    public let context: FocusRackContext?
    public let events: [FocusRackDiagnosticEvent]
    public let omittedEvents: Int
}

/// Deterministic session-local rack state machine, advanced by the production controller.
public struct FocusRackEngine: Sendable {
    private var configuration: FocusRackConfiguration
    private var context: FocusRackContext?
    private var referenceContext: FocusRackContext?
    private var program = FocusRackProgram(marks: [], transitions: [.init()])
    private var marks: [FocusRackMark] {
        get { program.marks }
        set { program.marks = newValue }
    }
    private var captureRevision: Int64 = 0
    private var position: Int? = 0
    private var phase = "idle"
    private var message = "UNQUALIFIED - set a fixed zoom, use AF-S, and adjust focus only here."
    private var runID: Int64
    private var trajectory: FocusRackMovementPlan?
    private let adaptive: Bool
    private let profile: FocusRackProfile
    private var completedUnits = 0
    private var totalUnits = 0
    private var activeNudge: (towardNear: Bool, steps: Int)?
    private var startedAt = 0.0
    private var enforcesTiming = false
    private var nextStep = 0
    private var inFlight: (id: Int, signedStep: Int, sessionID: String, startedAt: Double)?
    private var commandTimings: [Int: FocusRackCommandTiming] = [:]
    private var lastMovementAt: Double?
    private var lastCommandSettledAt: Double?
    private var unconfirmedSession: String?
    private var awaitingExternalFocus = false
    private var stopRequested = false
    private var pauseRequested = false
    private var pausedAt: Double?
    private var accumulatedPause = 0.0
    private var finishedAt: Double?
    private var hasStarted = false
    private var events: [FocusRackDiagnosticEvent] = []
    private var omittedEvents = 0

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

    /// Updates safety evidence; a known external change cannot silently preserve captured marks.
    public mutating func observe(_ observation: FocusRackContext, at timestamp: Double) {
        let previous = context
        context = observation
        if awaitingExternalFocus, observation.focusSettled == true {
            lastMovementAt = timestamp
            awaitingExternalFocus = false
        }
        let identityChanged =
            referenceContext.map {
                $0.sessionID != observation.sessionID || $0.lens != observation.lens
                    || $0.focalLength != observation.focalLength
                    || $0.focusArea != observation.focusArea
                    || $0.focusSubject != observation.focusSubject
            } ?? false
        let recordingStopped = previous?.recording == true && !observation.recording
        if identityChanged, !marks.isEmpty || trajectory != nil || inFlight != nil {
            interrupt(
                reason: "Session, lens, zoom, or focus settings changed. Reset both marks.",
                at: timestamp)
        } else if let reason = observation.unavailableReason(at: timestamp),
            !marks.isEmpty || trajectory != nil || inFlight != nil
        {
            interrupt(reason: reason, at: timestamp)
        } else if recordingStopped, trajectory != nil {
            requestStop(at: timestamp)
        }
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
        activeNudge = nil
        commandTimings = [:]
        marks = []
        pauseRequested = false
        pausedAt = nil
        referenceContext = context
        lastMovementAt = timestamp
        unconfirmedSession = nil
        awaitingExternalFocus = false
        phase = "idle"
        nextStep = 0
        completedUnits = 0
        totalUnits = 0
        hasStarted = false
        finishedAt = nil
        message = "Focus A, set A, then use Near/Far to focus B."
        append("reset", at: timestamp)
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
        referenceContext = context
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
        append("mark", at: timestamp, note: markID)
    }

    /// Starts one to ten identical increments after an explicit operator action.
    /// Each increment is acknowledged separately; Stop discards the remaining ones.
    public mutating func nudge(towardNear: Bool, steps: Int = 1, at timestamp: Double) throws {
        guard (1...10).contains(steps) else { throw FocusRackError.invalidConfiguration }
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

    /// Changes diagnostic timing while idle without changing the pulse quantum or session marks.
    /// This neither starts movement nor persists positions; active runs reject timing changes.
    public mutating func setTiming(
        duration: Double? = nil, easing: FocusRackEasing? = nil, at timestamp: Double
    ) throws {
        var transition = program.transitions[0]
        guard duration != nil || easing != nil else { throw FocusRackError.invalidConfiguration }
        if let duration { transition.duration = duration }
        if let easing { transition.easing = easing }
        try setTransition(transition, at: timestamp)
        let move = program.transitions[0]
        append(
            "timingChanged", at: timestamp,
            note: "duration=\(move.duration) delay=\(move.delay) easing=\(move.easing.rawValue)")
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

    /// Returns one adapter action. Late timed runs halt; positioning retains the minimum cadence.
    public mutating func nextAction(at timestamp: Double) -> FocusRackEngineAction {
        let idle = FocusRackEngineAction(
            kind: "idle", runID: runID, commandID: nil, signedPulses: nil, waitSeconds: nil)
        guard let trajectory, inFlight == nil, !stopRequested else { return idle }
        if pauseRequested {
            return .init(
                kind: "wait", runID: runID, commandID: nil, signedPulses: nil, waitSeconds: 0.1)
        }
        guard let reason = context?.unavailableReason(at: timestamp) else {
            let due = startedAt + accumulatedPause + trajectory.offsets[nextStep]
            if timestamp < due {
                return .init(
                    kind: "wait", runID: runID, commandID: nil, signedPulses: nil,
                    waitSeconds: min(0.1, due - timestamp))
            }
            if enforcesTiming, timestamp - due > max(0.2, trajectory.duration * 0.05) {
                self.trajectory = nil
                finishedAt = timestamp
                phase = "failed"
                message = "Camera cadence missed the requested timing. No catch-up commands sent."
                append("missedDeadline", at: timestamp)
                return idle
            }
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
            inFlight = (nextStep, signedUnits, context?.sessionID ?? "", timestamp)
            phase = "moving"
            append(
                "commandStarted", at: timestamp, commandID: nextStep,
                signedPulses: signedUnits * configuration.pulsesPerStep, scheduledAt: due)
            return .init(
                kind: "drive", runID: runID, commandID: nextStep,
                signedPulses: signedUnits * configuration.pulsesPerStep, waitSeconds: nil)
        }
        interrupt(reason: reason, at: timestamp)
        return idle
    }

    /// Records the additive native rack outcome wire value; stale callbacks are ignored.
    public mutating func complete(
        runID completedRun: Int64, commandID: Int, outcome: Int, at timestamp: Double
    ) {
        guard completedRun == runID, let command = inFlight, command.id == commandID else { return }
        append("commandCompleted", at: timestamp, commandID: commandID, outcome: outcome)
        inFlight = nil
        lastCommandSettledAt = timestamp
        if outcome == 0 {
            commandTimings[abs(command.signedStep), default: .init()].record(
                max(0, timestamp - command.startedAt))
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
                let durationError = abs(
                    timestamp - startedAt - accumulatedPause - trajectory.delay
                        - trajectory.duration)
                if enforcesTiming, durationError > max(0.2, trajectory.duration * 0.05) + 1e-9 {
                    phase = "failed"
                    message =
                        "Focus arrived, but the requested duration was missed. No more movement scheduled."
                    append("missedDeadline", at: timestamp)
                } else {
                    phase = "complete"
                    message = "Complete. Inspect the source recording for sharpness and smoothness."
                    append("runCompleted", at: timestamp)
                }
            } else if pauseRequested {
                pausedAt = timestamp
                phase = "paused"
                message = "Paused. Resume continues the remaining move."
                append("paused", at: timestamp)
            }
        } else {
            activeNudge = nil
            trajectory = nil
            finishedAt = timestamp
            switch outcome {
            case 2, 6:
                phase = outcome == 2 ? "stepTooSmall" : "stopped"
                message =
                    outcome == 2
                    ? "The lens did not move: increase the test increment."
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
        stopRequested = true
        pauseRequested = false
        if let pausedAt {
            accumulatedPause += timestamp - pausedAt
            self.pausedAt = nil
        }
        finishedAt = timestamp
        append("stopRequested", at: timestamp)
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
        append("invalidated", at: timestamp, note: reason)
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
        append("initialFocusAcquisition", at: timestamp)
    }

    /// Produces a bounded trace and actual observations for display or explicit local export.
    public func snapshot(at timestamp: Double, includeEvents: Bool = false)
        -> FocusRackDiagnostics
    {
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
            context: context, events: includeEvents ? events : [], omittedEvents: omittedEvents)
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

    private var isFrameAfterMovement: Bool {
        guard !awaitingExternalFocus else { return false }
        guard let lastMovementAt else { return true }
        return (context?.frameTimestamp ?? -.infinity) > lastMovementAt
    }

    private func requireReady(at timestamp: Double) throws {
        guard trajectory == nil, inFlight == nil else { throw FocusRackError.movementPending }
        guard position != nil, let context, context.unavailableReason(at: timestamp) == nil else {
            throw FocusRackError.referenceUnavailable
        }
    }

    private mutating func begin(
        signedSteps: Int, duration: Double, delay: Double, easing: FocusRackEasing,
        enforcesTiming: Bool, grouped: Bool = false,
        at timestamp: Double
    ) throws {
        try requireReady(at: timestamp)
        let planned = try FocusRackPlanner.make(
            signedSteps: signedSteps, duration: duration, delay: delay, easing: easing,
            quiet: configuration.commandInterval, timings: commandTimings, adaptive: adaptive,
            timed: enforcesTiming, grouped: grouped, profile: profile)
        runID += 1
        activeNudge = nil
        trajectory = planned
        referenceContext = context
        startedAt = timestamp
        pauseRequested = false
        pausedAt = nil
        accumulatedPause = 0
        finishedAt = nil
        hasStarted = true
        self.enforcesTiming = enforcesTiming
        completedUnits = 0
        totalUnits = abs(signedSteps)
        nextStep = 0
        stopRequested = false
        phase = delay > 0 ? "countdown" : "ready"
        message = "Experimental move: \(signedSteps) mark units, \(planned.chunks.count) commands."
        append(
            "runStarted", at: timestamp,
            note:
                "timed=\(enforcesTiming) duration=\(duration) delay=\(delay) easing=\(easing.rawValue) profile=\(profile.rawValue)"
        )
    }

    /// Current session program, including its selected transition.
    public var currentProgram: FocusRackProgram { program }

    /// Production settings: fine mark units; native Ready confirmation supplies the movement barrier.
    public static var productionConfiguration: FocusRackConfiguration {
        .init(pulsesPerStep: 16, commandInterval: 0)
    }

    // The controller performs fresh safety reads before this run's timing epoch begins.
    mutating func finishPreflight(runID expected: Int64, at timestamp: Double) {
        guard expected == runID, trajectory != nil, nextStep == 0, inFlight == nil,
            !stopRequested
        else { return }
        startedAt = timestamp
        accumulatedPause = 0
        if pausedAt != nil { pausedAt = timestamp }
        append("preflightCompleted", at: timestamp)
    }

    var isTimedRun: Bool { trajectory != nil && enforcesTiming }

    // A paused or untimed run cannot justify deferring the periodic safety refresh.
    var scheduledFinish: Double? {
        guard enforcesTiming, let trajectory, !pauseRequested, pausedAt == nil else { return nil }
        return startedAt + accumulatedPause + trajectory.delay + trajectory.duration
    }

    mutating func recordSafetyRead(startedAt: Double, finishedAt: Double, accepted: Bool) {
        append(
            "safetyRead", at: finishedAt, scheduledAt: startedAt,
            note: "elapsed=\(finishedAt - startedAt) accepted=\(accepted)")
    }

    /// Updates the entire idle transition atomically, preserving session marks.
    public mutating func setTransition(_ transition: FocusRackTransition, at timestamp: Double)
        throws
    {
        guard trajectory == nil, inFlight == nil else { throw FocusRackError.movementPending }
        try FocusRackTemplateCodec.validate(transition)
        if program.transitions[0] != transition {
            append(
                "timingChanged", at: timestamp,
                note:
                    "duration=\(transition.duration) delay=\(transition.delay) easing=\(transition.easing.rawValue)"
            )
        }
        program.transitions[0] = transition
    }

    /// Loads timing only, discarding marks while preserving an uncertain-stop latch.
    public mutating func applyTemplate(_ template: FocusRackTemplate, at timestamp: Double) throws {
        let template = try FocusRackTemplateCodec.validate(template)
        try setTransition(template.transition, at: timestamp)
        clearMarks(at: timestamp)
        append("templateLoaded", at: timestamp, note: template.name)
    }

    /// Discards idle session marks without requiring a connection or clearing stop uncertainty.
    public mutating func discardMarks(at timestamp: Double) throws {
        guard trajectory == nil, inFlight == nil else { throw FocusRackError.movementPending }
        clearMarks(at: timestamp)
        append("marksDiscarded", at: timestamp)
    }

    private mutating func clearMarks(at timestamp: Double) {
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
        append("pauseRequested", at: timestamp)
    }

    /// Continues the same trajectory and run identity, excluding paused wall time.
    public mutating func resume(at timestamp: Double) throws {
        guard let pausedAt, phase == "paused", trajectory != nil, inFlight == nil,
            position != nil, context?.unavailableReason(at: timestamp) == nil
        else { throw FocusRackError.referenceUnavailable }
        accumulatedPause += timestamp - pausedAt
        self.pausedAt = nil
        pauseRequested = false
        phase = "ready"
        message = "Resuming the remaining move."
        append("resumed", at: timestamp)
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
            ? state.transition.duration : trajectory?.estimatedDuration ?? 0
        state.remainingDuration = max(
            0, expectedDuration - max(0, state.activeElapsed - state.transition.delay))
        let ready =
            context?.unavailableReason(at: timestamp) == nil && context != nil && position != nil
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
        var admissionInstruction: String?
        if let from = marks.first(where: { $0.id == state.transition.fromMark }),
            let to = marks.first(where: { $0.id == state.transition.toMark })
        {
            do {
                let plan = try FocusRackPlanner.make(
                    signedSteps: to.stepPosition - from.stepPosition,
                    duration: state.transition.duration, delay: state.transition.delay,
                    easing: state.transition.easing, quiet: configuration.commandInterval,
                    timings: commandTimings, adaptive: adaptive,
                    timed: true, grouped: true, profile: profile)
                state.minimumDuration = focusRackMinimumForDisplay(plan.minimumDuration)
                state.maximumDuration = plan.maximumDuration
            } catch FocusRackError.calibrationRequired {
                state.admissionMessage = FocusRackError.calibrationRequired.localizedDescription
                admissionInstruction = "Go to A or B first"
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
                detail: state.transition.playbackDetail, disabledReason: reason)
        }
        state.updateTimedActions(
            recording: context?.recording == true, ready: ready,
            admissionInstruction: admissionInstruction)
        state.admissionMessage = state.admissionMessage?.replacingOccurrences(
            of: "test cadence", with: "current camera cadence")
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
            case .failed:
                state.message =
                    "The requested timing could not be maintained. Adjust the duration and try again."
            case .stepTooSmall: state.message = "The camera could not make this small adjustment."
            case .refused:
                state.message =
                    "The camera refused the focus move. Wait until it is ready, then try again."
            case .uncertain, .stopUnconfirmed: break
            }
        }
        state.message = state.message.replacingOccurrences(
            of: "before testing.", with: "to use Focus Rack.")
        return state
    }

    private var currentConfiguration: FocusRackConfiguration {
        var value = configuration
        value.transition = program.transitions[0]
        return value
    }

    private mutating func append(
        _ kind: String, at timestamp: Double, commandID: Int? = nil, signedPulses: Int? = nil,
        scheduledAt: Double? = nil, outcome: Int? = nil, note: String? = nil
    ) {
        if events.count == 20_000 {
            events.removeFirst(1_000)
            omittedEvents += 1_000
        }
        events.append(
            .init(
                kind: kind, timestamp: timestamp, runID: runID, commandID: commandID,
                signedPulses: signedPulses, scheduledAt: scheduledAt, outcome: outcome, note: note))
    }
}
