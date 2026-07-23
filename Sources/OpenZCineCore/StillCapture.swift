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

    /// Drive modes that keep firing while the shutter stays pressed — a remote release in
    /// these modes latches until the terminate op, so the shutter control ends the burst on
    /// finger-up. [verify-on-HW: latch behaviour per body]
    public var isContinuous: Bool {
        switch self {
        case .continuousHigh, .continuousLow, .continuousHighExtended,
            .highSpeedFrameC15, .highSpeedFrameC30, .highSpeedFrameC60, .highSpeedFrameC120:
            true
        case .single, .selfTimer, .quickSetting:
            false
        }
    }

    /// Reverse lookup from the display label the snapshot stores.
    public static func mode(forLabel label: String) -> StillDriveMode? {
        allCases.first { $0.label == label }
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
        .captureAreaCrop,
        .compressionSetting,
        .rawCompressionType,
        .stillToneMode,
        .exposureProgramMode,
        .userMode,
        .activePicCtrlItem,
        .stillISOAutoControl,
        .isoControlSensitivity,
        .stillShutterSpeed,
        .fNumber,
        .exposureBiasCompensation,
        .exposureIndicateStatus,
        .exposureIndicateLightup,
        .exposureMeteringMode,
        .flashMode,
        .focusMode,
        .stillFocusMode,
        .stillFocusMeteringMode,
        .afSubjectDetection,
        .whiteBalance,
        .wbColorTemp,
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
        case .peaking, .falseColor, .zebra, .histogram, .grid, .level, .evMeter, .instantReview:
            true
        case .lut, .waveform, .parade, .vectorscope, .trafficLights, .audioMeters,
            .guides, .crosshair, .desqueeze:
            false
        }
    }
}

/// Photo image area (`CaptureAreaCrop`): the sensor crop photographers pick per shot.
/// Raw values and frame aspects are shared across the lineup; DX halves the sensor but
/// keeps the 3:2 frame shape.
public enum StillImageArea: UInt8, Equatable, Sendable, CaseIterable {
    case fx = 0
    case dx = 2
    case square = 4
    case wide = 5

    public var label: String {
        switch self {
        case .fx: "FX"
        case .dx: "DX"
        case .square: "1:1"
        case .wide: "16:9"
        }
    }

    /// Width / height of the framed image in this area.
    public var frameAspect: Double {
        switch self {
        case .fx, .dx: 3.0 / 2.0
        case .square: 1.0
        case .wide: 16.0 / 9.0
        }
    }

    public static func decode(raw: UInt8) -> StillImageArea? {
        StillImageArea(rawValue: raw)
    }

    public static func area(forLabel label: String) -> StillImageArea? {
        allCases.first { $0.label == label }
    }
}

/// The Image-quality drum pair decomposed from / composed into a `CompressionSetting` code:
/// a RAW half and a JPEG/HEIF tier half (the body labels the tier JPEG or HEIF by its tone
/// mode; the codes are the same). The ★ flag is the optimal-quality variant of the tier.
public struct StillQualityConfiguration: Equatable, Sendable {
    public enum Tier: String, CaseIterable, Sendable {
        case off = "Off"
        case basic = "Basic"
        case normal = "Normal"
        case fine = "Fine"
    }

    public var rawEnabled: Bool
    public var tier: Tier
    public var starred: Bool

    public init(rawEnabled: Bool, tier: Tier, starred: Bool) {
        self.rawEnabled = rawEnabled
        self.tier = tier
        self.starred = starred
    }

    private static let tierLadder: [Tier] = [.basic, .normal, .fine]

    /// Decodes a `CompressionSetting` code (0–5 JPEG±★, 7 RAW, 8–13 RAW+JPEG±★). TIFF and
    /// unknown codes return nil — the panel seeds its defaults instead.
    public static func decode(compressionCode code: UInt8) -> StillQualityConfiguration? {
        switch code {
        case 0...5:
            return StillQualityConfiguration(
                rawEnabled: false, tier: tierLadder[Int(code) / 2], starred: code % 2 == 1)
        case 7:
            return StillQualityConfiguration(rawEnabled: true, tier: .off, starred: false)
        case 8...13:
            return StillQualityConfiguration(
                rawEnabled: true, tier: tierLadder[Int(code - 8) / 2], starred: (code - 8) % 2 == 1
            )
        default:
            return nil
        }
    }

