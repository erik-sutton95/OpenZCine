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
    /// Stable field count for ``renderConfiguration``. Kotlin validates this
    /// exact record before it uploads a shader uniform, so a newer facade
    /// cannot be silently misread by an older APK.
    public static let renderConfigurationFieldCount = 19

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

    /// Stable ordinal returned to Android after the shared core selected the
    /// active camera signal curve.
    static func curveOrdinal(_ curve: ExposureToneCurve) -> Int {
        switch curve {
        case .redLog3G10: 0
        case .nikonNLog: 1
        }
    }

    /// Resolves one camera-aware exposure mapping. A missing codec deliberately
    /// retains Android's previous Log3G10 fallback instead of treating absence
    /// as a positive N-Log report. Once a codec arrives, `ExposureSignalMapping`
    /// owns the R3D/N-Log and ISO-dependent warning policy.
    static func cameraMapping(
        codec: String?, iso: Int64, baseISO: String?
    ) -> ExposureSignalMapping {
        let normalizedCodec = codec?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let normalizedCodec, !normalizedCodec.isEmpty else {
            return ExposureSignalMapping(curve: .redLog3G10)
        }
        return ExposureSignalMapping.camera(
            codec: normalizedCodec,
            iso: UInt32(exactly: iso),
            baseISO: baseISO)
    }

    /// Compact camera mapping consumed by the Android renderer, scope sampler,
    /// and zebra editor: `[curveOrdinal, blackNative, middleGrayNative,
    /// clipNative]`. Every value is resolved in Swift; Kotlin never infers a
    /// tone curve or a camera clip endpoint.
    public static func cameraMappingPayload(codec: String?, iso: Int64, baseISO: String?) -> [Float]
    {
        let mapping = cameraMapping(codec: codec, iso: iso, baseISO: baseISO)
        return [
            Float(curveOrdinal(mapping.curve)),
            Float(mapping.blackNative),
            Float(mapping.middleGrayNative),
            Float(mapping.clipNative),
        ]
    }

    /// Converts a canonical monitor-percent zebra threshold into the current
    /// editor unit (`0 = native code`, `1 = monitor IRE`).
    public static func zebraEditorValue(
        codec: String?, iso: Int64, baseISO: String?, unitOrdinal: Int,
        monitorPercent: Double
    ) -> Float? {
        let mapping = cameraMapping(codec: codec, iso: iso, baseISO: baseISO)
        let clamped = min(max(monitorPercent, 0), 100)
        switch unitOrdinal {
        case 0: return Float(mapping.signalNative(monitorPercent: clamped))
        case 1: return Float(clamped)
        default: return nil
        }
    }

    /// Converts a zebra editor value into the canonical 0…100 monitor axis.
    /// This keeps unit conversion at the Swift mapping seam rather than in the
    /// Android preference or Compose layers.
    public static func zebraMonitorPercent(
        codec: String?, iso: Int64, baseISO: String?, unitOrdinal: Int, value: Double
    ) -> Float? {
        let mapping = cameraMapping(codec: codec, iso: iso, baseISO: baseISO)
        switch unitOrdinal {
        case 0: return Float(mapping.monitorPercent(signalNative: value))
        case 1: return Float(min(max(value, 0), 100))
        default: return nil
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

    /// A false-colour cube for Stops (`0`) or IRE (`1`) using the current
    /// camera-derived clip endpoint. Limits (`2`) uses the two dedicated
    /// paint/mask payloads below so it leaves unflagged monitor colour intact.
    public static func bakedFalseColor(
        scaleOrdinal: Int, curveOrdinal: Int, clipNative: Double? = nil
    ) -> [UInt8]? {
        guard let scale = falseColorScale(scaleOrdinal), scale != .limits,
            let mapping = mapping(curveOrdinal: curveOrdinal, clipNative: clipNative)
        else { return nil }
        return packedRGBA(cube: FalseColorMap.cube(scale: scale, mapping: mapping))
    }

    /// Limits false-colour paint cube. It is composited over the selected LUT
    /// (or the untouched source) with the sibling weight cube.
    public static func bakedFalseColorLimitsPaint(
        curveOrdinal: Int, clipNative: Double
    ) -> [UInt8]? {
        guard let mapping = mapping(curveOrdinal: curveOrdinal, clipNative: clipNative) else {
            return nil
        }
        return packedRGBA(cube: FalseColorMap.limitsPaintCube(mapping: mapping))
    }

    /// Limits false-colour zone-weight cube, paired with
    /// ``bakedFalseColorLimitsPaint(curveOrdinal:clipNative:)``.
    public static func bakedFalseColorLimitsWeight(
        curveOrdinal: Int, clipNative: Double
    ) -> [UInt8]? {
        guard let mapping = mapping(curveOrdinal: curveOrdinal, clipNative: clipNative) else {
            return nil
        }
        return packedRGBA(cube: FalseColorMap.limitsWeightCube(mapping: mapping))
    }

    /// Compact false-colour reference strip: `[count, red, green, blue ×
    /// count]`, derived from the same scale bands that bake the displayed cube.
    /// Android displays these returned colours only; it never recreates the
    /// exposure palette.
    public static func falseColorReference(
        scaleOrdinal: Int, curveOrdinal: Int, clipNative: Double
    ) -> [Float]? {
        guard let scale = falseColorScale(scaleOrdinal),
            let mapping = mapping(curveOrdinal: curveOrdinal, clipNative: clipNative)
        else { return nil }
        let bands = scale.bands(mapping: mapping)
        var result = [Float(bands.count)]
        result.reserveCapacity(1 + bands.count * 3)
        for band in bands {
            result.append(Float(band.red))
            result.append(Float(band.green))
            result.append(Float(band.blue))
        }
        return result
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

    /// Complete renderer configuration, resolved exclusively from shared-core
    /// camera mapping and iOS-matched operator choices. The flat payload is:
    ///
    /// `[curveOrdinal, clipNative, deLogBlack, deLogClip, peakingThreshold,
    /// peakingRamp, peakR, peakG, peakB, highlightOn, highlightCode,
    /// highlightR, highlightG, highlightB, midtoneOn, midtoneCode, midtoneR,
    /// midtoneG, midtoneB]`.
    public static func renderConfiguration(
        codec: String?, iso: Int64, baseISO: String?, peakingSensitivityOrdinal: Int,
        peakingColorOrdinal: Int, highlightEnabled: Bool, highlightIRE: Double,
        highlightColorOrdinal: Int, midtoneEnabled: Bool, midtoneIRE: Double,
        midtoneColorOrdinal: Int
    ) -> [Float]? {
        guard let sensitivity = peakingSensitivity(peakingSensitivityOrdinal),
            let peakingColor = peakingColor(peakingColorOrdinal),
            let highlightColor = zebraColor(highlightColorOrdinal),
            let midtoneColor = zebraColor(midtoneColorOrdinal)
        else { return nil }
        let mapping = cameraMapping(codec: codec, iso: iso, baseISO: baseISO)
        let highlightCode =
            mapping.signalNative(monitorPercent: min(max(highlightIRE, 0), 100)) / 255
        let midtoneCode = mapping.signalNative(monitorPercent: min(max(midtoneIRE, 0), 100)) / 255
        let peak = peakingColor.rgb
        let highlight = zebraRGB(highlightColor)
        let midtone = zebraRGB(midtoneColor)
        return [
            Float(curveOrdinal(mapping.curve)),
            Float(mapping.clipNative),
            Float(mapping.blackNative / 255),
            Float(mapping.clipNative / 255),
            Float(sensitivity * 0.06),
            160,
            Float(peak.0), Float(peak.1), Float(peak.2),
            highlightEnabled ? 1 : 0,
            Float(highlightCode),
            Float(highlight.0), Float(highlight.1), Float(highlight.2),
            midtoneEnabled ? 1 : 0,
            Float(midtoneCode),
            Float(midtone.0), Float(midtone.1), Float(midtone.2),
        ]
    }

    private static func mapping(curveOrdinal: Int, clipNative: Double?) -> ExposureSignalMapping? {
        guard let curve = curve(curveOrdinal) else { return nil }
        let resolvedClip: Double
        if let clipNative, clipNative.isFinite {
            resolvedClip = clipNative
        } else {
            resolvedClip = curve.defaultClipNative
        }
        return ExposureSignalMapping(curve: curve, clipNative: resolvedClip)
    }

    private static func falseColorScale(_ ordinal: Int) -> FalseColorScale? {
        switch ordinal {
        case 0: .stops
        case 1: .ire
        case 2: .limits
        default: nil
        }
    }

    /// iOS `Peaking.Sensitivity.peakingThreshold`, kept in the facade so
    /// Android only uploads the resolved detector threshold.
    private static func peakingSensitivity(_ ordinal: Int) -> Double? {
        switch ordinal {
        case 0: 0.05
        case 1: 0.035
        case 2: 0.022
        default: nil
        }
    }

    private static func peakingColor(_ ordinal: Int) -> Peaking.Color? {
        switch ordinal {
        case 0: .white
        case 1: .blue
        case 2: .red
        case 3: .green
        default: nil
        }
    }

    private static func zebraColor(_ ordinal: Int) -> AssistConfiguration.Zebra.StripeColor? {
        switch ordinal {
        case 0: .white
        case 1: .amber
        case 2: .red
        case 3: .cyan
        case 4: .green
        default: nil
        }
    }

    private static func zebraRGB(
        _ color: AssistConfiguration.Zebra.StripeColor
    ) -> (Double, Double, Double) {
        switch color {
        case .white: (1, 1, 1)
        case .amber: (1, 0.72, 0.2)
        case .red: (1, 0.15, 0.15)
        case .cyan: (0, 0.85, 0.9)
        case .green: (0.2, 0.9, 0.35)
        }
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
