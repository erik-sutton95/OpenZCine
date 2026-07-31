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

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .cameraLiveView: "Camera"
        case .hdmiCapture: "HDMI"
        }
    }

    /// Longer label for pickers and the connect wizard.
    public var detailTitle: String {
        switch self {
        case .cameraLiveView: "Camera live view"
        case .hdmiCapture: "HDMI capture"
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
    public init(source: VideoSourceKind, hasCameraControl: Bool) {
        self.source = source
        self.hasCameraControl = hasCameraControl
    }

    public let source: VideoSourceKind
    /// Whether a PTP session is live — the camera can be read and written.
    public let hasCameraControl: Bool

    /// Exposure/focus tiles, their pickers, and the command-mode grid. Purely a control-link
    /// question: PTP properties keep arriving over Wi-Fi while the picture comes over HDMI.
    public var cameraControls: Bool { hasCameraControl }

    /// The record button and its state readout. Record is an operation, and the camera reports
    /// the resulting state over PTP events as well as in the frame header, so it survives HDMI.
    public var recordControl: Bool { hasCameraControl }

    /// Browsing and downloading what is on the card — a control-link operation.
    public var mediaBrowser: Bool { hasCameraControl }

    /// The AF box overlay, and the body's focus confirmation behind it.
    public var focusBoxes: Bool { hasCameraControl }
    public var focusConfirmation: Bool { hasCameraControl }

    /// The body's own detections — faces, eyes, subject tracking.
    public var subjectDetectionBoxes: Bool { hasCameraControl }

    /// The camera's own audio meter.
    public var audioMeters: Bool { hasCameraControl }

    /// Timecode struck by the body.
    public var cameraTimecode: Bool { hasCameraControl }

    /// Whether the *body* is reporting its level angles. The horizon overlay stays up either way,
    /// because it already falls back to the phone's own CoreMotion attitude.
    public var cameraLevel: Bool { hasCameraControl }

    /// Whether the operator can pick a picture source at all: only worth offering once a control
    /// session exists to switch back to.
    public var offersSourceSwitch: Bool { hasCameraControl }

    /// Whether the camera's own live-view frame loop is running.
    ///
    /// That loop is not just a picture: its per-frame safe point is the ONLY place queued property
    /// writes, AF-point taps, record start/stop, still release, device-event polls and the property
    /// round-robin are serviced. Reading a source as "just where the picture comes from" is what
    /// made that easy to miss.
    public var runsCameraFrameLoop: Bool { source == .cameraLiveView && hasCameraControl }

    /// Whether a standalone control pump has to run.
    ///
    /// True exactly when the camera is controllable but its frame loop — which normally hosts
    /// every control operation — is not running. Standing the loop down without honouring this
    /// leaves the chrome fully live and every write queued forever: pickers move, nothing reaches
    /// the camera. The idle drain does not cover it, because it deliberately refuses while the
    /// monitor is up, on the assumption that the frame loop is there.
    public var requiresControlPump: Bool { cameraControls && !runsCameraFrameLoop }
}
