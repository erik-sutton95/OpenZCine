import Foundation

/// One bounded zone of a false-colour measurement scale. Components are in `[0, 1]`.
public struct FalseColorBand: Equatable, Sendable {
    /// Inclusive lower bound in the selected scale's domain (stops or reference IRE).
    public let lowerBound: Double
    /// Exclusive upper bound in the selected scale's domain.
    public let upperBound: Double
    // Normalized display RGB for this zone.
    public let red: Double
    public let green: Double
    public let blue: Double

    public init(
        lowerBound: Double, upperBound: Double,
        red: Double, green: Double, blue: Double
    ) {
        self.lowerBound = lowerBound
        self.upperBound = upperBound
        self.red = red
        self.green = green
        self.blue = blue
    }

    /// Convenience for 8-bit colour literals.
    init(
        lowerBound: Double, upperBound: Double,
        rgb255: (Double, Double, Double)
    ) {
        self.init(
            lowerBound: lowerBound,
            upperBound: upperBound,
            red: rgb255.0 / 255,
            green: rgb255.1 / 255,
            blue: rgb255.2 / 255)
    }

    /// Whether `value` lies inside the inclusive-lower/exclusive-upper zone.
    public func contains(_ value: Double) -> Bool {
        value >= lowerBound && value < upperBound
    }
}

/// OpenZCine's independently tuned interpretation of the supplied RED ONE landmark colours.
/// RED publishes the landmark meanings, not normative RGB coordinates.
private enum ZCStopsPalette {
    static let minimum = (78.0, 11.0, 82.0)
    static let minusThree = (17.0, 149.0, 141.0)
    static let middleGrey = (8.0, 203.0, 24.0)
    static let skin = (245.0, 143.0, 148.0)
    static let plusTwo = (212.0, 208.0, 13.0)
    static let twoThirdsBelowMaximum = (255.0, 244.0, 0.0)
    static let oneThirdBelowMaximum = (255.0, 126.0, 18.0)
    static let maximum = (250.0, 60.0, 36.0)
}

private func zcMaximumSceneStop(mapping: ExposureSignalMapping) -> Double {
    let clipLinear = mapping.curve.decode(encodedValue: mapping.clipNative / 255)
    guard clipLinear.isFinite, clipLinear > 0 else { return 6 }
    return max(3.0, log2(clipLinear / 0.18))
}

/// Original muted RGB choices for the published RED Video Mode zone semantics. They follow the
/// supplied visual reference's restrained purple/blue, green, pink, straw, orange, and red language
/// without sampling or reproducing RED's unpublished RGB coordinates.
private enum ZCIREPalette {
    static let purple = (0.44, 0.22, 0.76)
    static let blue = (0.28, 0.37, 0.85)
    static let teal = (0.18, 0.58, 0.64)
    static let green = (0.38, 0.63, 0.35)
    static let pink = (0.83, 0.53, 0.71)
    static let straw = (0.83, 0.77, 0.45)
    static let yellow = (0.89, 0.72, 0.29)
    static let orange = (0.85, 0.55, 0.22)
    static let red = (0.78, 0.28, 0.18)
}

private enum FalseColorBandTable {
    /// Sparse one-third-stop landmarks on scene exposure. The upper warnings follow the camera's
    /// current mapped maximum rather than pretending that a fixed encoded value is always clip.
    static func zStopBands(mapping: ExposureSignalMapping) -> [FalseColorBand] {
        let maximum = zcMaximumSceneStop(mapping: mapping)
        return [
            FalseColorBand(
                lowerBound: -.infinity, upperBound: -35.0 / 6,
                rgb255: ZCStopsPalette.minimum),
            FalseColorBand(
                lowerBound: -19.0 / 6, upperBound: -17.0 / 6,
                rgb255: ZCStopsPalette.minusThree),
            FalseColorBand(
                lowerBound: -1.0 / 6, upperBound: 1.0 / 6,
                rgb255: ZCStopsPalette.middleGrey),
            FalseColorBand(
                lowerBound: 5.0 / 6, upperBound: 7.0 / 6,
                rgb255: ZCStopsPalette.skin),
            FalseColorBand(
                lowerBound: 11.0 / 6, upperBound: 13.0 / 6,
                rgb255: ZCStopsPalette.plusTwo),
            FalseColorBand(
                lowerBound: maximum - 5.0 / 6,
                upperBound: maximum - 1.0 / 2,
                rgb255: ZCStopsPalette.twoThirdsBelowMaximum),
            FalseColorBand(
                lowerBound: maximum - 1.0 / 2,
                upperBound: maximum - 1.0 / 6,
                rgb255: ZCStopsPalette.oneThirdBelowMaximum),
            FalseColorBand(
                lowerBound: maximum - 1.0 / 6, upperBound: .infinity,
                rgb255: ZCStopsPalette.maximum),
        ]
    }

