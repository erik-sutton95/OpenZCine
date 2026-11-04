import Foundation

/// Stored curve metadata; production playback normalizes legacy curves to Linear.
public enum FocusRackEasing: String, Codable, CaseIterable, Sendable {
    case linear
    case easeInOut
}

/// One session-relative mark, expressed in completed base focus units.
public struct FocusRackMark: Codable, Equatable, Sendable {
    public let id: String
    public let stepPosition: Int
    public let captureIdentity: FocusRackCaptureIdentity?

    /// Creates a mark in the current session's relative reference.
    public init(id: String, stepPosition: Int, captureIdentity: FocusRackCaptureIdentity? = nil) {
        self.id = id
        self.stepPosition = stepPosition
        self.captureIdentity = captureIdentity
    }
}

/// Whether a move follows a requested duration or the camera's confirmed command cadence.
public enum FocusRackDurationMode: String, Codable, CaseIterable, Sendable {
    case timed, fastest
}

/// One move between two marks; the array-based program can later contain additional moves.
public struct FocusRackTransition: Codable, Equatable, Sendable {
    public var fromMark: String
    public var toMark: String
    public var duration: Double
    public var durationMode: FocusRackDurationMode
    public var delay: Double
    public var easing: FocusRackEasing

    /// Creates a requested move. Execution validates timing against the measured command budget.
    public init(
        fromMark: String = "A", toMark: String = "B", duration: Double = 3,
        delay: Double = 0, easing: FocusRackEasing = .linear,
        durationMode: FocusRackDurationMode = .timed
    ) {
        self.fromMark = fromMark
        self.toMark = toMark
        self.duration = duration
        self.durationMode = durationMode
        self.delay = delay
        self.easing = easing
    }

    private enum CodingKeys: String, CodingKey {
        case fromMark, toMark, duration, durationMode, delay, easing
    }

    /// Restores existing timing templates as Timed when they predate the mode selector.
    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        fromMark = try values.decode(String.self, forKey: .fromMark)
        toMark = try values.decode(String.self, forKey: .toMark)
        duration = try values.decode(Double.self, forKey: .duration)
        durationMode =
            try values.decodeIfPresent(FocusRackDurationMode.self, forKey: .durationMode) ?? .timed
        delay = try values.decode(Double.self, forKey: .delay)
        easing = try values.decode(FocusRackEasing.self, forKey: .easing)
    }
}

/// A session-local ordered set of marks and their requested transitions.
public struct FocusRackProgram: Codable, Equatable, Sendable {
    public var marks: [FocusRackMark]
    public var transitions: [FocusRackTransition]

    /// Creates the current two-mark program.
    public init(marks: [FocusRackMark], transitions: [FocusRackTransition]) {
        self.marks = marks
        self.transitions = transitions
    }
}

/// A reusable timing choice. It deliberately contains no lens positions or armed state.
public struct FocusRackTemplate: Codable, Equatable, Sendable {
    public let name: String
    public let transition: FocusRackTransition

    /// Creates a timing template whose use still requires newly captured marks.
    public init(name: String, transition: FocusRackTransition) {
        self.name = name
        self.transition = transition
    }
}

/// Validation failures that can be presented by either native shell.
public enum FocusRackError: Error, LocalizedError, Equatable, Sendable {
    case invalidConfiguration
    case marksRequired
    case samePosition
    case referenceUnavailable
    case movementPending
    case freshFrameRequired
    case notAtStart
    /// Timed playback requires a completed command of its selected size.
    case calibrationRequired
    /// Lens preparation moves only while recording is stopped.
    case recordingInProgress
    /// No measured command can complete inside fresh camera evidence.
    case safetyReadUnavailable
    case reconnectRequired
    case invalidTemplateName
    case templateStorageFull

    public var errorDescription: String? {
        switch self {
        case .invalidConfiguration: "Use finite positive timing and a valid pulse increment."
        case .marksRequired: "Set A and B before running a rack."
        case .samePosition: "Move focus with Near/Far before setting the second mark."
        case .referenceUnavailable: "The focus position is uncertain. Reset both marks."
        case .movementPending: "Wait for the current focus movement to settle."
        case .recordingInProgress: "Stop recording before preparing the lens."
        case .safetyReadUnavailable:
            "Fresh camera readings cannot cover this movement. Wait for the camera and try again."
        case .freshFrameRequired: "Wait for a fresh camera frame before setting a mark."
        case .notAtStart: "Go to the selected start mark before running."
        case .reconnectRequired: "The camera stop is unconfirmed. Reconnect before resetting marks."
        case .invalidTemplateName: "Use a unique template name of 1–60 characters."
        case .templateStorageFull: "Remove a saved timing template before saving another."
        case .calibrationRequired:
            "Use Prepare lens to measure command timing before timed playback."
        }
    }
}
