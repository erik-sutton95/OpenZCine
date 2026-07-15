import OpenZCineCore

/// Android camera controls resolved entirely inside the Swift facade.
///
/// Kotlin sends only these semantic selectors and camera-advertised labels. The
/// active session retains every descriptor's exact raw value and builds the
/// corresponding `PTPCameraPropertyWrite`; no Nikon value crosses JNI.
enum AndroidCameraControl: Hashable, Sendable {
    case iso
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

    /// Existing label-based controls whose byte policy already lives in the
    /// portable shared core.
    var sharedControl: PTPCameraControl? {
        switch self {
        case .iso: .iso
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
        case .baseISO, .shutterMode, .shutterLock, .whiteBalanceTint,
            .vibrationReduction, .electronicVR:
            nil
        }
    }

    /// Maps the established shared-core control model into this Android-only
    /// superset for source-compatible facade tests and callers.
    init(_ control: PTPCameraControl) {
        switch control {
        case .iso: self = .iso
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
        default: return nil
        }
    }
}
