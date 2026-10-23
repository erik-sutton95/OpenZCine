import Foundation

/// Chooses the camera's continuous autofocus or the existing timed relative-focus controller.
public enum FocusControlMode: String, Codable, CaseIterable, Sendable {
    case nativeAF, timedRack

    /// Operator-facing mode name used by both shells.
    public var title: String { self == .nativeAF ? "Native AF" : "Timed Rack" }
}

/// Shared ownership rules for the two focus surfaces; neither selection moves the lens.
public enum FocusControlModePolicy {
    /// A mode change cannot retire an active move, an unsettled stop, or a pending external command.
    public static func canChange(
        rack: FocusRackState?, stopPending: Bool = false, externalFocusIdle: Bool = true
    ) -> Bool {
        guard !stopPending, externalFocusIdle else { return false }
        guard let rack else { return true }
        return !rack.busy && !rack.capabilities.canStop && rack.phase != .stopUnconfirmed
    }

    /// Native AF requires movie AF-F. Area, subject detection and AF speed remain camera settings.
    public static func nativeAFConfigured(movieFocusMode: String?, photography: Bool) -> Bool {
        !photography && movieFocusMode == "AF-F"
    }

    /// Native targeting has its own ownership gate, independent of timed marks and MF admission.
    public static func allowsNativeAutofocus(
        mode: FocusControlMode, rack: FocusRackState?, stopPending: Bool = false
    ) -> Bool {
        mode == .nativeAF && canChange(rack: rack, stopPending: stopPending)
    }
}
