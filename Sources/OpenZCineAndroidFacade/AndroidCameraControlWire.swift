import OpenZCineCore

/// Android camera controls resolved entirely inside the Swift facade.
///
/// Kotlin sends only these semantic selectors and camera-advertised labels. The
/// active session retains every descriptor's exact raw value and builds the
/// corresponding `PTPCameraPropertyWrite`; no Nikon value crosses JNI.
enum AndroidCameraControl: Hashable, Sendable {
    case iso
    case isoAuto
    case shutter
    case iris
    case whiteBalance
    case focusMode
    case focusArea
    case focusSubject
    case exposureMode
    case audioSensitivity
    case audioInput
    case windFilter
    case attenuator
    case audio32BitFloat
    case baseISO
    case shutterMode
    case shutterLock
    case whiteBalanceTint
    case resolutionFrameRate
    case codec
    case vibrationReduction
    case electronicVR
    // Stills / photo-mode controls (photography pickers; the movie controls
    // above stay untouched in photo mode — iOS `CameraPicker.isStillPicker`).
    case stillISO
    case stillISOAuto
    case stillShutter
    case stillIris
    case stillDrive
    case stillFocusMode
    case stillFocusArea
    case stillFocusSubject
    case stillMeter
    case stillImageArea
    case stillImageSize
    case stillQuality
    case stillRawCompression
    case stillUserModeProgram
    case stillPictureControl

    /// Whether this is one of the photography (stills) controls. Stills writes follow the iOS
    /// pattern: fixed shared-core ladders encoded by label, the body as the final authority —
    /// never gated on a descriptor domain the camera may not advertise in photo mode.
    var isStillControl: Bool {
        switch self {
        case .stillISO, .stillISOAuto, .stillShutter, .stillIris, .stillDrive, .stillFocusMode,
            .stillFocusArea, .stillFocusSubject, .stillMeter, .stillImageArea, .stillImageSize,
            .stillQuality, .stillRawCompression, .stillUserModeProgram, .stillPictureControl:
            true
        default:
            false
        }
    }

    /// Whether a write must match the active Swift-owned capability snapshot.
    /// Exposure mode remains the one iOS-parity control whose fixed program labels are owned by
    /// the shared decoder rather than a body descriptor; the stills set mirrors iOS's
    /// label-encoded writes with the body as authority.
    var requiresCapabilityValidation: Bool {
        self != .exposureMode && self != .isoAuto && !isStillControl
    }

    /// When the capability domain is still empty (descriptor bootstrap pending, or
    /// mode-dependent options not yet known), allow an encode attempt for controls
    /// that the shared core can map from a human label. Codec/resolution and other
    /// raw-descriptor-only writes stay fail-closed until the body advertises them —
    /// matching iOS, which never invents packed MovScreenSize / MovFileType values.
    var allowsEncodeWithoutCapabilityDomain: Bool {
        switch self {
        case .iso, .isoAuto, .shutter, .iris, .whiteBalance, .focusMode, .focusArea, .focusSubject,
            .exposureMode, .audioSensitivity, .audioInput, .windFilter, .attenuator,
            .audio32BitFloat, .shutterMode, .shutterLock, .vibrationReduction, .baseISO:
            // baseISO: the capture-bar dual-base tabs always send Low/High; encode when the
            // active codec is dual-base even if the MovieBaseISO descriptor has not landed.
            true
        case .whiteBalanceTint, .resolutionFrameRate, .codec, .electronicVR:
            false
        default:
            // Stills controls skip capability validation outright (`isStillControl`), so this
            // flag never gates them.
            isStillControl
        }
    }

