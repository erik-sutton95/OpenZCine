import OpenZCineCore

/// Semantic Android-to-Swift camera-control selectors.
///
/// This deliberately maps only human-readable controls, never Nikon property
/// identifiers or encoded payload values. `PTPCameraPropertyWrite` in the
/// shared core remains the sole source of protocol-write encoding.
enum AndroidCameraControlWire {
    /// Resolves one stable Kotlin selector to the shared core control model.
    static func control(selector: Int) -> PTPCameraControl? {
        switch selector {
        case 0: return .iso
        case 1: return .shutter
        case 2: return .iris
        case 3: return .whiteBalanceKelvin
        case 4: return .focusMode
        case 5: return .focusArea
        case 6: return .focusSubject
        case 7: return .exposureMode
        case 8: return .audioSensitivity
        case 9: return .audioInput
        case 10: return .windFilter
        case 11: return .attenuator
        case 12: return .audio32BitFloat
        default: return nil
        }
    }
}
