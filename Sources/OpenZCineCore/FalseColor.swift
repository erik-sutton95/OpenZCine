import Foundation
import OpenCineMedia

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

/// Stable saved scale names. `Stops` retains the existing CineStop preference;
/// `Video` adds the shared video-level scale without moving the old native ordinals.
public enum FalseColorScale: String, CaseIterable, Codable, Sendable, Identifiable {
    case stops = "Stops"
    case ire = "IRE"
    case limits = "Limits"
    case video = "Video"

    public var id: String { rawValue }

    /// Canonical Media scale selected by this app's persisted value.
    public var sharedScale: LiveFalseColorScale {
        switch self {
        case .stops: .sceneStops
        case .video: .stops
        case .ire: .ire
        case .limits: .limits
        }
    }

    /// Painted zones using the default source profile.
    public var bands: [FalseColorBand] {
        bands(mapping: ExposureSignalMapping(curve: .redLog3G10))
    }

    /// Canonical zones for the calibrated source and LOG or built-in 709 reading.
    public func bands(mapping: ExposureSignalMapping, read709: Bool = false) -> [FalseColorBand] {
        FalseColorMap.sharedBands(scale: self, mapping: mapping, read709: read709).map {
            FalseColorBand(
                lowerBound: $0.lowerBound, upperBound: $0.upperBound,
                red: $0.red, green: $0.green, blue: $0.blue)
        }
    }

    /// Half-width of each feathered zone boundary.
    public var transitionWidth: Double { sharedScale.edgeSoftness }

    /// The canonical labels and colours for the default source profile.
    public var legendStops: [(label: String, band: FalseColorBand)] {
        legendStops(mapping: ExposureSignalMapping(curve: .redLog3G10))
    }

    /// The same labels and colours used by the calibrated renderer.
    public func legendStops(mapping: ExposureSignalMapping, read709: Bool = false)
        -> [(label: String, band: FalseColorBand)]
    {
        FalseColorMap.sharedBands(scale: self, mapping: mapping, read709: read709).map {
            (
                $0.label,
                FalseColorBand(
                    lowerBound: $0.lowerBound, upperBound: $0.upperBound,
                    red: $0.red, green: $0.green, blue: $0.blue)
            )
        }
    }
}

/// Calibrated source adapter for Media's canonical false-colour bands and painting.
public enum FalseColorMap {
    /// The centre of the canonical CineStop crush zone.
    public static let minimumSceneStop = -7.0

    /// Source scene stop where the canonical clip warning begins.
    public static func maximumSceneStop(mapping: ExposureSignalMapping, read709: Bool = false)
        -> Double
    {
        sharedBands(scale: .stops, mapping: mapping, read709: read709).last?.lowerBound
            ?? LiveColorScience.sceneStopDefaultClip
    }

    /// Source channels are decoded before scene-gamut luminance weighting.
    public static func linearLuminance(
        red: Double, green: Double, blue: Double, curve: ExposureToneCurve
    ) -> Double {
        let weights = LiveColorScience.lumaWeights(transfer(curve))
        return weights.red * curve.decode(encodedValue: red)
            + weights.green * curve.decode(encodedValue: green)
            + weights.blue * curve.decode(encodedValue: blue)
    }

    /// Encoded BT.709 luminance retained for signal diagnostics.
    public static func encodedAchromatic(red: Double, green: Double, blue: Double) -> Double {
        0.2126 * red + 0.7152 * green + 0.0722 * blue
    }

    /// Scale value from scene-linear luminance using the default source calibration.
    public static func exposureValue(
        linearLuminance: Double, scale: FalseColorScale, curve: ExposureToneCurve,
        read709: Bool = false
    ) -> Double {
        exposureValue(
            linearLuminance: linearLuminance, scale: scale,
            mapping: ExposureSignalMapping(curve: curve), read709: read709)
    }

    /// CineStop reads scene stops; video-level scales read the calibrated signal or 709 look.
    public static func exposureValue(
        linearLuminance: Double, scale: FalseColorScale, mapping: ExposureSignalMapping,
        read709: Bool = false
    ) -> Double {
        if scale == .stops { return LiveColorScience.stops(linear: linearLuminance) }
        return signalReading(
            encoded: mapping.curve.encode(linearLight: linearLuminance),
            scale: scale, mapping: mapping, read709: read709
        ).value
    }

    /// Scale value for a source pixel using the default clipping endpoint.
    public static func exposureValue(
        red: Double, green: Double, blue: Double, scale: FalseColorScale,
        curve: ExposureToneCurve, read709: Bool = false
    ) -> Double {
        exposureValue(
            red: red, green: green, blue: blue, scale: scale,
            mapping: ExposureSignalMapping(curve: curve), read709: read709)
    }