    /// Existing label-based controls whose byte policy already lives in the
    /// portable shared core.
    var sharedControl: PTPCameraControl? {
        switch self {
        case .iso: .iso
        case .isoAuto: .isoAuto
        case .shutter: .shutter
        case .iris: .iris
        case .whiteBalance: .whiteBalanceKelvin
        case .focusMode: .focusMode
        case .focusArea: .focusArea
        case .focusSubject: .focusSubject
        case .exposureMode: .exposureMode
        case .audioSensitivity: .audioSensitivity
        case .audioInput: .audioInput
        case .windFilter: .windFilter
        case .attenuator: .attenuator
        case .audio32BitFloat: .audio32BitFloat
        case .resolutionFrameRate: .resolution
        case .codec: .codec
        case .stillISO: .stillISO
        case .stillShutter: .stillShutter
        case .stillIris: .stillIris
        case .stillDrive: .stillDrive
        case .stillFocusMode: .stillFocus
        case .stillFocusArea: .stillFocusArea
        case .stillFocusSubject: .stillFocusSubject
        case .stillMeter: .stillMeter
        case .stillImageSize: .stillImageSize
        case .stillQuality: .stillQuality
        case .stillRawCompression: .stillRawCompression
        case .stillUserModeProgram: .stillUserModeProgram
        case .stillPictureControl: .stillPictureControl
        case .baseISO, .shutterMode, .shutterLock, .whiteBalanceTint,
            .vibrationReduction, .electronicVR, .stillISOAuto, .stillImageArea:
            // stillISOAuto / stillImageArea are session-local byte writes (no
            // shared label encoder), mirroring iOS's raw property writes.
            nil
        }
    }

    /// Maps the established shared-core control model into this Android-only
    /// superset for source-compatible facade tests and callers. Nil for the
    /// stills flash control the Android shell has not adopted.
    init?(_ control: PTPCameraControl) {
        switch control {
        case .iso: self = .iso
        case .isoAuto: self = .isoAuto
        case .shutter: self = .shutter
        case .iris: self = .iris
        case .whiteBalanceKelvin: self = .whiteBalance
        case .codec: self = .codec
        case .resolution: self = .resolutionFrameRate
        case .focusMode: self = .focusMode
        case .focusArea: self = .focusArea
        case .focusSubject: self = .focusSubject
        case .exposureMode: self = .exposureMode
        case .audioSensitivity: self = .audioSensitivity
        case .audioInput: self = .audioInput
        case .windFilter: self = .windFilter
        case .attenuator: self = .attenuator
        case .audio32BitFloat: self = .audio32BitFloat
        case .stillISO: self = .stillISO
        case .stillShutter: self = .stillShutter
        case .stillIris: self = .stillIris
        case .stillDrive: self = .stillDrive
        case .stillFocus: self = .stillFocusMode
        case .stillFocusArea: self = .stillFocusArea
        case .stillFocusSubject: self = .stillFocusSubject
        case .stillMeter: self = .stillMeter
        case .stillImageSize: self = .stillImageSize
        case .stillQuality: self = .stillQuality
        case .stillRawCompression: self = .stillRawCompression
        case .stillUserModeProgram: self = .stillUserModeProgram
        case .stillPictureControl: self = .stillPictureControl
        case .stillFlash:
            return nil
        }
    }
}

/// Semantic Android-to-Swift camera-control selectors.
///
/// This deliberately maps only human-readable controls, never Nikon property
/// identifiers or encoded payload values. `PTPCameraPropertyWrite` in the
/// shared core remains the sole source of protocol-write encoding.
enum AndroidCameraControlWire {
    /// Resolves one stable Kotlin selector to the shared core control model.
    static func control(selector: Int) -> AndroidCameraControl? {
        switch selector {
        case 0: return .iso
        case 1: return .shutter
        case 2: return .iris
        case 3: return .whiteBalance
        case 4: return .focusMode
        case 5: return .focusArea
        case 6: return .focusSubject
        case 7: return .exposureMode
        case 8: return .audioSensitivity
        case 9: return .audioInput
        case 10: return .windFilter
        case 11: return .attenuator
        case 12: return .audio32BitFloat
        case 13: return .baseISO
        case 14: return .shutterMode
        case 15: return .shutterLock
        case 16: return .whiteBalanceTint
        case 17: return .resolutionFrameRate
        case 18: return .codec
        case 19: return .vibrationReduction
        case 20: return .electronicVR
        case 21: return .isoAuto
        case 22: return .stillISO
        case 23: return .stillISOAuto
        case 24: return .stillShutter
        case 25: return .stillIris
        case 26: return .stillDrive
        case 27: return .stillFocusMode
        case 28: return .stillFocusArea
        case 29: return .stillFocusSubject
        case 30: return .stillMeter
        case 31: return .stillImageArea
        case 32: return .stillImageSize
        case 33: return .stillQuality
        case 34: return .stillRawCompression
        case 35: return .stillUserModeProgram
        case 36: return .stillPictureControl
        default: return nil
        }
    }
}
