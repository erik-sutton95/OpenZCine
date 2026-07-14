// Baked feed-effect payloads crossing the JNI seam.
//
// Like `MonitorZoneMapWire`, this file compiles on every platform so the baking
// is exercised by `just native-check` on macOS against the exact colour math
// the iOS shell renders with. The Kotlin consumer is
// `Apps/Android/app/src/main/kotlin/com/opencapture/openzcine/FeedEffectsRenderer.kt`.
//
// Single source of truth rule: the CORE bakes every curve and cube
// (`MonitorLUT`, `FalseColorMap`, `ExposureSignalMapping`); Android only uploads
// the result as textures/uniforms and interpolates. No colour math is re-derived
// in Kotlin or AGSL.

import OpenZCineCore

/// Bakes monitor looks, false-colour cubes, and assist thresholds into flat
/// byte/float payloads for the Android GPU effect chain.
///
/// Cube payloads use a packed-2D RGBA8 layout ready for a `width = size²`,
/// `height = size` bitmap: pixel `(x = b·size + r, y = g)` carries the
/// red-fastest cube entry `r + g·size + b·size²`, so a shader samples slice `b`
/// as a `size × size` tile at x-offset `b·size` (bilinear in-tile, two taps +
/// mix across slices = trilinear).
public enum FeedEffectsWire {
    /// Built-in look ordinals, mirroring `FeedLut` in Kotlin:
    /// 0 = Log3G10→709, 1 = N-Log→709, 2 = Mono.
    static func look(_ ordinal: Int) -> MonitorLUT? {
        switch ordinal {
        case 0: .log3G10Rec709
        case 1: .nLogRec709
        case 2: .monochrome
        default: nil
        }
    }

    /// Signal-curve ordinals, mirroring the Kotlin constants:
    /// 0 = RED Log3G10, 1 = Nikon N-Log.
    static func curve(_ ordinal: Int) -> ExposureToneCurve? {
        switch ordinal {
        case 0: .redLog3G10
        case 1: .nikonNLog
        default: nil
        }
    }

    /// A built-in monitor look as a packed-2D RGBA8 grid (`size³ × 4` bytes),
    /// or `nil` for an unknown ordinal / unsupported size. 33³ matches the iOS
    /// built-ins (`MonitorLUT.cube`'s professional-`.cube` default).
    public static func bakedLUT(lookOrdinal: Int, size: Int = 33) -> [UInt8]? {
        guard let look = look(lookOrdinal), CubeLUT.supportedSizeRange.contains(size)
        else { return nil }
        return packedRGBA(cube: look.cube(size: size))
    }

    /// A false-colour cube (scale ordinal 0 = Stops, 1 = IRE) for the default
    /// camera mapping of the selected curve, as a packed-2D RGBA8 grid at the
    /// core's 64³ false-colour resolution. `nil` for unknown ordinals.
    /// (The Limits scale composites two cubes over the graded feed and ships
    /// with the assist-toolbar work, not this debug surface.)
    public static func bakedFalseColor(scaleOrdinal: Int, curveOrdinal: Int) -> [UInt8]? {
        guard let curve = curve(curveOrdinal) else { return nil }
        let scale: FalseColorScale? =
            switch scaleOrdinal {
            case 0: .stops
            case 1: .ire
            default: nil
            }
        guard let scale else { return nil }
        return packedRGBA(
            cube: FalseColorMap.cube(scale: scale, mapping: ExposureSignalMapping(curve: curve)))
    }

    /// Assist thresholds on the normalized 0–1 code axis, for shader uniforms:
    /// `[deLogBlack, deLogClip, zebraHighlight, zebraMidtoneCentre]`.
    ///
    /// The first pair anchors focus peaking's de-log stretch (the same
    /// `ExposureScale.referenceIRE(signalNative:)` remap the iOS peaking path
    /// applies before edge detection); the second pair converts the operator's
    /// monitor-percent zebra thresholds to native code exactly like
    /// `ImageEffectsCompositor.applyZebra`. `nil` for an unknown curve ordinal.
    public static func scalars(
        curveOrdinal: Int, zebraHighlightIRE: Double, zebraMidtoneIRE: Double
    ) -> [Float]? {
        guard let curve = curve(curveOrdinal) else { return nil }
        let mapping = ExposureSignalMapping(curve: curve)
        return [
            Float(mapping.blackNative / 255),
            Float(mapping.clipNative / 255),
            Float(mapping.signalNative(monitorPercent: zebraHighlightIRE) / 255),
            Float(mapping.signalNative(monitorPercent: zebraMidtoneIRE) / 255),
        ]
    }

    /// Reorders a red-fastest cube into the packed-2D bitmap layout and
    /// quantizes to RGBA8 (alpha 255).
    static func packedRGBA(cube: CubeLUT) -> [UInt8] {
        let size = cube.size
        var out = [UInt8](repeating: 255, count: size * size * size * 4)
        for g in 0..<size {
            for b in 0..<size {
                for r in 0..<size {
                    let src = (r + g * size + b * size * size) * 3
                    let dst = (g * size * size + b * size + r) * 4
                    out[dst] = quantized(cube.rgb[src])
                    out[dst + 1] = quantized(cube.rgb[src + 1])
                    out[dst + 2] = quantized(cube.rgb[src + 2])
                }
            }
        }
        return out
    }

    /// `[0, 1]` float component to an 8-bit code, round-to-nearest.
    static func quantized(_ value: Float) -> UInt8 {
        UInt8((min(max(value, 0), 1) * 255).rounded())
    }
}