    /// Published RED Video Mode IRE intervals represented as half-open numeric bands. RED documents
    /// the zone names and inclusive integer ranges; the RGB values and feathers remain OpenZCine's.
    static let zcIREBands: [FalseColorBand] = [
        FalseColorBand(
            lowerBound: 0, upperBound: 5,
            red: ZCIREPalette.purple.0,
            green: ZCIREPalette.purple.1,
            blue: ZCIREPalette.purple.2),
        FalseColorBand(
            lowerBound: 5, upperBound: 6,
            red: ZCIREPalette.blue.0,
            green: ZCIREPalette.blue.1,
            blue: ZCIREPalette.blue.2),
        FalseColorBand(
            lowerBound: 10, upperBound: 13,
            red: ZCIREPalette.teal.0,
            green: ZCIREPalette.teal.1,
            blue: ZCIREPalette.teal.2),
        FalseColorBand(
            lowerBound: 41, upperBound: 49,
            red: ZCIREPalette.green.0,
            green: ZCIREPalette.green.1,
            blue: ZCIREPalette.green.2),
        FalseColorBand(
            lowerBound: 61, upperBound: 71,
            red: ZCIREPalette.pink.0,
            green: ZCIREPalette.pink.1,
            blue: ZCIREPalette.pink.2),
        FalseColorBand(
            lowerBound: 92, upperBound: 94,
            red: ZCIREPalette.straw.0,
            green: ZCIREPalette.straw.1,
            blue: ZCIREPalette.straw.2),
        FalseColorBand(
            lowerBound: 94, upperBound: 96,
            red: ZCIREPalette.yellow.0,
            green: ZCIREPalette.yellow.1,
            blue: ZCIREPalette.yellow.2),
        FalseColorBand(
            lowerBound: 96, upperBound: 99,
            red: ZCIREPalette.orange.0,
            green: ZCIREPalette.orange.1,
            blue: ZCIREPalette.orange.2),
        FalseColorBand(
            lowerBound: 99, upperBound: .infinity,
            red: ZCIREPalette.red.0,
            green: ZCIREPalette.red.1,
            blue: ZCIREPalette.red.2),
    ]

    /// The four OpenZCine extreme-exposure zones. Unlike full IRE false colour, values between
    /// these zones keep the monitor's normal (graded) image: renderers composite this paint over
    /// the feed instead of replacing it, as a minimal clipping/crushing warning.
    static let limitBands: [FalseColorBand] = [
        FalseColorBand(
            lowerBound: 0, upperBound: 5,
            red: ZCIREPalette.purple.0, green: ZCIREPalette.purple.1,
            blue: ZCIREPalette.purple.2),
        FalseColorBand(
            lowerBound: 5, upperBound: 10,
            red: ZCIREPalette.blue.0, green: ZCIREPalette.blue.1,
            blue: ZCIREPalette.blue.2),
        FalseColorBand(
            lowerBound: 94, upperBound: 99,
            red: ZCIREPalette.yellow.0, green: ZCIREPalette.yellow.1,
            blue: ZCIREPalette.yellow.2),
        FalseColorBand(
            lowerBound: 99, upperBound: .infinity,
            red: ZCIREPalette.red.0, green: ZCIREPalette.red.1,
            blue: ZCIREPalette.red.2),
    ]

    static func bands(for scale: FalseColorScale, mapping: ExposureSignalMapping)
        -> [FalseColorBand]
    {
        switch scale {
        case .stops: zStopBands(mapping: mapping)
        case .ire: zcIREBands
        case .limits: limitBands
        }
    }
}

/// Which physical quantity false colour displays.
public enum FalseColorScale: String, CaseIterable, Codable, Sendable, Identifiable {
    /// Scene-linear exposure relative to 18% middle grey (`0 EV`), decoded through the selected log
    /// transfer function.
    case stops = "Stops"
    /// RED Video Mode-style zones on a curve-aware full-range monitor IRE transform.
    case ire = "IRE"
    /// OpenZCine shadow and highlight limit zones, with every other pixel keeping the image the
    /// monitor normally shows (the selected LUT's grade, or the untouched feed with no LUT).
    case limits = "Limits"

