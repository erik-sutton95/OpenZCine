import Foundation

/// The selected direction of the two-mark program.
public enum FocusRackDirection: String, Codable, Sendable { case aToB, bToA }

/// Shared execution phases, including acknowledged pause and native stop settlement.
public enum FocusRackPhase: String, Codable, Sendable {
    case idle, countdown, ready, moving, pausing, paused, stopping, stopped, complete, failed
    case stepTooSmall, refused, uncertain, stopUnconfirmed

    /// Operator-facing phase text shared by both native shells.
    public var title: String {
        switch self {
        case .idle: "Set marks"
        case .countdown: "Starting soon"
        case .ready: "Ready"
        case .moving: "Moving"
        case .pausing: "Pausing…"
        case .paused: "Paused"
        case .stopping: "Stopping…"
        case .stopped: "Stopped"
        case .complete: "Complete"
        case .failed: "Unavailable"
        case .stepTooSmall: "Increment too small"
        case .refused: "Camera busy"
        case .uncertain: "Reset marks"
        case .stopUnconfirmed: "Reconnect camera"
        }
    }

}

/// The exact accepted image associated with a successful mark capture.
public struct FocusRackCaptureIdentity: Codable, Equatable, Sendable {
    public let markID: String
    public let revision: Int64
    public let sessionID: String
    public let frameSequence: Int64

    /// Identifies a session-local capture without retaining an image in the portable core.
    public init(markID: String, revision: Int64, sessionID: String, frameSequence: Int64) {
        self.markID = markID
        self.revision = revision
        self.sessionID = sessionID
        self.frameSequence = frameSequence
    }
}

/// One Swift-owned primary control rendered by both shells.
public struct FocusRackPrimaryAction: Codable, Equatable, Sendable {
    public var kind: String
    public var title: String
    public var enabled: Bool
    public var markID: String?
    /// Selected pull duration or Fastest mode, shown beside idle playback.
    public var detail: String?
    /// Short preparation or timing instruction when playback is unavailable.
    public var disabledReason: String?

    /// Creates a semantic action; shells forward performPrimary rather than implementing routing.
    public init(
        kind: String = "none", title: String = "Set A and B", enabled: Bool = false,
        markID: String? = nil, detail: String? = nil, disabledReason: String? = nil
    ) {
        self.kind = kind
        self.title = title
        self.enabled = enabled
        self.markID = markID
        self.detail = detail
        self.disabledReason = disabledReason
    }
}

/// Shared admission for individual operator controls.
public struct FocusRackCapabilities: Codable, Equatable, Sendable {
    public var canCaptureA = false
    public var canCaptureB = false
    public var canNudge = false
    public var canEditTiming = true
    public var canReset = false
    public var canPause = false
    public var canResume = false
    public var canStop = false
    public var canAutofocus = false
    public var canGoToA = false
    public var canGoToB = false

    /// Creates an initially disconnected set of capabilities.
    public init() {}
}

/// A setup nudge identified by the operator's original intent and acknowledged movement only.
public struct FocusRackNudgeProgress: Codable, Equatable, Sendable {
    /// Whether the active setup control moves focus toward near.
    public let towardNear: Bool
    /// Number of fine increments requested by the pressed control.
    public let steps: Int
    /// Whole-number percentage of acknowledged increments, independent of elapsed time.
    public let percent: Int

    /// Creates presentation metadata from the shared completed-movement ledger.
    public init(towardNear: Bool, steps: Int, percent: Int) {
        self.towardNear = towardNear
        self.steps = steps
        self.percent = percent
    }
}

/// Codable production state. Marks, captures and position remain session-local.
public struct FocusRackState: Codable, Sendable {
    public var phase: FocusRackPhase = .idle
    public var message = "Connect a camera to set focus marks."
    public var recoveryInstruction: String?
    public var runID: Int64 = 0
    public var program = FocusRackProgram(marks: [], transitions: [.init()])
    public var transition = FocusRackTransition()
    public var direction: FocusRackDirection = .aToB
    public var stepPosition: Int? = 0
    public var completedSteps = 0
    public var totalSteps = 0
    public var busy = false
    /// Active setup progress; absent for other moves, settled nudges and older state snapshots.
    public var nudgeProgress: FocusRackNudgeProgress?
    /// Next optional finer-increment timing measurement.
    public var calibration: FocusRackPrimaryAction?
    public var referenceValid = true
    public var minimumDuration: Double?
    public var maximumDuration: Double?
    /// Planned execution time; the operator's requested target remains in `transition.duration`.
    public var estimatedDuration: Double?
    /// Observed command-dispatch-to-completion span; not an optical arrival measurement.
    public var actualMovementDuration: Double?
    /// Nonblocking duration estimate or overrun; camera admission is reported separately.
    public var timingWarning: String?
    /// Requested target and planned estimate, without claiming optical arrival timing.
    public var playbackDetail: String {
        playbackDetail(for: transition)
    }