    /// CineStop decodes each source channel; other scales use the shared signal-luma reading.
    public static func exposureValue(
        red: Double, green: Double, blue: Double, scale: FalseColorScale,
        mapping: ExposureSignalMapping, read709: Bool = false
    ) -> Double {
        if scale == .stops {
            return LiveColorScience.stops(
                linear: linearLuminance(
                    red: red, green: green, blue: blue, curve: mapping.curve))
        }
        let weights = LiveColorScience.lumaWeights(transfer(mapping.curve))
        let encoded = weights.red * red + weights.green * green + weights.blue * blue
        return signalReading(
            encoded: encoded, scale: scale, mapping: mapping,
            read709: read709
        ).value
    }

    /// Categorical zone for a physical scale value and the default source calibration.
    public static func band(value: Double, scale: FalseColorScale) -> FalseColorBand? {
        band(value: value, scale: scale, mapping: ExposureSignalMapping(curve: .redLog3G10))
    }

    /// Categorical zone before feathering, including the source's canonical clip shelf.
    public static func band(
        value: Double, scale: FalseColorScale, mapping: ExposureSignalMapping,
        read709: Bool = false
    ) -> FalseColorBand? {
        let candidate = scale == .stops ? value : min(100, max(0, value))
        return scale.bands(mapping: mapping, read709: read709).first { $0.contains(candidate) }
    }

    /// Categorical zone for a source pixel using the default clipping endpoint.
    public static func band(
        red: Double, green: Double, blue: Double, scale: FalseColorScale,
        curve: ExposureToneCurve, read709: Bool = false
    ) -> FalseColorBand? {
        band(
            red: red, green: green, blue: blue, scale: scale,
            mapping: ExposureSignalMapping(curve: curve), read709: read709)
    }

    /// Categorical zone for a calibrated source pixel.
    public static func band(
        red: Double, green: Double, blue: Double, scale: FalseColorScale,
        mapping: ExposureSignalMapping, read709: Bool = false
    ) -> FalseColorBand? {
        band(
            value: exposureValue(
                red: red, green: green, blue: blue, scale: scale,
                mapping: mapping, read709: read709), scale: scale, mapping: mapping,
            read709: read709)
    }

    /// Composite paint for a source pixel using the default clipping endpoint.
    public static func mappedColor(
        red: Double, green: Double, blue: Double, scale: FalseColorScale,
        curve: ExposureToneCurve, read709: Bool = false
    ) -> (red: Double, green: Double, blue: Double) {
        mappedColor(
            red: red, green: green, blue: blue, scale: scale,
            mapping: ExposureSignalMapping(curve: curve), read709: read709)
    }

    /// Canonical paint with flat CineStop zones, monochrome video gaps, and intact Limits gaps.
    public static func mappedColor(
        red: Double, green: Double, blue: Double, scale: FalseColorScale,
        mapping: ExposureSignalMapping, read709: Bool = false
    ) -> (red: Double, green: Double, blue: Double) {
        let value = exposureValue(
            red: red, green: green, blue: blue, scale: scale,
            mapping: mapping, read709: read709)
        let gray: Double
        if scale == .stops {
            gray = MonitorDisplayToneMap(mapping: mapping).displayCode(
                sceneLinear: linearLuminance(
                    red: red, green: green, blue: blue, curve: mapping.curve))
        } else {
            gray = value / 100
        }
        return painting(scale: scale, mapping: mapping, read709: read709).compositeColor(
            value: value, monitorGray: gray, source: (red, green, blue))
    }

    /// Red-fastest composite cube using the default source clipping endpoint.
    public static func cube(
        scale: FalseColorScale, curve: ExposureToneCurve, size: Int = 64,
        read709: Bool = false
    ) -> CubeLUT {
        cube(
            scale: scale, mapping: ExposureSignalMapping(curve: curve), size: size, read709: read709
        )
    }

    /// Red-fastest composite cube with a calibrated source and an explicit reading mode.
    public static func cube(
        scale: FalseColorScale, mapping: ExposureSignalMapping, size: Int = 64,
        read709: Bool = false
    ) -> CubeLUT {
        lattice(scale: scale, mapping: mapping, size: size, read709: read709).cube(.composite)
    }

    /// Limits paint and opacity for a calibrated scale value.
    public static func limitsPaint(
        value: Double, mapping: ExposureSignalMapping, read709: Bool = false
    )
        -> (red: Double, green: Double, blue: Double, weight: Double)
    {
        painting(scale: .limits, mapping: mapping, read709: read709).paint(
            value: value, monitorGray: 0)
    }

    /// Limits paint indexed by the original source signal, composited over the existing grade.
    public static func limitsPaintCube(
        mapping: ExposureSignalMapping, size: Int = 64,
        read709: Bool = false
    ) -> CubeLUT {
        lattice(scale: .limits, mapping: mapping, size: size, read709: read709).cube(.paint)
    }

