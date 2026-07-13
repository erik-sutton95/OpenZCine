import Foundation

/// Shared scene-linear to monitor-code tone mapping for generated display LUTs and false colour.
///
/// This is an original, deterministic display transform. It anchors 18% scene grey near 41 IRE,
/// applies a gentle log-domain contrast slope, and rolls the selected scene-white point to display
/// white. Camera transfer functions are decoded before this transform is used.
struct MonitorDisplayToneMap: Equatable, Sendable {
    /// Display-linear value which becomes 0.42 after the BT.1886 inverse EOTF, placing 18% grey
    /// safely inside the published 41–48 IRE middle-grey zone.
    static let middleGrayDisplayLinear = pow(0.42, 2.4)
    static let defaultContrast = 1.1

    let contrast: Double
    let whitePoint: Double
    private let gain: Double
    private let whiteReinhard: Double

    /// Creates a transform from a scene-linear white value (`0.18` is middle grey).
    init(sceneWhite: Double, contrast: Double = Self.defaultContrast) {
        self.contrast = contrast
        let whitePoint = max(sceneWhite / 0.18, 0.000_001)
        self.whitePoint = whitePoint
        let contrastedWhite = pow(whitePoint, contrast)
        let whiteContribution = 1 / (contrastedWhite * contrastedWhite)
        let numerator = Self.middleGrayDisplayLinear - whiteContribution
        let gain = max(0.000_001, numerator / (1 - Self.middleGrayDisplayLinear))
        self.gain = gain
        whiteReinhard = gain * contrastedWhite
    }

    /// Creates a false-colour transform whose 100 IRE endpoint follows the camera's current clip.
    init(mapping: ExposureSignalMapping) {
        self.init(
            sceneWhite: mapping.curve.decode(encodedValue: mapping.clipNative / 255))
    }

    /// Scene-linear (`0.18` middle grey) to clamped display-linear intensity.
    func displayLinear(sceneLinear: Double) -> Double {
        let x = max(0, sceneLinear) / 0.18
        let contrasted = gain * pow(x, contrast)
        return min(1, max(0, reinhard(contrasted)))
    }

    /// Scene-linear intensity to the BT.1886-encoded monitor code range `[0, 1]`.
    func displayCode(sceneLinear: Double) -> Double {
        pow(displayLinear(sceneLinear: sceneLinear), 1 / 2.4)
    }

    /// Scene-linear intensity to full-range monitor IRE `[0, 100]`.
    func ire(sceneLinear: Double) -> Double {
        displayCode(sceneLinear: sceneLinear) * 100
    }

    private func reinhard(_ value: Double) -> Double {
        let white = whiteReinhard
        return value * (1 + value / (white * white)) / (1 + value)
    }
}
