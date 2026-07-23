import Foundation

/// Whether the body is currently in stills or movie live-view mode.
///
/// Decoded from `LiveViewSelector` (0xD1A6): 0 = photo, 1 = video. Cross-body on
/// the Z lineup. Remote mode may also write the selector; PC-camera mode may
/// only report the physical photo/video lever. [VERIFY-ON-HW]
public enum CameraCaptureSelector: String, Equatable, Sendable, CaseIterable {
    case photo
    case video

    /// Decode a raw UINT8 from `LiveViewSelector`.
    public static func decode(raw: UInt8) -> CameraCaptureSelector? {
        switch raw {
        case 0: return .photo
        case 1: return .video
        default: return nil
        }
    }

    public var rawValueUInt8: UInt8 {
        switch self {
        case .photo: return 0
        case .video: return 1
        }
    }
}

/// Release / drive mode for still capture (`StillCaptureMode` 0x5013).
///
/// This is the label union across the Z lineup; each body advertises its own
/// valid subset through the property descriptor (the Cxx high-speed modes and
/// the extended-continuous mode are body-dependent). Bodies with a release-mode
/// dial report `quickSetting` when the dial sits on the quick position and move
/// the effective mode to `StillCaptureModeQuick` (0xD0F6).
public enum StillDriveMode: UInt16, Equatable, Sendable, CaseIterable {
    case single = 0x0001
    case continuousHigh = 0x0002
    case continuousLow = 0x8010
    case selfTimer = 0x8011
    case continuousHighExtended = 0x8019
    case quickSetting = 0x8100
    case highSpeedFrameC15 = 0x810F
    case highSpeedFrameC30 = 0x811E
    case highSpeedFrameC60 = 0x813C
    case highSpeedFrameC120 = 0x8178

    public var label: String {
        switch self {
        case .single: return "Single"
        case .continuousHigh: return "Continuous H"
        case .continuousLow: return "Continuous L"
        case .selfTimer: return "Self-timer"
        case .continuousHighExtended: return "Continuous H+"
        case .quickSetting: return "Quick"
        case .highSpeedFrameC15: return "C15"
        case .highSpeedFrameC30: return "C30"
        case .highSpeedFrameC60: return "C60"
        case .highSpeedFrameC120: return "C120"
        }
    }

    public static func decode(raw: UInt16) -> StillDriveMode? {
        StillDriveMode(rawValue: raw)
    }
}

/// Destination for a still capture request.
public enum StillCaptureDestination: Equatable, Sendable {
    /// Card only (`InitiateCapture` 0x100E).
    case card
    /// Temporary camera buffer for host pull (`InitiateCaptureRecInSdram` 0x90C0).
    case sdram
    /// Parameterised media capture (`InitiateCaptureRecInMedia` 0x9207). Prefer for
    /// remote app control when the body advertises it.
    case media
}

/// Pure policy for still capture opcodes and photo-mode polling.
public enum StillCapturePolicy: Sendable {
    /// Operation used for a single release given destination preference.
    public static func captureOperation(
        destination: StillCaptureDestination
    ) -> PTPOperationCode {
        switch destination {
        case .card: return .initiateCapture
        case .sdram: return .initiateCaptureRecInSdram
        case .media: return .initiateCaptureRecInMedia
        }
    }

    /// Properties polled while the body is in photo mode (in addition to shared health).
    /// ExposureTime (0x500D) and ExposureIndex (0x500F) are deliberately absent: the
    /// fraction-packed ShutterSpeed and the 32-bit controlled-ISO readout supersede both.
    public static let photoMonitorPollOrder: [PTPPropertyCode] = [
        .liveViewSelector,
        .stillCaptureMode,
        .imageSize,
        .compressionSetting,
        .exposureProgramMode,
        .stillISOAutoControl,
        .isoControlSensitivity,
        .stillShutterSpeed,
        .fNumber,
        .exposureBiasCompensation,
        .exposureMeteringMode,
        .flashMode,
        .focusMode,
        .stillFocusMode,
        .stillFocusMeteringMode,
        .whiteBalance,
        .exposureRemaining,
        .batteryLevel,
        .acPower,
        .warningStatus,
        .focalLength,
    ]

    /// Compact health set during continuous/high-speed still capture bursts.
    public static let photoBurstPollOrder: [PTPPropertyCode] = [
        .liveViewSelector,
        .stillCaptureMode,
        .batteryLevel,
        .acPower,
        .warningStatus,
    ]

