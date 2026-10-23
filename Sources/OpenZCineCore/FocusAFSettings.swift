import Foundation

/// Movie AF properties temporarily managed by the focus panel.
public enum FocusAFProperty: String, CaseIterable, Codable, Sendable {
    case mode, area, subject

    /// Existing Nikon setting encoder used by both platform adapters.
    public func write(_ value: String) -> PTPCameraPropertyWrite? {
        let control: PTPCameraControl =
            switch self {
            case .mode: .focusMode
            case .area: .focusArea
            case .subject: .focusSubject
            }
        return PTPCameraPropertyWrite.request(control: control, label: value)
    }
}

/// Confirmed movie AF values, never optimistic picker values.
public struct FocusAFSettingsValues: Equatable, Codable, Sendable {
    public var mode: String?
    public var area: String?
    public var subject: String?

    /// Creates a tuple from camera readbacks; unknown values remain unknown.
    public init(mode: String?, area: String?, subject: String?) {
        self.mode = mode
        self.area = area
        self.subject = subject
    }

    /// Looks up a property without mixing movie and stills focus settings.
    public subscript(_ property: FocusAFProperty) -> String? {
        switch property {
        case .mode: mode
        case .area: area
        case .subject: subject
        }
    }

    /// The established movie setup for each focus surface; AF speed stays on the camera.
    public static func target(_ mode: FocusControlMode) -> Self {
        .init(
            mode: mode == .nativeAF ? "AF-F" : "AF-S",
            area: "Auto", subject: "Off")
    }
}

/// Same-session safety facts required before any temporary AF setting write.
public struct FocusAFSettingsObservation: Sendable {
    public var sessionID: String?
    public var values: FocusAFSettingsValues
    public var recording: Bool?
    public var recordingPending: Bool
    public var movie: Bool
    public var foreground: Bool
    /// Includes a fresh accepted header, completed bounded DeviceReady barrier and no focus work.
    public var focusIdle: Bool
    public var commandsIdle: Bool
    public var rack: FocusRackState?

    /// Creates an observation using reported recording, focus and property evidence.
    public init(
        sessionID: String?, values: FocusAFSettingsValues, recording: Bool?,
        recordingPending: Bool, movie: Bool, foreground: Bool, focusIdle: Bool,
        commandsIdle: Bool, rack: FocusRackState?
    ) {
        self.sessionID = sessionID
        self.values = values
        self.recording = recording
        self.recordingPending = recordingPending
        self.movie = movie
        self.foreground = foreground
        self.focusIdle = focusIdle
        self.commandsIdle = commandsIdle
        self.rack = rack
    }

    /// Unknown recording or movement evidence never permits a settings write.
    public var permitsWrite: Bool {
        sessionID != nil && recording == false && !recordingPending && movie && foreground
            && focusIdle && commandsIdle && FocusControlModePolicy.canChange(rack: rack)
    }
}

/// One compare-before-write effect, executed by the existing serialized platform setting path.
public struct FocusAFSettingChange: Equatable, Codable, Sendable {
    public let id: UInt64
    public let sessionID: String
    public let property: FocusAFProperty
    public let expectedValue: String
    public let value: String
    public let restoring: Bool
}

/// Temporary ownership of confirmed app changes. This value owns no tasks or camera queue.
public struct FocusAFSettingsLease: Sendable {
    public private(set) var sessionID: String?
    public private(set) var pending: FocusAFSettingChange?
    public private(set) var restoring = false
    public private(set) var failure: String?
    private var target: FocusAFSettingsValues?
    private var originals: [FocusAFProperty: String] = [:]
    private var applied: [FocusAFProperty: String] = [:]
    private var observed: [FocusAFProperty: String] = [:]
    private var released: Set<FocusAFProperty> = []
    private var sequence: UInt64 = 0

    /// Starts with no camera ownership.
    public init() {}

    /// True while setup or deferred restoration needs safe-point service.
    public var needsService: Bool { target != nil || restoring || pending != nil }

    /// Captures restorable originals before setup. Explicit selection may re-own manual changes.
    public mutating func requestMode(
        _ mode: FocusControlMode, sessionID: String, values: FocusAFSettingsValues
    ) throws {
        guard pending == nil else { throw FocusRackError.movementPending }
        guard
            FocusAFProperty.allCases.allSatisfy({
                guard let value = values[$0] else { return false }
                return $0.write(value) != nil
            })
        else { throw FocusAFSettingsError.unavailable }
        if self.sessionID != sessionID { abandon() }
        self.sessionID = sessionID
        observe(values)
        for property in FocusAFProperty.allCases {
            if originals[property] == nil || released.contains(property) {
                originals[property] = values[property]
            }
            observed[property] = values[property]
        }
        released.removeAll()
        target = .target(mode)
        restoring = false
        failure = nil
    }

