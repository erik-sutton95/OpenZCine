import Foundation

/// The requested pulse trajectory. Its optical behavior must be qualified on the actual lens.
public enum FocusRackEasing: String, Codable, CaseIterable, Sendable {
    case linear
    case easeInOut

    /// Converts a completed fraction to its scheduled time fraction.
    public func timeFraction(forPosition fraction: Double) -> Double {
        let target = min(1, max(0, fraction))
        if target == 0 || target == 1 { return target }
        guard self == .easeInOut else { return target }
        // Invert smoothstep without introducing a second trajectory implementation in Kotlin.
        var lower = 0.0
        var upper = 1.0
        for _ in 0..<48 {
            let middle = (lower + upper) / 2
            if middle * middle * (3 - 2 * middle) < target {
                lower = middle
            } else {
                upper = middle
            }
        }
        return (lower + upper) / 2
    }
}

/// Immutable command-planning policy selected when a controller is created.
public enum FocusRackProfile: String, Sendable {
    /// Selects the finest feasible profile from the existing adaptive command sizes.
    case adaptive
    /// Local, unqualified ten-command trial for a 100-unit, one-second Linear move.
    case tenBy160Experiment
    /// Local measured-size comparison with explicit bidirectional finer-increment calibration.
    case calibratedFineExperiment
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

    /// Creates a program; the diagnostic surface currently captures A and B only.
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
    case durationTooShort(minimum: Double)
    case durationTooLong(maximum: Double)
    case noSmoothTiming
    /// Timed experimental playback requires a completed command of its selected size.
    case calibrationRequired
    case marksTooClose
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
        case .freshFrameRequired: "Wait for a fresh camera frame before setting a mark."
        case .notAtStart: "Go to the selected start mark before running."
        case .marksTooClose:
            "These marks are too close for a timed pull. Set new marks farther apart."
        case .reconnectRequired: "The camera stop is unconfirmed. Reconnect before resetting marks."
        case .invalidTemplateName: "Use a unique template name of 1–60 characters."
        case .templateStorageFull: "Remove a saved timing template before saving another."
        case .calibrationRequired:
            "Use Go to A or Go to B once to measure this move before timed playback."
        case .noSmoothTiming:
            "This duration is not supported for these marks at the current camera cadence. Try another duration or Linear. Go to A/B remains available for fast positioning."
        case .durationTooLong(let maximum):
            "These marks need finer movement for this duration. Try Linear or a duration of \(String(format: "%.2f", focusRackMaximumForDisplay(maximum))) seconds or less. Rehearse to check smoothness."
        case .durationTooShort(let minimum):
            "This move needs at least \(String(format: "%.2f", focusRackMinimumForDisplay(minimum))) seconds at the current camera cadence."
        }
    }
}

// The displayed bound must remain sufficient when entered back into either shell.
func focusRackMinimumForDisplay(_ seconds: Double) -> Double {
    (seconds * 100).rounded(.up) / 100
}

// A displayed maximum must remain admissible when entered back into either shell.
func focusRackMaximumForDisplay(_ seconds: Double) -> Double {
    (seconds * 100).rounded(.down) / 100
}

/// A fixed-increment schedule. Duration includes one expected final command interval.
public struct FocusRackTrajectory: Sendable {
    public let signedSteps: Int
    public let duration: Double
    public let delay: Double
    public let offsets: [Double]
    /// Minimum duration admitted by the current measured command budget.
    public let minimumDuration: Double

    /// Plans identical increments; neither changing timing nor easing changes their pulse size.
    /// Final completion can reserve native latency separately from the start-to-start budget.
    public init(
        signedSteps: Int, duration: Double, delay: Double, easing: FocusRackEasing,
        commandInterval: Double, finalCommandDuration: Double? = nil
    ) throws {
        guard signedSteps != 0, signedSteps != .min, abs(signedSteps) <= 10_000,
            duration.isFinite, duration > 0, delay.isFinite, delay >= 0,
            commandInterval.isFinite, commandInterval > 0
        else { throw FocusRackError.invalidConfiguration }
        let finalDuration = finalCommandDuration ?? commandInterval
        guard finalDuration.isFinite, finalDuration >= 0, finalDuration <= commandInterval else {
            throw FocusRackError.invalidConfiguration
        }
        let count = abs(signedSteps)
        if count == 1, duration > commandInterval + 1e-9 { throw FocusRackError.marksTooClose }
        let fractions = (0..<count).map { index in
            count == 1 ? 0 : easing.timeFraction(forPosition: Double(index) / Double(count - 1))
        }
        let smallestGap = zip(fractions, fractions.dropFirst()).map { $1 - $0 }.min() ?? 1
        let minimum = count == 1 ? finalDuration : commandInterval / smallestGap + finalDuration
        guard duration + 1e-9 >= minimum else {
            throw FocusRackError.durationTooShort(minimum: minimum)
        }
        self.minimumDuration = minimum
        self.signedSteps = signedSteps
        self.duration = duration
        self.delay = delay
        offsets = fractions.map { delay + $0 * (duration - finalDuration) }
    }
}
