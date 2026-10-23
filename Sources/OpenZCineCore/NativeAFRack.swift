import Foundation

/// A saved picture target, independent of a timed rack's relative lens positions.
public enum NativeAFMark: String, Codable, CaseIterable, Sendable {
    case a = "A"
    case b = "B"
}

/// A normalized point in the camera picture, after the shell's display-coordinate mapping.
public struct NativeAFPoint: Codable, Equatable, Sendable {
    /// Horizontal camera-picture coordinate in the closed range zero through one.
    public let x: Double
    /// Vertical camera-picture coordinate in the closed range zero through one.
    public let y: Double

    /// Validates a camera-picture point without silently clamping an invalid tap.
    public init(x: Double, y: Double) throws {
        guard x.isFinite, y.isFinite, (0...1).contains(x), (0...1).contains(y) else {
            throw NativeAFRackError.invalidPoint
        }
        self.x = x
        self.y = y
    }

    /// Decodes a saved point using the same validation as a live picture tap.
    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            x: values.decode(Double.self, forKey: .x), y: values.decode(Double.self, forKey: .y))
    }

    private enum CodingKeys: String, CodingKey { case x, y }
}

/// A destination selection to send through the existing serialized autofocus targeting path.
public struct NativeAFRequest: Equatable, Sendable {
    /// Identity used to reject stale timers and command completions.
    public let id: UInt64
    /// Target in normalized camera-picture coordinates.
    public let point: NativeAFPoint
    /// Saved destination being selected; this is not an optical-arrival assertion.
    public let mark: NativeAFMark
    /// Earliest dispatch time on the shell's monotonic clock.
    public let dueAt: Double
}

/// Validation failures for native target selection; camera command failures stay in the adapter.
public enum NativeAFRackError: Error, LocalizedError, Equatable, Sendable {
    case invalidPoint, invalidDelay, invalidTime, selectionNotArmed, commandInFlight
    case missingTarget(NativeAFMark)
    case requestNotPending, requestNotDue
    case invalidCheckpoint, checkpointRequiresIdle
    case requestIdentityExhausted

    /// An operator-facing explanation for the rejected action.
    public var errorDescription: String? {
        switch self {
        case .invalidPoint: "Select a point inside the camera picture."
        case .invalidDelay: "Start delay must be a finite, nonnegative number."
        case .invalidTime: "The focus timer is unavailable."
        case .selectionNotArmed: "Choose Set A or Set B before saving a picture target."
        case .commandInFlight: "Wait for the current focus command to finish."
        case .missingTarget(let mark): "Set target \(mark.rawValue) first."
        case .requestNotPending: "This focus request is no longer pending."
        case .requestNotDue: "The focus start delay has not finished."
        case .invalidCheckpoint: "Saved Native AF targets are invalid."
        case .checkpointRequiresIdle: "Finish or cancel target selection before restoring targets."
        case .requestIdentityExhausted: "Native AF request identities are exhausted."
        }
    }
}

/// Shared target-control availability and explanation, separate from settings-recovery controls.
/// Optical focus state is deliberately not an input: an unfocused subject must remain retryable.
public struct NativeAFAdmission: Equatable, Sendable {
    /// Whether the current camera and shell state permits requesting a native target.
    public var allowed: Bool { disabledReason == nil }
    /// The first actionable blocker, used by both control enablement and readiness text.
    public let disabledReason: String?