    /// Dismissal retains confirmed ownership until recording and movement stop.
    public mutating func requestRestore() {
        target = nil
        restoring = !applied.isEmpty || pending != nil
        failure = nil
        if !restoring { abandon() }
    }

    /// App picker intent relinquishes ownership even when the operator chooses the same value.
    public mutating func manualChange(_ property: FocusAFProperty) {
        released.insert(property)
        applied[property] = nil
        if pending?.property == property { pending = nil }
    }

    /// Latches observed manual changes; returning to an old app value cannot re-acquire ownership.
    public mutating func observe(_ values: FocusAFSettingsValues) {
        for property in FocusAFProperty.allCases {
            guard let actual = values[property] else { continue }
            if let pending, pending.property == property {
                if actual != pending.expectedValue && actual != pending.value {
                    manualChange(property)
                }
            } else if let previous = observed[property], actual != previous,
                target != nil || applied[property] != nil
            {
                manualChange(property)
            }
            observed[property] = actual
        }
    }

    /// Emits at most one effect, only against fresh eligible same-session evidence.
    public mutating func nextChange(_ observation: FocusAFSettingsObservation)
        -> FocusAFSettingChange?
    {
        guard observation.sessionID == sessionID else {
            abandon()
            return nil
        }
        observe(observation.values)
        if restoring && applied.isEmpty && pending == nil {
            abandon()
            return nil
        }
        guard pending == nil, needsService, let sessionID else {
            return nil
        }
        let desiredMode = restoring ? originals[.mode] : target?.mode
        let continuous = desiredMode == "AF-F" || desiredMode == "AF-C"
        let order: [FocusAFProperty] =
            continuous
            ? [.subject, .area, .mode] : [.mode, .subject, .area]
        for property in order where !released.contains(property) {
            let desired =
                restoring
                ? (applied[property] == nil ? nil : originals[property]) : target?[property]
            guard let desired else { continue }
            guard let current = observation.values[property] else { return nil }
            if desired == current { continue }
            guard observation.permitsWrite else { return nil }
            sequence &+= 1
            let change = FocusAFSettingChange(
                id: sequence, sessionID: sessionID, property: property,
                expectedValue: current, value: desired, restoring: restoring)
            pending = change
            return change
        }
        target = nil
        if restoring {
            originals.removeAll()
            applied.removeAll()
            released.removeAll()
            restoring = false
        }
        return nil
    }

    /// Rechecked by the platform admission immediately before sending the property write.
    public func allows(_ change: FocusAFSettingChange, observation: FocusAFSettingsObservation)
        -> Bool
    {
        pending == change && sessionID == observation.sessionID && observation.permitsWrite
            && change.restoring == restoring
            && !released.contains(change.property)
            && observation.values[change.property] == change.expectedValue
    }

    /// A control fence can retire an unsent effect without losing deferred work or ownership.
    public mutating func deferChange(_ change: FocusAFSettingChange) {
        guard pending == change else { return }
        pending = nil
    }

    /// Claims ownership only after a matching actual camera readback in the original session.
    public mutating func confirm(
        _ change: FocusAFSettingChange, sessionID: String, values: FocusAFSettingsValues
    ) {
        guard pending == change, self.sessionID == sessionID else { return }
        guard !released.contains(change.property) else {
            pending = nil
            return
        }
        guard values[change.property] == change.value else {
            fail(change, message: FocusAFSettingsError.readbackMismatch.localizedDescription)
            return
        }
        pending = nil
        observed[change.property] = change.value
        applied[change.property] = change.restoring ? nil : change.value
    }

    /// Stops this attempt visibly; an error never spins an automatic retry loop.
    public mutating func fail(_ change: FocusAFSettingChange, message: String) {
        guard pending == change, self.sessionID == change.sessionID else { return }
        failPreparation(message: message)
    }

    /// A failed readiness/readback preparation stops this attempt before an effect is reserved.
    public mutating func failPreparation(message: String) {
        pending = nil
        target = nil
        restoring = false
        failure = message
    }

    /// A replacement connection never inherits old setting ownership or pending restoration.
    public mutating func abandon() {
        sessionID = nil
        pending = nil
        target = nil
        restoring = false
        originals.removeAll()
        applied.removeAll()
        observed.removeAll()
        released.removeAll()
        failure = nil
    }
}

/// A temporary setup requires known, encodable originals and confirmed write readbacks.
public enum FocusAFSettingsError: LocalizedError {
    case unavailable, readbackMismatch

    public var errorDescription: String? {
        switch self {
        case .unavailable: "Camera AF settings are unavailable; automatic setup could not start."
        case .readbackMismatch: "The camera did not confirm the requested AF setting."
        }
    }
}
