import Foundation

/// Top-level monitor mode cycled by the `DISP` control.
public enum DispMode: String, CaseIterable, Codable, Equatable, Identifiable, Sendable {
    case live  // with overlays
    case clean  // no overlays
    case command

    public var id: String { rawValue }

    /// User-facing title for the mode.
    public var title: String {
        switch self {
        case .live: "Live"
        case .clean: "Clean"
        case .command: "Command"
        }
    }

    /// Returns the next mode in the specified order.
    public func next(in order: [DispMode]) -> DispMode {
        guard let index = order.firstIndex(of: self), !order.isEmpty else {
            return .live
        }
        return order[(index + 1) % order.count]
    }
}

/// One value in the bottom camera-value strip.
public struct CameraValue: Equatable, Identifiable, Sendable {
    public init(label: String, value: String, isSettable: Bool = true) {
        self.label = label
        self.value = value
        self.isSettable = isSettable
    }

    public var id: String { label }
    public let label: String
    public let value: String
    public let isSettable: Bool
}

/// UI-ready camera state snapshot used by the native shells.
public struct CameraDisplayState: Equatable, Sendable {
    public init(
        recordState: RecordState,
        timecode: Timecode,
        resolutionFrameRate: String,
        codec: String,
        media: String,
        liveFPS: String,
        cameraBatteryPercent: Int,
        phoneBatteryPercent: Int,
        cameraName: String,
        lens: String,
        temperature: String,
        values: [CameraValue],
        mediaStatus: MediaStatus? = nil
    ) {
        self.recordState = recordState
        self.timecode = timecode
        self.resolutionFrameRate = resolutionFrameRate
        self.codec = codec
        self.media = media
        self.liveFPS = liveFPS
        self.cameraBatteryPercent = cameraBatteryPercent
        self.phoneBatteryPercent = phoneBatteryPercent
        self.cameraName = cameraName
        self.lens = lens
        self.temperature = temperature
        self.values = values
        self.mediaStatus = mediaStatus
    }

    public let recordState: RecordState
    public let timecode: Timecode
    public let resolutionFrameRate: String
    public let codec: String
    public let media: String
    public let liveFPS: String
    public let cameraBatteryPercent: Int
    public let phoneBatteryPercent: Int
    public let cameraName: String
    public let lens: String
    public let temperature: String
    public let values: [CameraValue]
    /// Structured media capacity used by the interactive top-bar MEDIA cell.
    public let mediaStatus: MediaStatus?

    /// The apertures the IRIS picker should offer, restricted to what the mounted lens can reach
    /// (derived from the lens descriptor's marked maximum aperture). Empty-safe: callers fall back
    /// to a default ladder if the lens is unknown.
    public var availableApertures: [String] {
        PTPCameraPropertyDecoders.availableApertures(forLens: lens)
    }

    /// The value shown where the camera has told us nothing. Matches the Android shells'
    /// `UNAVAILABLE_MONITOR_VALUE` so a readout that survives into a control-less session reads
    /// the same on both platforms.
    public static let unavailableValue = "—"

    /// State for a monitor with no camera control behind it — an HDMI capture source on its own.
    ///
    /// This exists because `applyingCameraProperties` maps over the *existing* values and falls
    /// back to `existing` on every branch, so a snapshot that has never received a property leaves
    /// whatever was there before untouched. Starting from `preview` in that situation renders a
    /// wholly fictional camera: ISO 800, f/2.8, "6K · 25p", "Nikon ZR". Chrome gating hides most
    /// of these anyway; this is the honest floor underneath it, so anything that does slip through
    /// says "—" rather than lying.
    public static let blank = CameraDisplayState(
        recordState: .standby,
        timecode: Timecode(on: false, hour: 0, minute: 0, second: 0, frame: 0),
        resolutionFrameRate: unavailableValue,
        codec: unavailableValue,
        media: unavailableValue,
        liveFPS: unavailableValue,
        cameraBatteryPercent: 0,
        phoneBatteryPercent: 0,
        cameraName: unavailableValue,
        lens: unavailableValue,
        temperature: unavailableValue,
        values: [
            CameraValue(label: "ISO", value: unavailableValue, isSettable: false),
            CameraValue(label: "SHUTTER", value: unavailableValue, isSettable: false),
            CameraValue(label: "IRIS", value: unavailableValue, isSettable: false),
            CameraValue(label: "WB", value: unavailableValue, isSettable: false),
            CameraValue(label: "FOCUS", value: unavailableValue, isSettable: false),
        ],
        mediaStatus: nil
    )

    /// Preview state for design and testing.
    public static let preview = CameraDisplayState(
        recordState: .standby,
        timecode: Timecode(on: true, hour: 0, minute: 0, second: 0, frame: 0),
        resolutionFrameRate: "6K · 25p",
        codec: "R3D NE",
        media: "521 GB · 47 min",
        liveFPS: "25.00",
        cameraBatteryPercent: 80,
        phoneBatteryPercent: 84,
        cameraName: "Nikon ZR",
        lens: "Z 24-70mm f/2.8",
        temperature: "OK",
        values: [
            CameraValue(label: "ISO", value: "800"),
            CameraValue(label: "SHUTTER", value: "180°"),
            CameraValue(label: "IRIS", value: "f/2.8"),
            CameraValue(label: "WB", value: "5560K"),
            CameraValue(label: "FOCUS", value: "AF-C"),
        ],
        mediaStatus: MediaStatus(gigabytesFree: 521, percentFree: 47, minutesRemaining: 47)
    )
}
