import Foundation

/// Where the monitor's picture comes from.
///
/// The picture source is deliberately independent of the control link. A camera reached over
/// Wi-Fi can be *controlled* over PTP while its picture arrives over HDMI through a USB capture
/// device, and a capture device can drive the monitor with no camera session behind it at all.
public enum VideoSourceKind: String, CaseIterable, Codable, Equatable, Identifiable, Sendable {
    /// The camera's own live-view stream, pulled over the PTP command channel.
    case cameraLiveView
    /// An HDMI signal digitised by an attached USB Video Class capture device.
    case hdmiCapture
    /// Another device's feed, relayed over the network. That device holds the camera; this one
    /// watches. PTP-IP serves a single initiator, so this is the only way a second screen exists.
    case relay

    public var id: String { rawValue }

    /// The sources an operator can actually PICK.
    ///
    /// Relay is a state this device is put into by joining another device's broadcast, not a
    /// choice on a settings row — there is nothing to relay from until a broadcaster exists, and
    /// tapping it could never establish one. Listing it offered a control that could not work.
    public static var operatorSelectableCases: [VideoSourceKind] {
        allCases.filter { $0 != .relay }
    }

    public var title: String {
        switch self {
        case .cameraLiveView: "Camera"
        case .hdmiCapture: "HDMI"
        case .relay: "Relay"
        }
    }

    /// Longer label for pickers and the connect wizard.
    public var detailTitle: String {
        switch self {
        case .cameraLiveView: "Camera live view"
        case .hdmiCapture: "HDMI capture"
        case .relay: "Relayed from another device"
        }
    }

    /// Whether the PICTURE from this source arrives with the camera's live-view metadata header
    /// attached. HDMI carries picture and nothing else.
    ///
    /// Deliberately NOT what decides whether the app has that metadata. The header is a PTP
    /// payload — `GetLiveViewImageEx` — so it follows the CONTROL link, not the picture. With a
    /// session up the app keeps pulling it (at the smallest frame the body offers, purely as a
    /// carrier) whatever is on screen, which is how Command mode has always worked. What this
    /// property really marks is whether that separate pull is needed.
    public var carriesCameraFrameHeader: Bool { self == .cameraLiveView }
}

/// What the monitor can truthfully display, given where the picture comes from and whether a
/// camera control session exists.
///
/// This is the single definition both shells and their tests read, so "the AF box hides on HDMI"
/// is stated once rather than re-derived at each mount site. It answers what data *exists*; the
/// operator's own chrome preferences still apply on top.
public struct MonitorDataAvailability: Equatable, Sendable {
    /// - Parameters:
    ///   - receivesCameraMetadata: Whether the camera's readings are reaching this device at all.
    ///     Deliberately separate from `ownsCameraSession`, because a relay viewer has every reading
    ///     — the host forwards them — and no ability to write. Collapsing the two would either
    ///     blank a viewer's readouts or offer it controls the camera will never hear.
    public init(
        source: VideoSourceKind, ownsCameraSession: Bool, receivesCameraMetadata: Bool,
        holdsRelayControl: Bool = false
    ) {
        self.source = source
        self.ownsCameraSession = ownsCameraSession
        self.receivesCameraMetadata = receivesCameraMetadata
        self.holdsRelayControl = holdsRelayControl
    }

    /// Whether this device may issue camera commands at all — over its own session, or proxied
    /// through a relay host. Deliberately distinct from owning the session: a viewer holding the
    /// token drives the camera without ever touching the camera link.
    public var canDriveCamera: Bool { ownsCameraSession || holdsRelayControl }

    public let source: VideoSourceKind
    /// Whether a PTP session is live — the camera can be read and written.
    public let ownsCameraSession: Bool
    /// Whether this device currently holds the relay's control token — it drives the camera
    /// through the host rather than over a link of its own.
    public let holdsRelayControl: Bool
    /// Whether the camera's readings are arriving, from our own session or a relay host's.
    public let receivesCameraMetadata: Bool

    /// Exposure/focus tiles, their pickers, and the command-mode grid. Purely a control-link
    /// question: PTP properties keep arriving over Wi-Fi while the picture comes over HDMI.
    public var cameraControls: Bool { canDriveCamera }

    /// The record button and its state readout. Record is an operation, and the camera reports
    /// the resulting state over PTP events as well as in the frame header, so it survives HDMI.
    public var recordControl: Bool { canDriveCamera }

    /// Browsing and downloading what is on the card — a control-link operation.
    public var mediaBrowser: Bool { ownsCameraSession }

    /// The AF box overlay, and the body's focus confirmation behind it.
    public var focusBoxes: Bool { receivesCameraMetadata }
    public var focusConfirmation: Bool { receivesCameraMetadata }

    /// The body's own detections — faces, eyes, subject tracking.
    public var subjectDetectionBoxes: Bool { receivesCameraMetadata }

    /// The camera's own audio meter.
    public var audioMeters: Bool { receivesCameraMetadata }

    /// Timecode struck by the body.
    public var cameraTimecode: Bool { receivesCameraMetadata }

    /// Whether the *body* is reporting its level angles. The horizon overlay stays up either way,
    /// because it already falls back to the phone's own CoreMotion attitude.
    public var cameraLevel: Bool { receivesCameraMetadata }

    /// Whether the operator can pick a picture source at all: only worth offering once a control
    /// session exists to switch back to.
    public var offersSourceSwitch: Bool { ownsCameraSession }

    /// Whether the camera's own live-view frame loop is running.
    ///
    /// That loop is not just a picture: its per-frame safe point is the ONLY place queued property
    /// writes, AF-point taps, record start/stop, still release, device-event polls and the property
    /// round-robin are serviced. Reading a source as "just where the picture comes from" is what
    /// made that easy to miss.
    public var runsCameraFrameLoop: Bool { source == .cameraLiveView && ownsCameraSession }

    /// Whether a standalone control pump has to run.
    ///
    /// True exactly when the camera is controllable but its frame loop — which normally hosts
    /// every control operation — is not running. Standing the loop down without honouring this
    /// leaves the chrome fully live and every write queued forever: pickers move, nothing reaches
    /// the camera. The idle drain does not cover it, because it deliberately refuses while the
    /// monitor is up, on the assumption that the frame loop is there.
    /// Deliberately `ownsCameraSession`, not `canDriveCamera`: the pump services a PTP session,
    /// and a relay viewer holding the token has none — it drives the camera by asking the host to.
    /// Pumping on `canDriveCamera` would spin a loop against a session that does not exist.
    public var requiresControlPump: Bool { ownsCameraSession && !runsCameraFrameLoop }
}