    /// The `CompressionSetting` code for this pair; nil for the unwritable both-off state.
    public var compressionCode: UInt8? {
        let tierIndex = Self.tierLadder.firstIndex(of: tier)
        switch (rawEnabled, tierIndex) {
        case (true, nil): return 7
        case (true, let index?): return UInt8(8 + index * 2 + (starred ? 1 : 0))
        case (false, let index?): return UInt8(index * 2 + (starred ? 1 : 0))
        case (false, nil): return nil
        }
    }

    /// The decoded quality label for this pair (the write path's label form), nil when unwritable.
    public var compressionLabel: String? {
        compressionCode.map(PTPCameraPropertyDecoders.compressionSetting)
    }
}

extension PTPCameraPropertySnapshot {
    /// The photography capture strip, in the same `CameraValue` shape the cinema strip
    /// renders — same tiles, same bar, different readouts. Quality and image size live
    /// in the top bar, keeping this strip to shooting settings.
    public var photographyCaptureValues: [CameraValue] {
        [
            CameraValue(label: "MODE", value: exposureMode ?? "—"),
            CameraValue(label: "ISO", value: iso.map(String.init) ?? "—"),
            CameraValue(label: "SHUTTER", value: shutterSpeed ?? "—"),
            CameraValue(label: "IRIS", value: fNumber ?? "—"),
            CameraValue(label: "DRIVE", value: compactDriveLabel ?? "—"),
            CameraValue(label: "FOCUS", value: focusMode ?? "—"),
            CameraValue(label: "WB", value: stillWhiteBalanceValue),
            CameraValue(label: "METER", value: meteringMode ?? "—"),
            CameraValue(label: "PROFILE", value: compactPictureControlLabel ?? "—"),
        ]
    }

    /// Picture-control label compacted to strip width (body-style codes for the built-ins;
    /// Auto and the creative names are short enough to show whole).
    private var compactPictureControlLabel: String? {
        switch pictureControl {
        case nil: nil
        case "Standard": "SD"
        case "Neutral": "NL"
        case "Vivid": "VI"
        case "Monochrome": "MC"
        case "Portrait": "PT"
        case "Landscape": "LS"
        case "Flat": "FL"
        case "Flat Mono": "FM"
        case "Deep Tone Mono": "DTM"
        case "Rich Tone Portrait": "RTP"
        case let other: other
        }
    }

    /// Top-bar size readout: image area + size class ("FX · L"). Bodies report ImageSize as a
    /// resolution string, so the class letter is ranked against the camera's enumerated sizes —
    /// never shown raw (a "6048x3400" pill is dead weight). Falls back to whichever half is known.
    public func stillSizeAreaLabel(sizeOptions: [String]) -> String? {
        let size = stillSizeClassLabel(options: sizeOptions)
        let area = imageArea?.label
        switch (area, size) {
        case (let area?, let size?): return "\(area) · \(size)"
        case (let area?, nil): return area
        case (nil, let size?): return size
        case (nil, nil): return nil
        }
    }

    /// Ranks the current image-size string among the camera's enumerated sizes: largest pixel
    /// count = L, then M, then S. Bodies that report "Size L"-form strings pass through directly.
    /// Nil when the domain is unknown or the current value isn't in it.
    public func stillSizeClassLabel(options: [String]) -> String? {
        guard imageSize != nil else { return nil }
        let letters = ["L", "M", "S"]
        if let compact = stillSizeCompactLabel, letters.contains(compact) { return compact }
        let ranked =
            options
            .compactMap { option in Self.pixelCount(option).map { (option, $0) } }
            .sorted { $0.1 > $1.1 }
        guard let index = ranked.firstIndex(where: { $0.0 == imageSize }), index < letters.count
        else { return nil }
        return letters[index]
    }

    /// "6048x4032" → 24_385_536; nil for strings that aren't a WxH resolution.
    private static func pixelCount(_ size: String) -> Int? {
        let parts = size.lowercased().split(separator: "x")
        guard parts.count == 2, let width = Int(parts[0]), let height = Int(parts[1]) else {
            return nil
        }
        return width * height
    }

    /// The live-view frame aspect for the current photo image area (3:2 default).
    public var photographyFeedAspect: Double {
        (imageArea ?? .fx).frameAspect
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

    /// WB tile readout: the Kelvin figure while in colour-temperature mode, else the preset
    /// name (presets render as icons in the strip, like the movie tile).
    private var stillWhiteBalanceValue: String {
        if wbMode == "Color temp", let kelvin = wbKelvin { return "\(kelvin)K" }
        return wbMode ?? "—"
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