    public var id: String { rawValue }

    /// Painted zones ordered low to high. Stops and IRE gaps are monochrome; Limits gaps retain
    /// source colour.
    public var bands: [FalseColorBand] {
        bands(mapping: ExposureSignalMapping(curve: .redLog3G10))
    }

    /// Painted zones for a particular camera signal and clipping endpoint.
    public func bands(mapping: ExposureSignalMapping) -> [FalseColorBand] {
        FalseColorBandTable.bands(for: self, mapping: mapping)
    }

    /// Half-width of the smooth transition around each zone boundary, in the scale's own units.
    public var transitionWidth: Double {
        switch self {
        case .stops: 0.05
        case .ire, .limits: 0.5
        }
    }

    /// Every rendered colour and its operator-facing label, ordered low to high.
    public var legendStops: [(label: String, band: FalseColorBand)] {
        legendStops(mapping: ExposureSignalMapping(curve: .redLog3G10))
    }

    /// Legend entries for the selected camera signal mapping.
    public func legendStops(
        mapping: ExposureSignalMapping
    ) -> [(label: String, band: FalseColorBand)] {
        let bands = bands(mapping: mapping)
        switch self {
        case .stops:
            let labels = [
                "Minimum", "−3", "18%", "Skin +1", "+2",
                "⅔ below max", "⅓ below max", "Maximum",
            ]
            return zip(labels, bands).map { ($0, $1) }
        case .ire:
            let labels = [
                "0–4", "5", "10–12", "41–48", "61–70", "92–93", "94–95", "96–98",
                "99–100",
            ]
            return zip(labels, bands).map { ($0, $1) }
        case .limits:
            let labels = ["0–4", "5–9", "94–98", "99–100"]
            return zip(labels, bands).map { ($0, $1) }
        }
    }
}

/// Maps log-encoded RGB pixels into false-colour exposure bands and bakes the result into a
/// `CIColorCube`-compatible table for GPU rendering.
public enum FalseColorMap {
    /// Portion of encoded achromatic scene detail retained beneath ZC Stops' exposure hue. This
    /// keeps faces, edges, and broad tonal structure readable without weakening zone recognition.
    static let zcStopsDetailBlend = 0.4

    /// Lower endpoint used by the compact ZC Stops reference ruler. The minimum-exposure colour is
    /// centred on −6 stops and absorbs darker values.
    public static let minimumSceneStop = -6.0

    /// Camera-aware maximum exposure in stops above 18% grey, derived from the selected log curve
    /// and the current camera clipping code.
    public static func maximumSceneStop(mapping: ExposureSignalMapping) -> Double {
        zcMaximumSceneStop(mapping: mapping)
    }

    /// Scene-linear luminance reconstructed in the source gamut. The channels are decoded before
    /// weighting: REDWideGamutRGB uses RED's published XYZ Y row; N-Log/N-Gamut uses BT.2020 Y.
    public static func linearLuminance(
        red: Double, green: Double, blue: Double, curve: ExposureToneCurve
    ) -> Double {
        let coefficients = luminanceCoefficients(curve: curve)
        return coefficients.red * curve.decode(encodedValue: red)
            + coefficients.green * curve.decode(encodedValue: green)
            + coefficients.blue * curve.decode(encodedValue: blue)
    }

    /// Achromatic intensity on normalized encoded RGB, available for signal-domain diagnostics.
    public static func encodedAchromatic(red: Double, green: Double, blue: Double) -> Double {
        0.2126 * red + 0.7152 * green + 0.0722 * blue
    }

    /// The selected scale value for scene-linear luminance: stops relative to 18% grey, or
    /// curve-aware monitor IRE with 18% grey at 42 and the current clip at 100.
    public static func exposureValue(
        linearLuminance: Double, scale: FalseColorScale, curve: ExposureToneCurve
    ) -> Double {
        exposureValue(
            linearLuminance: linearLuminance, scale: scale,
            mapping: ExposureSignalMapping(curve: curve))
    }