    /// Limits opacity indexed by the original source signal.
    public static func limitsWeightCube(
        mapping: ExposureSignalMapping, size: Int = 64,
        read709: Bool = false
    ) -> CubeLUT {
        lattice(scale: .limits, mapping: mapping, size: size, read709: read709).cube(.weight)
    }

    static func sharedBands(
        scale: FalseColorScale, mapping: ExposureSignalMapping,
        read709: Bool = false, latticeSize: Int? = nil
    ) -> [LiveFalseColorBand] {
        let source = transfer(mapping.curve)
        let clip = LiveColorScience.falseColorClip(
            scale: scale.sharedScale, transfer: source,
            rec709: read709, lookCurve: lookCurve(mapping.curve),
            clipEncoded: mapping.clipNative / 255)
        return LiveColorScience.falseColorBands(
            scale.sharedScale, transfer: clip.transfer,
            clipEncoded: clip.ceiling, latticeSize: latticeSize)
    }

    private static func painting(
        scale: FalseColorScale, mapping: ExposureSignalMapping,
        read709: Bool, latticeSize: Int? = nil
    ) -> MonitorFalseColorPainting {
        MonitorFalseColorPainting(
            bands: sharedBands(
                scale: scale, mapping: mapping, read709: read709, latticeSize: latticeSize),
            edgeSoftness: scale.transitionWidth,
            domain: scale == .stops ? .sceneStops : .monitorPercent,
            background: scale == .limits ? .source : .monitorGray)
    }

    private static func lattice(
        scale: FalseColorScale, mapping: ExposureSignalMapping, size: Int,
        read709: Bool
    ) -> MonitorFalseColorLattice {
        precondition(CubeLUT.rendererSizeRange.contains(size))
        if scale != .stops {
            return .signal(
                scale: scale.sharedScale, transfer: transfer(mapping.curve),
                clipByte: clipByte(mapping), lookCurve: lookCurve(mapping.curve),
                readThroughLook: read709, size: size)
        }
        let denominator = Double(size - 1)
        let decoded = (0..<size).map {
            mapping.curve.decode(encodedValue: Double($0) / denominator)
        }
        return .sceneLinear(
            decodedChannels: decoded,
            luminanceCoefficients: LiveColorScience.lumaWeights(transfer(mapping.curve)),
            tone: MonitorDisplayToneMap(mapping: mapping),
            painting: painting(scale: scale, mapping: mapping, read709: read709, latticeSize: size))
    }

    private static func signalReading(
        encoded: Double, scale: FalseColorScale,
        mapping: ExposureSignalMapping, read709: Bool
    ) -> (value: Double, gray: Double) {
        let source = transfer(mapping.curve)
        let read = LiveColorScience.falseColorReading(
            encoded: encoded, transfer: source,
            rec709: read709, lookCurve: lookCurve(mapping.curve), scale: scale.sharedScale)
        let value = OpenCineMedia.ScopeDisplayScale.monitorPercent(
            read.encoded, transfer: read.transfer,
            clipByte: read.transfer == source ? clipByte(mapping) : 255)
        return (value, value / 100)
    }

    private static func clipByte(_ mapping: ExposureSignalMapping) -> Int {
        min(255, max(1, Int(mapping.clipNative.rounded())))
    }

    private static func transfer(_ curve: ExposureToneCurve) -> MonitorTransfer {
        switch curve {
        case .redLog3G10: .log3G10
        case .nikonNLog: .nlog
        case .srgb: .srgb
        case .hlg: .hdr
        }
    }

    // Use the existing generated monitoring look, independent of the selected creative LUT.
    private static let monitorLookCurves: [ExposureToneCurve: [Double]] = {
        let looks: [(ExposureToneCurve, MonitorLUT)] = [
            (.redLog3G10, .log3G10Rec709), (.nikonNLog, .nLogRec709),
        ]
        return Dictionary(
            uniqueKeysWithValues: looks.map { curve, look in
                let cube = look.cube()
                let samples = (0...255).map { index in
                    let code = Float(index) / 255
                    let rgb = cube.map(red: code, green: code, blue: code)
                    return 0.2126 * Double(rgb.red) + 0.7152 * Double(rgb.green) + 0.0722
                        * Double(rgb.blue)
                }
                return (curve, samples)
            })
    }()

    /// Whether this source has an applied built-in monitor look for the requested read mode.
    public static func readsThroughLook(mapping: ExposureSignalMapping, read709: Bool) -> Bool {
        read709 && lookCurve(mapping.curve) != nil
    }

    private static func lookCurve(_ curve: ExposureToneCurve) -> [Double]? {
        monitorLookCurves[curve]
    }
}