    private func playbackDetail(for move: FocusRackTransition) -> String {
        guard move.durationMode == .timed, let estimatedDuration,
            estimatedDuration > move.duration + 0.0005
        else { return move.playbackDetail }
        let estimate = estimatedDuration.formatted(.number.precision(.fractionLength(0...2)))
        return
            "\(move.duration.formatted(.number.precision(.fractionLength(0...2)))) s target · ~\(estimate) s"
    }
    public var admissionMessage: String?
    public var primary = FocusRackPrimaryAction()
    /// Explicit duration-based playback in each direction; absent in older state snapshots.
    public var pullAToB: FocusRackPrimaryAction?
    /// Reverse playback uses the same selected duration and delay.
    public var pullBToA: FocusRackPrimaryAction?
    /// Shared preparation reason for the direct playback controls.
    public var playbackInstruction: String?
    public var capabilities = FocusRackCapabilities()
    public var captures: [FocusRackCaptureIdentity] = []
    public var activeElapsed = 0.0
    public var remainingDelay = 0.0
    public var remainingDuration = 3.0

    /// Creates inert state, also useful for platform rendering fixtures.
    public init() {}

    /// Projects both timed actions from the same marks, readiness and admission result.
    /// Fast positioning remains governed independently by canGoToA/B. An optional admission
    /// instruction describes preparation that cannot be resolved by changing timing.
    public mutating func updateTimedActions(
        recording: Bool, ready: Bool, admissionInstruction: String? = nil
    ) {
        var timed = transition
        timed.durationMode = .timed
        let admissionReason = admissionInstruction ?? "Adjust timing"
        func action(from: String, to: String) -> FocusRackPrimaryAction {
            let start = program.marks.first { $0.id == from }
            let hasMarks = start != nil && program.marks.contains { $0.id == to }
            let reason: String? =
                !hasMarks
                ? "Set A and B"
                : !referenceValid
                    ? "Reset marks"
                    : busy
                        ? "Wait for movement"
                        : admissionMessage != nil
                            ? admissionReason
                            : !ready
                                ? "Camera not ready"
                                : stepPosition != start?.stepPosition
                                    ? "Go to " + from + " first" : nil
            return .init(
                kind: "run", title: (recording ? "Run " : "Rehearse ") + from + "→" + to,
                enabled: reason == nil, markID: from, detail: playbackDetail(for: timed),
                disabledReason: reason)
        }
        pullAToB = action(from: "A", to: "B")
        pullBToA = action(from: "B", to: "A")
        playbackInstruction =
            busy || pullAToB?.enabled == true || pullBToA?.enabled == true
            ? nil
            : program.marks.count != 2
                ? "Set A and B"
                : !referenceValid
                    ? "Reset marks"
                    : admissionMessage != nil
                        ? admissionReason
                        : !ready ? "Camera not ready" : "Go to A or B first"
    }

    /// Initial disconnected production state; creating it starts no work.
    public static let initial = FocusRackState()
}

/// OS-owned facts. Frame ages are durations; no platform clock epoch crosses this boundary.
public struct FocusRackObservation: Codable, Sendable {
    /// Reported stable body identity and link, used only to match locally saved timing evidence.
    public var cameraID: String?
    public var transport: String?
    public var sessionID: String
    public var connected: Bool
    public var foregroundOwner: Bool
    public var recording: Bool
    public var frameSequence: Int64?
    public var frameAgeSeconds: Double
    public var focus: FocusRackFocusObservation?
    public var focusResult: String?
    public var externalFocusRevision: Int64
    public var externalFocusIdle: Bool

    /// Supplies actual accepted-frame identity and current lifecycle/control observations.
    public init(
        sessionID: String, connected: Bool, foregroundOwner: Bool, recording: Bool,
        frameSequence: Int64?, focus: FocusRackFocusObservation?,
        externalFocusRevision: Int64 = 0, externalFocusIdle: Bool = true,
        frameAgeSeconds: Double = 0, focusResult: String? = nil,
        cameraID: String? = nil, transport: String? = nil
    ) {
        self.cameraID = cameraID
        self.transport = transport
        self.sessionID = sessionID
        self.connected = connected
        self.foregroundOwner = foregroundOwner
        self.recording = recording
        self.frameSequence = frameSequence
        self.focus = focus
        self.externalFocusRevision = externalFocusRevision
        self.externalFocusIdle = externalFocusIdle
        self.frameAgeSeconds = frameAgeSeconds
        self.focusResult = focusResult
    }
}