    /// The selected scale value using a camera-aware clipping endpoint.
    public static func exposureValue(
        linearLuminance: Double, scale: FalseColorScale, mapping: ExposureSignalMapping
    ) -> Double {
        switch scale {
        case .stops:
            guard linearLuminance > 0 else { return -.infinity }
            return log2(linearLuminance / 0.18)
        case .ire, .limits:
            return MonitorDisplayToneMap(mapping: mapping).ire(sceneLinear: linearLuminance)
        }
    }

    /// The selected scale value for a canonical normalized log-encoded RGB pixel.
    public static func exposureValue(
        red: Double, green: Double, blue: Double,
        scale: FalseColorScale, curve: ExposureToneCurve
    ) -> Double {
        exposureValue(
            red: red, green: green, blue: blue, scale: scale,
            mapping: ExposureSignalMapping(curve: curve))
    }

    /// The selected scale value for an encoded RGB pixel using a camera-aware clipping endpoint.
    public static func exposureValue(
        red: Double, green: Double, blue: Double,
        scale: FalseColorScale, mapping: ExposureSignalMapping
    ) -> Double {
        exposureValue(
            linearLuminance: linearLuminance(
                red: red, green: green, blue: blue, curve: mapping.curve),
            scale: scale,
            mapping: mapping)
    }

    /// The painted zone for a value in the selected scale's physical domain. IRE and Limits return
    /// `nil` between their categorical zones so the renderer can use the appropriate passthrough.
    public static func band(value: Double, scale: FalseColorScale) -> FalseColorBand? {
        band(
            value: value, scale: scale,
            mapping: ExposureSignalMapping(curve: .redLog3G10))
    }

    /// The painted zone for a scale value using a camera-aware clipping endpoint.
    public static func band(
        value: Double, scale: FalseColorScale, mapping: ExposureSignalMapping
    ) -> FalseColorBand? {
        let candidate = scale == .stops ? value : min(100, max(0, value))
        return scale.bands(mapping: mapping).first { $0.contains(candidate) }
    }

    /// The false-colour zone for a canonical normalized log-encoded RGB pixel.
    public static func band(
        red: Double, green: Double, blue: Double,
        scale: FalseColorScale, curve: ExposureToneCurve
    ) -> FalseColorBand? {
        band(
            red: red, green: green, blue: blue, scale: scale,
            mapping: ExposureSignalMapping(curve: curve))
    }

    /// The false-colour zone for an encoded RGB pixel using a camera-aware clipping endpoint.
    public static func band(
        red: Double, green: Double, blue: Double,
        scale: FalseColorScale, mapping: ExposureSignalMapping
    ) -> FalseColorBand? {
        band(
            value: exposureValue(
                red: red, green: green, blue: blue, scale: scale, mapping: mapping),
            scale: scale, mapping: mapping)
    }

    /// The normalized RGB output for one log-encoded source pixel. ZC Stops and IRE gaps become
    /// achromatic, ZC landmarks retain luminance detail, and Limits gaps preserve the source pixel
    /// (the ungraded reference; renderers composite ``limitsPaint(value:mapping:)`` over the graded
    /// feed instead so gaps show exactly what the monitor shows with false colour off).
    public static func mappedColor(
        red: Double, green: Double, blue: Double,
        scale: FalseColorScale, curve: ExposureToneCurve
    ) -> (red: Double, green: Double, blue: Double) {
        mappedColor(
            red: red, green: green, blue: blue, scale: scale,
            mapping: ExposureSignalMapping(curve: curve))
    }

    /// The normalized false-colour RGB output using a camera-aware clipping endpoint.
    public static func mappedColor(
        red: Double, green: Double, blue: Double,
        scale: FalseColorScale, mapping: ExposureSignalMapping
    ) -> (red: Double, green: Double, blue: Double) {
        let luminance = linearLuminance(
            red: red, green: green, blue: blue, curve: mapping.curve)
        let monitorTone = MonitorDisplayToneMap(mapping: mapping)
        let value =
            scale == .stops
            ? exposureValue(linearLuminance: luminance, scale: scale, mapping: mapping)
            : monitorTone.ire(sceneLinear: luminance)
        let monitorGray = monitorTone.displayCode(sceneLinear: luminance)
        return renderedColor(
            value: value,
            scale: scale,
            mapping: mapping,
            source: (red, green, blue),
            monitorGray: monitorGray)
    }