    /// Evaluates current raw facts without replacing the adapter's command-time PTP safeguards.
    public init(
        connected: Bool, foreground: Bool, interfaceLocked: Bool, focusPointLocked: Bool,
        liveViewFresh: Bool, commandIdle: Bool, settingsPending: Bool, settingsFailure: String?,
        configured: Bool, movieMode: Bool
    ) {
        if !connected {
            disabledReason = "Connect the camera before selecting a focus target."
        } else if !foreground {
            disabledReason = "Return to the live camera preview to select a focus target."
        } else if interfaceLocked {
            disabledReason = "Unlock the interface before selecting a focus target."
        } else if focusPointLocked {
            disabledReason = "Unlock the focus point before selecting a new target."
        } else if let settingsFailure {
            disabledReason = settingsFailure
        } else if settingsPending {
            disabledReason = "Waiting for camera AF setup…"
        } else if !movieMode {
            disabledReason = "Switch the camera to movie mode."
        } else if !configured {
            disabledReason =
                "Camera AF setup is not ready. Open Focus settings or select Native AF again."
        } else if !liveViewFresh {
            disabledReason = "Waiting for a fresh live camera picture…"
        } else if !commandIdle {
            disabledReason = "Waiting for the current focus command to finish…"
        } else {
            disabledReason = nil
        }
    }
}

/// Portable A/B target and delay state. The shell owns its clock and existing command transport.
///
/// Acknowledgment records destination selection only. It neither proves sharpness nor ends the
/// camera's continuous autofocus. Cancellation removes unsent work without releasing an active
/// command's ownership. Mode and lifecycle interruptions can cancel while retaining both targets.
public struct NativeAFRack: Equatable, Sendable {
    /// Target whose next picture tap will be saved.
    public private(set) var selectingMark: NativeAFMark?
    /// Delay used by directional actions; Go to A/B and target capture are immediate.
    public private(set) var startDelay: Double = 0
    /// The sole unsent destination selection, if any.
    public private(set) var pendingRequest: NativeAFRequest?
    /// Command awaiting transport acknowledgment or failure, if any.
    public private(set) var dispatchedRequest: NativeAFRequest?
    /// Acknowledged destination for the current intent, without any optical-arrival implication.
    public private(set) var lastSelectedMark: NativeAFMark?

    private var targetA: NativeAFPoint?
    private var targetB: NativeAFPoint?
    private var nextRequestID: UInt64 = 0

    /// Creates an empty native rack without changing camera focus or settings.
    public init() {}

    /// Returns a saved camera-picture target.
    public func target(for mark: NativeAFMark) -> NativeAFPoint? {
        mark == .a ? targetA : targetB
    }

    /// Updates the directional-action delay without changing an already scheduled request.
    public mutating func setStartDelay(_ seconds: Double) throws {
        guard seconds.isFinite, seconds >= 0 else { throw NativeAFRackError.invalidDelay }
        startDelay = seconds
    }

    /// Arms the next picture tap and replaces any unsent request while preserving saved targets.
    public mutating func arm(_ mark: NativeAFMark) throws {
        try requireCommandIdle()
        pendingRequest = nil
        selectingMark = mark
        lastSelectedMark = nil
    }

    /// Saves an armed target and requests an immediate selection for focus preview.
    @discardableResult
    public mutating func capture(_ point: NativeAFPoint, now: Double) throws -> NativeAFRequest {
        try requireCommandIdle()
        guard let mark = selectingMark else { throw NativeAFRackError.selectionNotArmed }
        let request = try makeRequest(point: point, mark: mark, now: now, delay: 0)
        if mark == .a { targetA = point } else { targetB = point }
        selectingMark = nil
        pendingRequest = request
        return request
    }

    /// Requests the saved destination only; a directional action does not reposition its source.
    @discardableResult
    public mutating func request(
        _ mark: NativeAFMark, now: Double, delayed: Bool
    ) throws -> NativeAFRequest {
        try requireCommandIdle()
        guard let point = target(for: mark) else { throw NativeAFRackError.missingTarget(mark) }
        let request = try makeRequest(
            point: point, mark: mark, now: now, delay: delayed ? startDelay : 0)
        selectingMark = nil
        pendingRequest = request
        return request
    }

    /// Returns the remaining unsent delay without advancing state or issuing a command.
    public func remainingDelay(at now: Double) -> Double {
        guard now.isFinite, let pendingRequest else { return 0 }
        return max(0, pendingRequest.dueAt - now)
    }

