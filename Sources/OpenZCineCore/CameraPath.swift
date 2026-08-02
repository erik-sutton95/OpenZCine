import Foundation

/// The operator's declared way of reaching one camera in one rig configuration — the value the
/// transport refactor exists to make first-class (docs/transport-architecture.md).
///
/// A path is DECLARED once, at setup time, and carried through records, connects, discovery,
/// recovery and the relay. It is never re-derived from an SSID string, a subnet, a host shape or
/// free text; the one place inference survives is the one-time migration of records that predate
/// the field. (Named `CameraPath` rather than the design doc's `CameraTransport` because that
/// identifier is the session-layer wire transport protocol.)
public enum CameraPath: Codable, Equatable, Hashable, Sendable {
    /// This device joins the CAMERA's own network. The only path with Wi-Fi join machinery.
    case cameraAccessPoint(ssid: String?)
    /// Both ends sit on somebody's network — a set router, home Wi-Fi. The app never touches
    /// Wi-Fi configuration on this path; "wrong network" is a hint to the operator, not a join.
    case infrastructure(networkName: String?)
    /// The camera joins THIS device's Personal Hotspot. The phone hosts and scans nothing.
    case phoneHotspot
    /// Tethered PTP over the cable.
    case usbC
    /// Picture only, through a UVC capture device; control, if any, rides another setup.
    case hdmiCapture

    /// The keying discriminant: a camera has at most one setup per kind, edited in place.
    public enum Kind: String, Codable, CaseIterable, Sendable {
        case cameraAccessPoint
        case infrastructure
        case phoneHotspot
        case usbC
        case hdmiCapture
    }

    public var kind: Kind {
        switch self {
        case .cameraAccessPoint: return .cameraAccessPoint
        case .infrastructure: return .infrastructure
        case .phoneHotspot: return .phoneHotspot
        case .usbC: return .usbC
        case .hdmiCapture: return .hdmiCapture
        }
    }

    /// The camera's access-point SSID when this path declares one.
    public var accessPointSSID: String? {
        if case .cameraAccessPoint(let ssid) = self { return ssid }
        return nil
    }

    /// Short label for chips and rows.
    public var displayLabel: String {
        switch self {
        case .cameraAccessPoint: return "Camera AP"
        case .infrastructure: return "Router"
        case .phoneHotspot: return "Hotspot"
        case .usbC: return "USB-C"
        case .hdmiCapture: return "HDMI"
        }
    }

    /// The legacy `transport` string a record of this path historically carried. Kept in sync so
    /// every reader of the old field keeps working until it is deleted. Historically ALL network
    /// paths collapsed to "Wi-Fi" (the collapse this type exists to end) — hotspot use was
    /// identified by the 172.20.10.x host, never by the label.
    public var legacyTransportLabel: String {
        switch self {
        case .usbC: return "USB-C"
        case .hdmiCapture: return "HDMI"
        case .cameraAccessPoint, .infrastructure, .phoneHotspot: return "Wi-Fi"
        }
    }
}
