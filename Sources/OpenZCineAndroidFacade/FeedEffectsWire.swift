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
    public static let renderConfigurationFieldCount = 22

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
    /// 0 = RED Log3G10, 1 = Nikon N-Log, 2 = sRGB, 3 = HLG (stills previews).
    static func curve(_ ordinal: Int) -> ExposureToneCurve? {
        switch ordinal {
        case 0: .redLog3G10
        case 1: .nikonNLog
        case 2: .srgb
        case 3: .hlg
        default: nil
        }
    }

    /// Stable ordinal returned to Android after the shared core selected the
    /// active camera signal curve.
    static func curveOrdinal(_ curve: ExposureToneCurve) -> Int {
        switch curve {
        case .redLog3G10: 0
        case .nikonNLog: 1
        case .srgb: 2
        case .hlg: 3
        }
    }

    /// Resolves one camera-aware exposure mapping. A missing codec deliberately
    /// retains Android's previous Log3G10 fallback instead of treating absence
    /// as a positive N-Log report. Once a codec arrives, `ExposureSignalMapping`
    /// owns the R3D/N-Log and ISO-dependent warning policy.
    ///
    /// A non-nil `stillsToneMode` wins outright: the photography live view is a
    /// display-referred stills preview, so the assists anchor on the stills
    /// tone mode (sRGB, or HLG when the body reports it) instead of the movie
    /// codec's log curve. Empty means "photo selector active, tone unreported"
    /// and resolves to the sRGB default like iOS's `.stills(toneMode: nil)`.
    static func cameraMapping(
        codec: String?, iso: Int64, baseISO: String?, stillsToneMode: String? = nil
    ) -> ExposureSignalMapping {
        if let stillsToneMode {
            return .stills(toneMode: stillsToneMode.isEmpty ? nil : stillsToneMode)
        }
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
    public static func cameraMappingPayload(
        codec: String?, iso: Int64, baseISO: String?, stillsToneMode: String? = nil
    ) -> [Float] {
        let mapping = cameraMapping(
            codec: codec, iso: iso, baseISO: baseISO, stillsToneMode: stillsToneMode)
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
        codec: String?, iso: Int64, baseISO: String?, stillsToneMode: String? = nil,
        unitOrdinal: Int, monitorPercent: Double
    ) -> Float? {
        let mapping = cameraMapping(
            codec: codec, iso: iso, baseISO: baseISO, stillsToneMode: stillsToneMode)
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
        codec: String?, iso: Int64, baseISO: String?, stillsToneMode: String? = nil,
        unitOrdinal: Int, value: Double
    ) -> Float? {
        let mapping = cameraMapping(
            codec: codec, iso: iso, baseISO: baseISO, stillsToneMode: stillsToneMode)
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

    /// Renderer-ready false-colour reference geometry:
    /// `[version, curveOrdinal, segmentCount, markerCount,
    /// (lowerFraction, upperFraction, red, green, blue) × segmentCount,
    /// stopMarkerFraction × markerCount]`.
    ///
    /// Segment and marker placement use the exact camera-aware scale domain as
    /// the iOS reference panel. Android only lays out this returned geometry;
    /// it never recreates exposure bands or curve policy.
    public static func falseColorReference(
        scaleOrdinal: Int, curveOrdinal: Int, clipNative: Double
    ) -> [Float]? {
        guard let scale = falseColorScale(scaleOrdinal),
            let mapping = mapping(curveOrdinal: curveOrdinal, clipNative: clipNative)
        else { return nil }
        let segments = falseColorReferenceSegments(scale: scale, mapping: mapping)
        let markers = falseColorReferenceMarkers(scale: scale, mapping: mapping)
        var result: [Float] = [
            1, Float(Self.curveOrdinal(mapping.curve)), Float(segments.count),
            Float(markers.count),
        ]
        result.reserveCapacity(4 + segments.count * 5 + markers.count)
        for segment in segments {
            result.append(Float(segment.lower))
            result.append(Float(segment.upper))
            let band = segment.band
            result.append(Float(band.red))
            result.append(Float(band.green))
            result.append(Float(band.blue))
        }
        result.append(contentsOf: markers.map(Float.init))
        return result
    }

    private static func falseColorReferenceSegments(
        scale: FalseColorScale, mapping: ExposureSignalMapping
    ) -> [(lower: Double, upper: Double, band: FalseColorBand)] {
        let bands = scale.bands(mapping: mapping)
        switch scale {
        case .stops:
            let domain = falseColorStopReferenceDomain(mapping: mapping)
            return bands.map { band in
                (
                    falseColorStopFraction(band.lowerBound, domain: domain, infiniteFallback: 0),
                    falseColorStopFraction(band.upperBound, domain: domain, infiniteFallback: 1),
                    band
                )
            }
        case .ire, .limits:
            return bands.map { band in
                (
                    min(1, max(0, band.lowerBound / 100)),
                    band.upperBound.isFinite ? min(1, max(0, band.upperBound / 100)) : 1,
                    band
                )
            }
        }
    }

    private static func falseColorReferenceMarkers(
        scale: FalseColorScale, mapping: ExposureSignalMapping
    ) -> [Double] {
        guard scale == .stops else { return [] }
        let domain = falseColorStopReferenceDomain(mapping: mapping)
        let maximum = FalseColorMap.maximumSceneStop(mapping: mapping)
        return [FalseColorMap.minimumSceneStop, -3, 0, 1, 2, maximum].map {
            falseColorStopFraction($0, domain: domain, infiniteFallback: 0)
        }
    }

    private static func falseColorStopReferenceDomain(
        mapping: ExposureSignalMapping
    ) -> ClosedRange<Double> {
        let lower = FalseColorMap.minimumSceneStop - 1.0 / 6
        let upper = max(6, FalseColorMap.maximumSceneStop(mapping: mapping) + 1.0 / 6)
        return lower...upper
    }

    private static func falseColorStopFraction(
        _ value: Double, domain: ClosedRange<Double>, infiniteFallback: Double
    ) -> Double {
        guard value.isFinite else { return infiniteFallback }
        return min(1, max(0, (value - domain.lowerBound) / (domain.upperBound - domain.lowerBound)))
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
    /// `[curveOrdinal, clipNative, deLog0...deLog4, peakingThreshold,
    /// peakingRamp, peakR, peakG, peakB, highlightOn, highlightCode,
    /// highlightR, highlightG, highlightB, midtoneOn, midtoneCode, midtoneR,
    /// midtoneG, midtoneB]`. The five de-log values are the same quarter-axis
    /// tone-curve samples used by iOS's peaking compositor.
    public static func renderConfiguration(
        codec: String?, iso: Int64, baseISO: String?, stillsToneMode: String? = nil,
        peakingSensitivityOrdinal: Int, peakingColorOrdinal: Int, highlightEnabled: Bool,
        highlightIRE: Double, highlightColorOrdinal: Int, midtoneEnabled: Bool,
        midtoneIRE: Double, midtoneColorOrdinal: Int
    ) -> [Float]? {
        guard let sensitivity = peakingSensitivity(peakingSensitivityOrdinal),
            let peakingColor = peakingColor(peakingColorOrdinal),
            let highlightColor = zebraColor(highlightColorOrdinal),
            let midtoneColor = zebraColor(midtoneColorOrdinal)
        else { return nil }
        let mapping = cameraMapping(
            codec: codec, iso: iso, baseISO: baseISO, stillsToneMode: stillsToneMode)
        let highlightCode =
            mapping.signalNative(monitorPercent: min(max(highlightIRE, 0), 100)) / 255
        let midtoneCode = mapping.signalNative(monitorPercent: min(max(midtoneIRE, 0), 100)) / 255
        let peak = peakingColor.rgb
        let highlight = zebraRGB(highlightColor)
        let midtone = zebraRGB(midtoneColor)
        // Peaking de-log matches iOS ImageEffectsCompositor exactly: always
        // redLog3G10 quarter-axis samples (not the live camera curve). Using
        // the active camera mapping expands N-Log noise and over-peaks defocus.
        let deLog = (0...4).map { index in
            Float(
                ExposureScale.referenceIRE(
                    signalNative: Double(index) / 4 * 255, curve: .redLog3G10) / 100)
        }
        return [
            Float(curveOrdinal(mapping.curve)),
            Float(mapping.clipNative),
        ] + deLog + [
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