    /// Returns a due selection; the shell must recheck camera admission before dispatching it.
    public func dueRequest(at now: Double) -> NativeAFRequest? {
        guard now.isFinite, let pendingRequest, pendingRequest.dueAt <= now else { return nil }
        return pendingRequest
    }

    /// Claims a due request once, before calling the shell's serialized native targeting path.
    @discardableResult
    public mutating func beginDispatch(id: UInt64, at now: Double) throws -> NativeAFRequest {
        try requireCommandIdle()
        guard now.isFinite else { throw NativeAFRackError.invalidTime }
        guard let request = pendingRequest, request.id == id else {
            throw NativeAFRackError.requestNotPending
        }
        guard request.dueAt <= now else { throw NativeAFRackError.requestNotDue }
        pendingRequest = nil
        dispatchedRequest = request
        return request
    }

    /// Records target-selection acknowledgment. Stale completions cannot change current intent.
    @discardableResult
    public mutating func complete(id: UInt64) -> Bool {
        guard let request = dispatchedRequest, request.id == id else { return false }
        dispatchedRequest = nil
        lastSelectedMark = request.mark
        return true
    }

    /// Releases a failed command without claiming that its target was selected or became sharp.
    @discardableResult
    public mutating func fail(id: UInt64) -> Bool {
        guard dispatchedRequest?.id == id else { return false }
        dispatchedRequest = nil
        return true
    }

    /// Cancels selection and unsent delay work; it does not stop AF or retire an active command.
    public mutating func cancel() {
        selectingMark = nil
        pendingRequest = nil
        lastSelectedMark = nil
    }

    /// Explicitly clears targets and unsent work once the current command has finished.
    public mutating func reset() throws {
        try requireCommandIdle()
        cancel()
        targetA = nil
        targetB = nil
        lastSelectedMark = nil
    }

    /// Encodes only target coordinates, delay and request identity for owner recreation.
    /// Armed selection, queued work, active commands and acknowledgments are never saved.
    public func checkpointJSON() throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let checkpoint = Checkpoint(
            a: targetA, b: targetB, startDelay: startDelay, nextRequestID: nextRequestID)
        return String(decoding: try encoder.encode(checkpoint), as: UTF8.self)
    }

    /// Restores an idle value without replaying work or allowing old request identities to recur.
    public mutating func restoreCheckpointJSON(_ json: String) throws {
        guard selectingMark == nil, pendingRequest == nil, dispatchedRequest == nil else {
            throw NativeAFRackError.checkpointRequiresIdle
        }
        guard json.utf8.count <= 4096 else { throw NativeAFRackError.invalidCheckpoint }
        let checkpoint: Checkpoint
        do {
            checkpoint = try JSONDecoder().decode(Checkpoint.self, from: Data(json.utf8))
        } catch { throw NativeAFRackError.invalidCheckpoint }
        guard checkpoint.startDelay.isFinite, checkpoint.startDelay >= 0 else {
            throw NativeAFRackError.invalidCheckpoint
        }
        targetA = checkpoint.a
        targetB = checkpoint.b
        startDelay = checkpoint.startDelay
        nextRequestID = max(nextRequestID, checkpoint.nextRequestID)
        lastSelectedMark = nil
    }

    private struct Checkpoint: Codable {
        let a: NativeAFPoint?
        let b: NativeAFPoint?
        let startDelay: Double
        let nextRequestID: UInt64
    }

    private func requireCommandIdle() throws {
        guard dispatchedRequest == nil else { throw NativeAFRackError.commandInFlight }
    }

    private mutating func makeRequest(
        point: NativeAFPoint, mark: NativeAFMark, now: Double, delay: Double
    ) throws -> NativeAFRequest {
        guard now.isFinite, (now + delay).isFinite else { throw NativeAFRackError.invalidTime }
        let (next, overflow) = nextRequestID.addingReportingOverflow(1)
        guard !overflow else { throw NativeAFRackError.requestIdentityExhausted }
        nextRequestID = next
        lastSelectedMark = nil
        return NativeAFRequest(id: nextRequestID, point: point, mark: mark, dueAt: now + delay)
    }
}