    /// Whether the shell should present the photography chrome instead of the cinema strip.
    public static func prefersPhotographyChrome(
        selector: CameraCaptureSelector?
    ) -> Bool {
        selector == .photo
    }

    /// Classifies a `DeviceReady` response while a still release is in flight.
    public static func releaseReadiness(_ code: PTPResponseCode) -> StillReleaseReadiness {
        switch code {
        case .ok: .complete
        case .deviceBusy, .silentReleaseBusy, .movieFrameReleaseBusy: .inProgress
        case .bulbReleaseBusy: .openShutterInProgress
        default: .failed(code)
        }
    }
}

extension MonitorAssistTool {
    /// Assist tools that apply to still photography — the exposure aids (peaking, false
    /// color, zebra, histogram) plus the composition aids photographers actually use
    /// (grid, level). Everything else is cinema-only, which keeps the photo toolbar
    /// deliberately shorter so the stills strip gets the bar width.
    public var appliesToPhotography: Bool {
        switch self {
        case .peaking, .falseColor, .zebra, .histogram, .grid, .level:
            true
        case .lut, .waveform, .parade, .vectorscope, .trafficLights, .audioMeters,
            .guides, .crosshair, .desqueeze:
            false
        }
    }
}

extension PTPCameraPropertySnapshot {
    /// The photography capture strip, in the same `CameraValue` shape the cinema strip
    /// renders — same tiles, same bar, different readouts.
    public var photographyCaptureValues: [CameraValue] {
        [
            CameraValue(label: "MODE", value: exposureMode ?? "—"),
            CameraValue(label: "ISO", value: iso.map(String.init) ?? "—"),
            CameraValue(label: "SHUTTER", value: shutterSpeed ?? "—"),
            CameraValue(label: "IRIS", value: fNumber ?? "—"),
            CameraValue(label: "DRIVE", value: compactDriveLabel ?? "—"),
            CameraValue(label: "FOCUS", value: focusMode ?? "—"),
            CameraValue(label: "QUAL", value: stillQualityCompactLabel ?? "—"),
            CameraValue(label: "FLASH", value: compactFlashLabel ?? "—"),
            CameraValue(label: "METER", value: meteringMode ?? "—"),
        ]
    }

    /// Flash label compacted to strip width ("Red-eye slow" → "Red+S").
    private var compactFlashLabel: String? {
        switch flashMode {
        case nil: nil
        case "Red-eye": "Red"
        case "Red-eye slow": "Red+S"
        case let other: other
        }
    }

    /// Drive-mode label compacted to strip width ("Continuous H" → "CH").
    private var compactDriveLabel: String? {
        switch stillCaptureMode {
        case nil: nil
        case "Continuous H": "CH"
        case "Continuous L": "CL"
        case "Continuous H+": "CH+"
        case "Self-timer": "Timer"
        case let other: other
        }
    }

    /// Image-size label compacted for the photo top bar ("Size L" → "L").
    public var stillSizeCompactLabel: String? {
        imageSize.map { $0.replacingOccurrences(of: "Size ", with: "") }
    }

    /// Quality label compacted to strip width ("RAW+JPEG Fine★" → "R+JF★").
    public var stillQualityCompactLabel: String? {
        guard let compression else { return imageSize }
        if compression.hasPrefix("RAW+JPEG") {
            let suffix = compression.dropFirst("RAW+JPEG ".count)
            let letter = suffix.first.map(String.init) ?? ""
            let star = suffix.hasSuffix("★") ? "★" : ""
            return "R+J\(letter)\(star)"
        }
        if compression.hasPrefix("JPEG") {
            let suffix = compression.dropFirst("JPEG ".count)
            let letter = suffix.first.map(String.init) ?? ""
            let star = suffix.hasSuffix("★") ? "★" : ""
            return "JPG \(letter)\(star)"
        }
        return compression
    }
}

/// Progress of a still release as reported by polling `DeviceReady` after the release op.
public enum StillReleaseReadiness: Equatable, Sendable {
    /// The release (including every frame of a burst) finished.
    case complete
    /// AF / shooting / self-timer still running — poll again.
    case inProgress
    /// A bulb or time exposure is holding the shutter open; a second shutter action ends it
    /// via `TerminateCapture`, and no timeout applies.
    case openShutterInProgress
    /// The release failed (out of focus, storage full, …).
    case failed(PTPResponseCode)
}
