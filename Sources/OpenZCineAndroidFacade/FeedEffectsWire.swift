// Baked feed-effect payloads crossing the JNI seam.
//
// This file compiles on every platform so the baking
// is exercised by `just native-check` on macOS against the exact colour math
// the iOS shell renders with. The Kotlin consumer is
// `Apps/Android/app/src/main/kotlin/com/opencapture/openzcine/FeedEffectsRenderer.kt`.
//
// Single source of truth rule: the CORE bakes every curve and cube
// (`MonitorLUT`, `FalseColorMap`, `ExposureSignalMapping`); Android only uploads
// the result as textures/uniforms and interpolates. No colour math is re-derived
// in Kotlin or AGSL.

import OpenZCineCore

import struct OpenCineMedia.MonitorFalseColorReferencePlan
import enum OpenCineMedia.MonitorZebraPaint

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
    /// 0 = Log3G10→709, 1 = N-Log→709, 2 = Mono, 3 = R3D NE Monitor.
    static func look(_ ordinal: Int) -> MonitorLUT? {
        switch ordinal {
        case 0: .log3G10Rec709
        case 1: .nLogRec709
        case 2: .monochrome
        case 3: .r3dNEMonitor
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
        guard let look = look(lookOrdinal), CubeLUT.rendererSizeRange.contains(size)
        else { return nil }
        return packedRGBA(cube: look.cube(size: size))
    }

    /// A false-colour cube for CineStop (`0`), IRE (`1`) or Video (`3`).
    /// Add `4` to the scale ordinal for the built-in 709 reading. Uses the current
    /// camera-derived clip endpoint. Limits (`2`) uses the two dedicated
    /// paint/mask payloads below so it leaves unflagged monitor colour intact.
    public static func bakedFalseColor(
        scaleOrdinal: Int, curveOrdinal: Int, clipNative: Double? = nil
    ) -> [UInt8]? {
        guard let selection = falseColorSelection(scaleOrdinal), selection.scale != .limits,
            let mapping = mapping(curveOrdinal: curveOrdinal, clipNative: clipNative)
        else { return nil }
        return packedRGBA(
            cube: FalseColorMap.cube(
                scale: selection.scale, mapping: mapping, read709: selection.read709))
    }

    /// Limits false-colour paint cube. It is composited over the selected LUT
    /// (or the untouched source) with the sibling weight cube. Add `4` to the
    /// curve ordinal for 709; the underlying source curve ordinal remains `0...3`.
    public static func bakedFalseColorLimitsPaint(
        curveOrdinal: Int, clipNative: Double
    ) -> [UInt8]? {
        guard let selection = falseColorCurveSelection(curveOrdinal),
            let mapping = mapping(curveOrdinal: selection.ordinal, clipNative: clipNative)
        else { return nil }
        return packedRGBA(
            cube: FalseColorMap.limitsPaintCube(mapping: mapping, read709: selection.read709))
    }

    /// Limits false-colour zone-weight cube, paired with
    /// ``bakedFalseColorLimitsPaint(curveOrdinal:clipNative:)``.
    public static func bakedFalseColorLimitsWeight(
        curveOrdinal: Int, clipNative: Double
    ) -> [UInt8]? {
        guard let selection = falseColorCurveSelection(curveOrdinal),
            let mapping = mapping(curveOrdinal: selection.ordinal, clipNative: clipNative)
        else { return nil }
        return packedRGBA(
            cube: FalseColorMap.limitsWeightCube(mapping: mapping, read709: selection.read709))
    }

    /// Current monitor pixels use the shared signal projection. Legacy public bakers above
    /// retain their pinned compatibility vectors until their consumers migrate.
    public static func bakedMonitorFalseColor(
        scaleOrdinal: Int, curveOrdinal: Int, clipNative: Double? = nil
    ) -> [UInt8]? {
        guard let selection = falseColorSelection(scaleOrdinal), selection.scale != .limits,
            let mapping = mapping(curveOrdinal: curveOrdinal, clipNative: clipNative)
        else { return nil }
        return packedRGBA(
            cube: NikonMonitorSignal.lattice(
                scale: selection.scale, mapping: mapping,
                read709: selection.read709
            ).cube(.composite))
    }

    /// Shared monitor limits paint paired with the weight payload.
    public static func bakedMonitorFalseColorLimitsPaint(curveOrdinal: Int, clipNative: Double)
        -> [UInt8]?
    {
        guard let selection = falseColorCurveSelection(curveOrdinal),
            let mapping = mapping(curveOrdinal: selection.ordinal, clipNative: clipNative)
        else { return nil }
        return packedRGBA(
            cube: NikonMonitorSignal.lattice(
                scale: .limits, mapping: mapping,
                read709: selection.read709
            ).cube(.paint))
    }

    /// Shared monitor limits weight paired with the paint payload.
    public static func bakedMonitorFalseColorLimitsWeight(curveOrdinal: Int, clipNative: Double)
        -> [UInt8]?
    {
        guard let selection = falseColorCurveSelection(curveOrdinal),
            let mapping = mapping(curveOrdinal: selection.ordinal, clipNative: clipNative)
        else { return nil }
        return packedRGBA(
            cube: NikonMonitorSignal.lattice(
                scale: .limits, mapping: mapping,
                read709: selection.read709
            ).cube(.weight))
    }

    /// Renderer-ready false-colour reference geometry:
    /// `[version, curveOrdinal, segmentCount, markerCount,
    /// (lowerFraction, upperFraction, red, green, blue) × segmentCount,
    /// stopMarkerFraction × markerCount]`.
    ///
    /// Segment and marker placement use the exact camera-aware scale domain as
    /// the iOS reference panel. Android only lays out this returned geometry;
    /// it never recreates exposure bands or curve policy.
    /// Version 2 source ruler: the shared bands plus typed stop/clip marker records.
    /// The version 1 compatibility entry remains available beside this monitor entry.
    public static func bakedMonitorFalseColorReference(
        scaleOrdinal: Int, curveOrdinal: Int, clipNative: Double
    ) -> [Float]? {
        guard let selection = falseColorSelection(scaleOrdinal),
            let mapping = mapping(curveOrdinal: curveOrdinal, clipNative: clipNative)
        else { return nil }
        let plan = MonitorFalseColorReferencePlan(
            scale: selection.scale.sharedScale,
            transfer: mapping.curve.monitorTransfer, clipByte: mapping.clipByte,
            lookCurve: NikonMonitorSignal.lookCurves[mapping.curve.monitorTransfer],
            readThroughLook: selection.read709)
        var result: [Float] = [
            2, Float(Self.curveOrdinal(mapping.curve)),
            Float(plan.segments.count), Float(plan.markers.count),
        ]
        for segment in plan.segments {
            result += [
                Float(segment.lowerFraction), Float(segment.upperFraction),
                Float(segment.band.red), Float(segment.band.green), Float(segment.band.blue),
            ]
        }
        for marker in plan.markers {
            result += [
                marker.kind == .clip ? 1 : 0, Float(marker.sceneStop), Float(marker.fraction),
            ]
        }
        return result
    }

    public static func falseColorReference(
        scaleOrdinal: Int, curveOrdinal: Int, clipNative: Double
    ) -> [Float]? {
        guard let selection = falseColorSelection(scaleOrdinal),
            let mapping = mapping(curveOrdinal: curveOrdinal, clipNative: clipNative)
        else { return nil }
        let segments = falseColorReferenceSegments(
            scale: selection.scale, mapping: mapping, read709: selection.read709)
        let markers = falseColorReferenceMarkers(
            scale: selection.scale, mapping: mapping, read709: selection.read709)
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
        scale: FalseColorScale, mapping: ExposureSignalMapping, read709: Bool
    ) -> [(lower: Double, upper: Double, band: FalseColorBand)] {
        let bands = scale.bands(mapping: mapping, read709: read709)
        switch scale {
        case .stops:
            let domain = falseColorStopReferenceDomain(mapping: mapping, read709: read709)
            return bands.map { band in
                (
                    falseColorStopFraction(band.lowerBound, domain: domain, infiniteFallback: 0),
                    falseColorStopFraction(band.upperBound, domain: domain, infiniteFallback: 1),
                    band
                )
            }
        case .video, .ire, .limits:
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
        scale: FalseColorScale, mapping: ExposureSignalMapping, read709: Bool
    ) -> [Double] {
        guard scale == .stops else { return [] }
        let domain = falseColorStopReferenceDomain(mapping: mapping, read709: read709)
        let maximum = FalseColorMap.maximumSceneStop(mapping: mapping, read709: read709)
        return [FalseColorMap.minimumSceneStop, -2, -1, 0, 1, 2, maximum].map {
            falseColorStopFraction($0, domain: domain, infiniteFallback: 0)
        }
    }

    private static func falseColorStopReferenceDomain(
        mapping: ExposureSignalMapping, read709: Bool
    ) -> ClosedRange<Double> {
        let lower = FalseColorMap.minimumSceneStop - 0.5
        let upper = max(6, FalseColorMap.maximumSceneStop(mapping: mapping, read709: read709) + 0.5)
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
    /// `[curveOrdinal, clipNative, deLog0...deLog4, peakingRatioThreshold,
    /// peakingNoiseGate, peakR, peakG, peakB, highlightOn, highlightCode,
    /// highlightR, highlightG, highlightB, midtoneOn, midtoneCode, midtoneR,
    /// midtoneG, midtoneB]`. The five de-log values are the quarter-axis tone-curve
    /// samples of the active curve; peaking no longer consumes them (it measures a
    /// blur ratio on the raw source - see `Peaking`), and the slots are kept so the
    /// record layout and the Vulkan uniform block stay put.
    ///
    /// `peakingNoiseGate` arrives already scaled for the feed's own encoding, so the shaders
    /// compare it directly and hold no mode policy of their own.
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
        let highlight = highlightColor.rgb
        let midtone = midtoneColor.rgb
        let deLog = (0...4).map { index in
            Float(
                ExposureScale.referenceIRE(
                    signalNative: Double(index) / 4 * 255, curve: mapping.curve) / 100)
        }
        // Assembled in named steps, not one literal: as a single expression this exceeded the
        // type checker's budget on the Xcode-default toolchain.
        var record: [Float] = [
            Float(curveOrdinal(mapping.curve)),
            Float(mapping.clipNative),
        ]
        record += deLog
        // The shared gate follows the resolved source curve, also used by scopes and zebra.
        let gateScale = mapping.curve.monitorTransfer.peakingGateScale
        record.append(Float(sensitivity.ratioThreshold))
        record.append(Float(sensitivity.noiseGate * gateScale))
        record += [Float(peak.0), Float(peak.1), Float(peak.2)]
        record.append(highlightEnabled ? 1 : 0)
        record.append(Float(highlightCode))
        record += [Float(highlight.0), Float(highlight.1), Float(highlight.2)]
        record.append(midtoneEnabled ? 1 : 0)
        record.append(Float(midtoneCode))
        record += [Float(midtone.0), Float(midtone.1), Float(midtone.2)]
        return record
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

    private static func falseColorSelection(_ ordinal: Int)
        -> (scale: FalseColorScale, read709: Bool)?
    {
        guard (0...7).contains(ordinal) else { return nil }
        let scale: FalseColorScale
        switch ordinal % 4 {
        case 0: scale = .stops
        case 1: scale = .ire
        case 2: scale = .limits
        default: scale = .video
        }
        return (scale, ordinal >= 4)
    }

    private static func falseColorCurveSelection(_ ordinal: Int)
        -> (ordinal: Int, read709: Bool)?
    {
        guard (0...7).contains(ordinal) else { return nil }
        return (ordinal % 4, ordinal >= 4)
    }

    /// The operator-facing step; the detector constants behind it live in shared core
    /// (`Peaking.Sensitivity`) so both shells resolve the same numbers.
    private static func peakingSensitivity(_ ordinal: Int) -> Peaking.Sensitivity? {
        switch ordinal {
        case 0: .low
        case 1: .medium
        case 2: .high
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

    private static func zebraColor(_ ordinal: Int) -> MonitorZebraPaint? {
        switch ordinal {
        case 0: .white
        case 1: .amber
        case 2: .red
        case 3: .cyan
        case 4: .green
        default: nil
        }
    }

    /// Reorders a red-fastest cube into the packed-2D bitmap layout and
    /// quantizes to RGBA8 (alpha 255).
    static func packedRGBA(cube: CubeLUT) -> [UInt8] {
        cube.packedRGBA
    }

    /// `[0, 1]` float component to an 8-bit code, round-to-nearest.
    static func quantized(_ value: Float) -> UInt8 {
        CubeLUT.quantizedRGBAChannel(value)
    }
}