    /// Builds a red-fastest false-colour cube. The 64³ default is Core Image's maximum supported
    /// dimension and resolves the short feather around zone boundaries; decoded channel values are
    /// precomputed to keep generation cheap.
    public static func cube(
        scale: FalseColorScale, curve: ExposureToneCurve, size: Int = 64
    ) -> CubeLUT {
        cube(scale: scale, mapping: ExposureSignalMapping(curve: curve), size: size)
    }

    /// Builds a red-fastest false-colour cube using a camera-aware clipping endpoint.
    public static func cube(
        scale: FalseColorScale, mapping: ExposureSignalMapping, size: Int = 64
    ) -> CubeLUT {
        precondition(
            (2...64).contains(size),
            "Core Image false-colour cubes require a dimension from 2 through 64.")
        let denominator = Double(size - 1)
        let encoded = (0..<size).map { Double($0) / denominator }
        let decoded = (0..<size).map {
            mapping.curve.decode(encodedValue: Double($0) / denominator)
        }
        let coefficients = luminanceCoefficients(curve: mapping.curve)
        let monitorTone = MonitorDisplayToneMap(mapping: mapping)
        var rgb = [Float]()
        rgb.reserveCapacity(size * size * size * 3)
        for b in 0..<size {
            for g in 0..<size {
                for r in 0..<size {
                    let luminance =
                        coefficients.red * decoded[r]
                        + coefficients.green * decoded[g]
                        + coefficients.blue * decoded[b]
                    let value =
                        scale == .stops
                        ? exposureValue(
                            linearLuminance: luminance, scale: scale, mapping: mapping)
                        : monitorTone.ire(sceneLinear: luminance)
                    let chosen = renderedColor(
                        value: value,
                        scale: scale,
                        mapping: mapping,
                        source: (encoded[r], encoded[g], encoded[b]),
                        monitorGray: monitorTone.displayCode(sceneLinear: luminance))
                    rgb.append(Float(chosen.red))
                    rgb.append(Float(chosen.green))
                    rgb.append(Float(chosen.blue))
                }
            }
        }
        return CubeLUT(size: size, rgb: rgb)
    }

    /// The feathered Limits paint for one monitor-IRE value: the normalized crush/clip zone colour
    /// and its composite weight — `0` between the zones, `1` deep inside them, smoothly blended
    /// across each boundary. Renderers composite `paint × weight` over the graded monitor image so
    /// every unflagged pixel keeps exactly what the operator sees with false colour off.
    public static func limitsPaint(
        value: Double, mapping: ExposureSignalMapping
    ) -> (red: Double, green: Double, blue: Double, weight: Double) {
        let scale = FalseColorScale.limits
        var paint = (red: 0.0, green: 0.0, blue: 0.0)
        var total = 0.0
        for band in scale.bands(mapping: mapping) {
            let weight = bandWeight(value: value, band: band, width: scale.transitionWidth)
            paint.red += band.red * weight
            paint.green += band.green * weight
            paint.blue += band.blue * weight
            total += weight
        }
        guard total > 0 else { return (0, 0, 0, 0) }
        // Adjacent zone feathers are complementary, so the summed weight never exceeds 1; the
        // clamp only guards floating-point noise.
        return (paint.red / total, paint.green / total, paint.blue / total, min(1, total))
    }

    /// Normalized Limits crush/clip paint colours indexed by log-encoded RGB, for GPU compositing:
    /// blend this over the graded feed with ``limitsWeightCube(mapping:size:)`` as the mask
    /// (`CIBlendWithMask`).
    public static func limitsPaintCube(
        mapping: ExposureSignalMapping, size: Int = 64
    ) -> CubeLUT {
        limitsCube(mapping: mapping, size: size) { ($0.red, $0.green, $0.blue) }
    }

    /// Grayscale Limits zone-weight mask indexed by log-encoded RGB: 1 inside the crush/clip
    /// zones, 0 between them, feathered across each zone boundary.
    public static func limitsWeightCube(
        mapping: ExposureSignalMapping, size: Int = 64
    ) -> CubeLUT {
        limitsCube(mapping: mapping, size: size) { ($0.weight, $0.weight, $0.weight) }
    }

