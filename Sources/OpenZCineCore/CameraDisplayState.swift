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
            CameraValue(label: "WB", value: "5600K"),
            CameraValue(label: "FOCUS", value: "AF-C"),
        ],
        mediaStatus: MediaStatus(gigabytesFree: 521, percentFree: 47, minutesRemaining: 47)
    )
}