/// Field-specific timing edits merge against the controller's latest state after queueing.
public struct FocusRackTimingUpdate: Codable, Equatable, Sendable {
    public var duration: Double?
    public var delay: Double?
    public var easing: FocusRackEasing?
    public var durationMode: FocusRackDurationMode?
    public var direction: FocusRackDirection?

    /// Creates an edit without copying unrelated asynchronously presented settings.
    public init(
        duration: Double? = nil, delay: Double? = nil, easing: FocusRackEasing? = nil,
        durationMode: FocusRackDurationMode? = nil, direction: FocusRackDirection? = nil
    ) {
        self.duration = duration
        self.delay = delay
        self.easing = easing
        self.durationMode = durationMode
        self.direction = direction
    }
}

extension FocusRackTransition {
    /// Playback timing shown beside Rehearse/Run, independently of fast repositioning.
    public var playbackDetail: String {
        durationMode == .fastest
            ? "Fastest" : "\(duration.formatted(.number.precision(.fractionLength(0...2)))) s pull"
    }

    /// Applies one queued edit atomically while preserving every field absent from the request.
    public func applying(_ update: FocusRackTimingUpdate) throws -> Self {
        guard update != FocusRackTimingUpdate() else { throw FocusRackError.invalidConfiguration }
        var result = self
        if let duration = update.duration { result.duration = duration }
        if let delay = update.delay { result.delay = delay }
        if let easing = update.easing { result.easing = easing }
        if let mode = update.durationMode { result.durationMode = mode }
        if let direction = update.direction {
            result.fromMark = direction == .aToB ? "A" : "B"
            result.toMark = direction == .aToB ? "B" : "A"
        }
        try FocusRackTemplateCodec.validate(result)
        return result
    }
}

/// Semantic operator requests; the same controller handles both native shells.
public enum FocusRackIntent: Codable, Sendable {
    case capture(markID: String, expectedFrameSequence: Int64)
    case nudge(towardNear: Bool, steps: Int)
    case goTo(markID: String)
    /// Starts exactly one explicitly requested finer-increment calibration traversal.
    case calibrate
    /// Starts a duration-based pull in one atomic intent, without implicit repositioning.
    case run(direction: FocusRackDirection)
    case setTransition(FocusRackTransition)
    case updateTiming(FocusRackTimingUpdate)
    case setDirection(FocusRackDirection)
    case start, pause, resume, stop, reset, discardMarks, performPrimary, primary
    case applyTemplate(FocusRackTemplate)
    case externalFocusAction
}

/// Validates and encodes only named timing choices, never execution or lens state.
public enum FocusRackTemplateCodec {
    /// Encodes validated timing-only templates for platform-owned storage.
    public static func encode(_ templates: [FocusRackTemplate]) throws -> Data {
        let validated = try templates.map(validate)
        guard Set(validated.map(\.name)).count == validated.count else {
            throw FocusRackError.invalidTemplateName
        }
        let encoded = try JSONEncoder().encode(validated)
        guard encoded.count <= 65_536 else { throw FocusRackError.templateStorageFull }
        return encoded
    }

    /// Decodes and validates stored timing templates before they can affect a controller.
    public static func decode(_ data: Data) throws -> [FocusRackTemplate] {
        guard data.count <= 65_536 else { throw FocusRackError.templateStorageFull }
        let templates = try JSONDecoder().decode([FocusRackTemplate].self, from: data)
        let validated = try templates.map(validate)
        guard Set(validated.map(\.name)).count == validated.count else {
            throw FocusRackError.invalidTemplateName
        }
        return validated
    }

    /// Validates a single template and normalizes its name.
    public static func validate(_ template: FocusRackTemplate) throws -> FocusRackTemplate {
        let name = template.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (1...60).contains(name.count) else { throw FocusRackError.invalidTemplateName }
        try validate(template.transition)
        return .init(name: name, transition: template.transition)
    }

    /// Validates the supported two-mark transition atomically.
    public static func validate(_ transition: FocusRackTransition) throws {
        guard Set([transition.fromMark, transition.toMark]) == Set(["A", "B"]),
            transition.duration.isFinite, transition.duration > 0, transition.duration <= 120,
            transition.delay.isFinite, transition.delay >= 0, transition.delay <= 120
        else { throw FocusRackError.invalidConfiguration }
    }
}
