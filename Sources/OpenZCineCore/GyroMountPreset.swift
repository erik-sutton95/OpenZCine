import Foundation

/// Fixed phone mounts with the screen parallel to the camera's back, perpendicular to the lens axis.
/// Directions are viewed from behind an upright camera and never follow display rotation.
public enum GyroMountPreset: String, CaseIterable, Codable, Sendable, Identifiable {
    /// No phone-to-camera alignment was selected; adjust it in Gyroflow.
    case unconfigured
    /// Screen toward the operator, USB-C edge down.
    case rearDown
    /// Screen toward the operator, USB-C edge left.
    case rearLeft
    /// Screen toward the operator, USB-C edge right.
    case rearRight
    /// Screen toward the operator, USB-C edge up.
    case rearUp
    /// Screen toward the lens, USB-C edge down.
    case frontDown
    /// Screen toward the lens, USB-C edge left.
    case frontLeft
    /// Screen toward the lens, USB-C edge right.
    case frontRight
    /// Screen toward the lens, USB-C edge up.
    case frontUp

    /// Stable preference and native-wire identity.
    public var id: String { rawValue }

    /// Operator-visible position of the phone's bottom edge.
    public var shortLabel: String {
        switch self {
        case .unconfigured: "Unconfigured"
        case .rearDown, .frontDown: "USB-C down"
        case .rearLeft, .frontLeft: "USB-C left"
        case .rearRight, .frontRight: "USB-C right"
        case .rearUp, .frontUp: "USB-C up"
        }
    }

    /// Operator-visible physical portrait or landscape position.
    public var title: String {
        switch self {
        case .unconfigured: "Unconfigured"
        case .rearDown, .frontDown, .rearUp, .frontUp: "Portrait · \(shortLabel)"
        case .rearLeft, .frontLeft, .rearRight, .frontRight: "Landscape · \(shortLabel)"
        }
    }

    /// Screen direction used to group mount choices, absent for an unknown mount.
    public var group: String? {
        switch self {
        case .unconfigured: nil
        case .rearDown, .rearLeft, .rearRight, .rearUp: "Screen toward you"
        case .frontDown, .frontLeft, .frontRight, .frontUp: "Screen toward lens"
        }
    }

    /// Full mount identity retained in the take list.
    public var detail: String {
        guard let group else { return "Unconfigured · set alignment in Gyroflow" }
        return "\(shortLabel) · \(group.lowercased())"
    }

    /// Raw-device-axis lookup for Gyroflow's camera-up, camera-left, camera-backward basis.
    /// Capital letters preserve the selected phone axis; lowercase letters negate it.
    public var orientation: String {
        switch self {
        case .unconfigured, .rearRight: "XYZ"
        case .rearDown: "YxZ"
        case .rearLeft: "xyZ"
        case .rearUp: "yXZ"
        case .frontDown: "YXz"
        case .frontLeft: "Xyz"
        case .frontRight: "xYz"
        case .frontUp: "yxz"
        }
    }
}