    private static func limitsCube(
        mapping: ExposureSignalMapping, size: Int,
        component: ((red: Double, green: Double, blue: Double, weight: Double)) -> (
            Double, Double, Double
        )
    ) -> CubeLUT {
        precondition(
            (2...64).contains(size),
            "Core Image false-colour cubes require a dimension from 2 through 64.")
        let denominator = Double(size - 1)
        let decoded = (0..<size).map {
            mapping.curve.decode(encodedValue: Double($0) / denominator)
        }
        let coefficients = luminanceCoefficients(curve: mapping.curve)
        let monitorTone = MonitorDisplayToneMap(mapping: mapping)
        var rgb = [Float]()
        rgb.reserveCapacity(size * size * size * 3)
        for b in 0..<size {
            for g in 0..<size {
                for r in 0..<size {
                    let luminance =
                        coefficients.red * decoded[r]
                        + coefficients.green * decoded[g]
                        + coefficients.blue * decoded[b]
                    let chosen = component(
                        limitsPaint(
                            value: monitorTone.ire(sceneLinear: luminance), mapping: mapping))
                    rgb.append(Float(chosen.0))
                    rgb.append(Float(chosen.1))
                    rgb.append(Float(chosen.2))
                }
            }
        }
        return CubeLUT(size: size, rgb: rgb)
    }

    private static func renderedColor(
        value: Double,
        scale: FalseColorScale,
        mapping: ExposureSignalMapping,
        source: (red: Double, green: Double, blue: Double),
        monitorGray: Double
    ) -> (red: Double, green: Double, blue: Double) {
        let base: (red: Double, green: Double, blue: Double)
        switch scale {
        case .stops, .ire:
            let gray = min(1, max(0, monitorGray))
            base = (gray, gray, gray)
        case .limits:
            base = (
                min(1, max(0, source.red)),
                min(1, max(0, source.green)),
                min(1, max(0, source.blue))
            )
        }

        let weightedBands = scale.bands(mapping: mapping).map { band in
            (band, bandWeight(value: value, band: band, width: scale.transitionWidth))
        }
        let totalWeight = weightedBands.reduce(0) { $0 + $1.1 }
        guard totalWeight > 0 else { return base }
        let normalization = max(1, totalWeight)
        let baseWeight = max(0, 1 - totalWeight)
        let painted = weightedBands.reduce(
            (
                red: base.red * baseWeight, green: base.green * baseWeight,
                blue: base.blue * baseWeight
            )
        ) { result, item in
            let color = renderedBandColor(
                item.0, scale: scale, detailGray: monitorGray)
            return (
                result.red + color.red * item.1,
                result.green + color.green * item.1,
                result.blue + color.blue * item.1
            )
        }
        return (
            painted.red / normalization,
            painted.green / normalization,
            painted.blue / normalization
        )
    }

    private static func renderedBandColor(
        _ band: FalseColorBand,
        scale: FalseColorScale,
        detailGray: Double
    ) -> (red: Double, green: Double, blue: Double) {
        guard scale == .stops else { return (band.red, band.green, band.blue) }
        let gray = min(1, max(0, detailGray))
        let colorWeight = 1 - zcStopsDetailBlend
        return (
            band.red * colorWeight + gray * zcStopsDetailBlend,
            band.green * colorWeight + gray * zcStopsDetailBlend,
            band.blue * colorWeight + gray * zcStopsDetailBlend
        )
    }

    private static func bandWeight(
        value: Double, band: FalseColorBand, width: Double
    ) -> Double {
        let rising =
            band.lowerBound.isFinite && band.lowerBound != 0
            ? smoothStep(
                edge0: band.lowerBound - width,
                edge1: band.lowerBound + width,
                value: value)
            : 1
        let falling =
            band.upperBound.isFinite
            ? 1
                - smoothStep(
                    edge0: band.upperBound - width,
                    edge1: band.upperBound + width,
                    value: value)
            : 1
        return rising * falling
    }

    private static func smoothStep(edge0: Double, edge1: Double, value: Double) -> Double {
        let progress = min(1, max(0, (value - edge0) / (edge1 - edge0)))
        return progress * progress * (3 - 2 * progress)
    }

    private static func luminanceCoefficients(
        curve: ExposureToneCurve
    ) -> (red: Double, green: Double, blue: Double) {
        switch curve {
        case .redLog3G10:
            // REDWideGamutRGB → XYZ (Y row), RED white paper Rev C.
            return (0.286694, 0.842979, -0.129673)
        case .nikonNLog:
            // N-Gamut is BT.2020/D65, Nikon N-Log Specification v1.0.0.
            return (0.2627, 0.6780, 0.0593)
        }
    }
}
