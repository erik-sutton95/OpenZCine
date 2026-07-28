import Foundation

/// Focus peaking: paint the pixels the lens is currently rendering sharply.
///
/// The obvious detector — threshold the luma gradient — measures the wrong thing. For an edge of
/// amplitude `A` blurred by the lens to a radius `sigma`, the gradient peaks at `A / (sigma·√2π)`:
/// it scales with CONTRAST as much as with focus. A clipped specular highlight in a defocused
/// background therefore outranks genuinely sharp low-contrast detail like skin or fabric, so the
/// overlay paints the bokeh and skips the subject. That is not a tuning problem; no threshold
/// separates those two cases, because one number confounds two variables.
///
/// The fix is to measure the blur radius instead, which is what the operator RATIO at two scales
/// gives: run the operator on the source, run it again on a re-blurred copy, and divide. Amplitude
/// cancels exactly — the result depends only on `sigma`, running up to ``ratioCeiling`` for a
/// perfectly sharp edge and down to 1 for a fully defocused one. One threshold then holds from a
/// dim texture to a blown highlight. (Classical edge-based defocus estimation, cf. Zhuo & Sim,
/// *Defocus map estimation from a single image*, Pattern Recognition 2011, which recovers `sigma`
/// from exactly this ratio against a re-blurred copy.)
///
/// Two consequences worth keeping in mind:
///
/// * It is measured on the RAW source. The ratio is near-invariant to the camera's transfer
///   curve, so linearising first buys nothing — and the contrast stretch that used to run here
///   clamped everything above ~75% code value flat, which made in-focus HIGHLIGHT detail
///   undetectable no matter how sharp it was.
/// * Sensor noise is not lens-blurred, so it always reads as perfectly sharp. The ratio cannot
///   reject it; ``Sensitivity/noiseGate`` is what does.
///
/// ## One detector, four shells
///
/// This file is the definition and ``overlay(grey:width:height:sensitivity:gateScale:closing:)`` is
/// the executable form of it. The four GPU shells — Core Image on iOS, GLES2/Vulkan/AGSL on
/// Android — are transcriptions of that function, and `RunnerTests` renders it against the live
/// Core Image graph pixel-for-pixel so "transcription" stays a checked claim rather than an
/// intention.
///
/// Android used to carry its own second set of thresholds for its own operator (a central
/// difference at twice the spacing, 8 taps, thresholds 1.45/1.35/1.25). Two tables meant two
/// detectors, and an operator-facing "Med" that meant something different on each phone. There is
/// now one table, and the platform-specific numbers that remain are the ones the shells genuinely
/// cannot see for themselves: ``reblurWeights`` and ``closingOffsets`` are MEASURED off
/// `CIGaussianBlur` and `CIMorphologyMaximum` by impulse response, not taken from their docs.
public enum Peaking {

    /// Highlight colours (each `[0,1]` RGB) the operator can paint edges in.
    public enum Color: String, CaseIterable, Codable, Sendable, Identifiable {
        case white = "White"
        case blue = "Blue"
        case red = "Red"
        case green = "Green"

        public var id: String { rawValue }

        public var rgb: (Double, Double, Double) {
            switch self {
            case .white: (246.0 / 255, 241.0 / 255, 226.0 / 255)
            case .blue: (64.0 / 255, 142.0 / 255, 255.0 / 255)
            case .red: (255.0 / 255, 72.0 / 255, 64.0 / 255)
            case .green: (74.0 / 255, 220.0 / 255, 132.0 / 255)
            }
        }
    }

    /// How aggressively peaking flags edges. A higher level lowers the detector threshold so finer
    /// (and noisier) edges count. Raw values match the settings segmented control
    /// ("Low" / "Med" / "High").
    public enum Sensitivity: String, CaseIterable, Codable, Sendable, Identifiable {
        case low = "Low"
        case medium = "Med"
        case high = "High"

        public var id: String { rawValue }

        /// How sharp an edge must read before it is painted, as the two-scale ratio (see
        /// ``Peaking`` for why a ratio and not a magnitude). Higher = stricter.
        ///
        /// Ratios run from ``ratioCeiling`` (perfectly sharp) down to 1 (fully defocused). Measured
        /// against the same synthetic edge set: in-focus detail lands at 2.49…2.90, defocused
        /// background at 1.08…1.33, so these sit inside that gap.
        ///
        /// Shifted in step with ``noiseGate`` — a sensitivity step moves BOTH, so shifting only the
        /// gate would have handed Med the old Low's floor with Med's looser ratio bar and a 2.6:1
        /// discrimination instead of the 7.4:1 the old Low actually delivered. Med now reproduces
        /// the old Low exactly.
        public var ratioThreshold: Double {
            switch self {
            case .low: 2.30
            case .medium: 2.10
            case .high: 1.90
            }
        }

        /// Minimum coarse-operator energy before a pixel is considered at all, in ``robertsSquared``
        /// units — a SQUARED code-value slope, which is why it looks so much smaller than a
        /// gradient magnitude would.
        ///
        /// Sensor noise is not lens-blurred, so it always reads as perfectly sharp: the ratio
        /// cannot reject it and this gate is what keeps shadows from sparkling.
        ///
        /// Re-anchored and widened, and the two changes are inseparable from ``maskClosingRadius``
        /// — read that first. Med is 0.00174 rather than 0.00058 and yet paints exactly as much:
        /// closing fattens what survives, so the gate has to tighten by the same amount to land
        /// back on the old density. Measured, that trade is free — Med keeps its ink and its
        /// fragmentation falls from 18.9% to 1.6%.
        ///
        /// The ends then move by 3× either side, a 9× span against the old 2.9×, which is only
        /// safe because closing repairs the dashing a strict gate would otherwise cause.
        /// Shifted one whole step stricter, because measured against the real ZR sweep only the
        /// strict end discriminated at all. Focused frame against fully defocused frame, ink:
        ///
        /// | gate | focused | defocused | ratio |
        /// |---|---|---|---|
        /// | 0.00174 | 1.25 % | 0.17 % | **7.4 : 1** |
        /// | 0.00058 | 2.59 % | 0.88 % | 2.9 : 1 |
        /// | 0.00019 | 4.50 % | 2.51 % | 1.8 : 1 |
        ///
        /// At the old High a fully defocused frame painted more than half as much as a focused
        /// one, which is not a sensitivity setting so much as a coin toss — hence the report that
        /// Med and High were unusable and only Low was worth having. So Med becomes the old Low
        /// and the ladder slides down under it, keeping the 3× step.
        public var noiseGate: Double {
            switch self {
            case .low: 0.00522
            case .medium: 0.00174
            case .high: 0.00058
            }
        }
    }

    // MARK: - Detector constants

    /// Radius Core Image re-blurs by to reach the coarse scale, and the anchor for
    /// ``reblurWeights``.
    public static let reblurRadius = 1.0

    /// The re-blur as separable 1D weights: the coarse scale's actual kernel.
    ///
    /// MEASURED by impulse response, because `CIGaussianBlur`'s `inputRadius` is not a documented
    /// sigma and every calibrated constant above lives downstream of whatever it really does. At
    /// radius 1.0 it is a separable seven-tap whose 2D corners reproduce `k(i)·k(j)` to eight
    /// significant figures:
    ///
    /// | offset | 0 | ±1 | ±2 | ±3 |
    /// |---|---|---|---|---|
    /// | weight | 0.382992 | 0.241798 | 0.060662 | 0.006044 |
    ///
    /// That is close to a sigma-1.04 Gaussian but not equal to one (the ±2 tap sits 0.4% under and
    /// the ±3 tap 1.3% under), which is the whole reason for measuring rather than deriving. The
    /// Android shells convolve with these directly; iOS keeps the stock filter, which is where they
    /// came from.
    public static let reblurWeights = [
        0.006044, 0.060662, 0.241798, 0.382992, 0.241798, 0.060662, 0.006044,
    ]

    /// Ratio a perfectly sharp edge saturates at.
    ///
    /// Core Image reaches the ratio with a divide blend that clamps at 1, so the numerator is
    /// pre-shrunk by ``ratioScale`` and the thresholds shrunk to match. The ceiling that imposes is
    /// part of the calibrated detector rather than an artifact to be removed, so the shells that
    /// divide freely clamp to it explicitly.
    public static let ratioCeiling = 4.0

    /// Pre-shrink for Core Image's divide blend; the reciprocal of ``ratioCeiling`` by construction.
    public static var ratioScale: Double { 1 / ratioCeiling }

    /// Half-width of the antialiasing ramp on the peaking decision, in ratio units. Deliberately
    /// narrow — peaking reads as a drawn line, not a glow.
    ///
    /// The ramp is LINEAR. Core Image reaches it with a scale-and-clamp pair, so the shells clamp
    /// too rather than reaching for the `smoothstep` a shader would use by habit; on a ramp this
    /// narrow the Hermite curve is a visible difference in stroke weight, not a rounding one.
    public static let antialiasWidth = 0.12

    /// Where the dark under-hairline's ramp starts, below ``Sensitivity/ratioThreshold`` and in
    /// units of ``antialiasWidth``.
    ///
    /// The hairline is what stops a bright stroke from disappearing into a bright subject. Starting
    /// half a ramp early means it reaches half opacity exactly where the stroke is still at zero,
    /// so the stroke always has something to sit against.
    public static let underRampOffset = 0.5

    /// Colour of that hairline. Painted at its full ramp opacity, with the stroke composited over
    /// the top of it.
    public static let underColor = (red: 0.04, green: 0.04, blue: 0.05)

    /// Where the noise gate's ramp starts, as a fraction of ``Sensitivity/noiseGate``.
    public static let gateRampFloor = 0.7

    /// Border (in source pixels) where peaking never fires; the kernels would sample outside.
    public static let edgeInset = 6.0

    /// Radius, in source pixels, of the morphological CLOSING applied to the finished stroke.
    ///
    /// This is what lets the sensitivity range be wide. Only two knobs can make a setting
    /// stricter, and measured against a noisy frame they behave very differently:
    ///
    /// | change | fragmentation | grain |
    /// |---|---|---|
    /// | gate 0.00035 → 0.00100 | 25% → 75% | 0.0135% → 0% |
    /// | ratio threshold 2.10 → 3.20 | 25% → 71% | 0.0135% → 0.0127% |
    ///
    /// The ratio threshold is useless for this — grain is not lens-blurred, so it reads as
    /// perfectly sharp and raising the sharpness bar does not exclude it. So strictness has to
    /// come from the gate, and the gate's cost is fragmentation: it punches holes in edges that
    /// ARE sharp. A line broken into dashes reads as MORE noise than a continuous line, even
    /// with less ink on screen, which is how a stricter setting can look worse.
    ///
    /// Closing — dilate, then erode — rejoins those dashes without inventing a line where there
    /// was none. It is specifically closing and not opening: peaking strokes are about a pixel
    /// wide, so eroding first would delete the lines along with the specks. With it, a Low that
    /// is twice as strict comes out FOUR times smoother than the setting it replaces:
    ///
    /// | | ink | fragmented | grain |
    /// |---|---|---|---|
    /// | gate 0.00035, no closing | 24.6% | 25.3% | 0.0135% |
    /// | gate 0.00070, no closing | 14.7% | 48.1% | 0% |
    /// | gate 0.00070 + closing | 22.7% | **6.2%** | 0% |
    public static let maskClosingRadius = 1.0

    /// Structuring element of that closing, as `(dx, dy)` offsets.
    ///
    /// MEASURED, and not what the name suggests: `CIMorphologyMaximum` at radius 1 is a five-point
    /// PLUS, not the 3×3 square. Its impulse response paints exactly the centre and its four
    /// edge-neighbours, and `CIMorphologyMinimum` reaches the same five.
    ///
    /// The composition therefore spans a 13-point diamond (`|dx| + |dy| ≤ 2`), which is what makes
    /// closing expensive to fuse into a single fragment shader — 13 mask evaluations, each wanting
    /// its own re-blur neighbourhood, is roughly 130 live floats of intermediate state. That is a
    /// pass boundary in every renderer, which is why iOS spends two stock filters on it.
    public static let closingOffsets = [(0, 0), (1, 0), (-1, 0), (0, 1), (0, -1)]

    /// How much larger the operator reads on a DISPLAY-REFERRED feed than on the log feed the gates
    /// were calibrated against — the reason peaking behaved differently in photography mode.
    ///
    /// The ratio is transfer-curve invariant, as documented above, but the ``Sensitivity/noiseGate``
    /// is an absolute magnitude, and a display-referred preview spends far more code value per stop
    /// through the midtones than a log curve does. Same scene, same optical blur, larger numbers —
    /// so a gate calibrated on log sits effectively lower on an SDR photo feed, and the operator's
    /// chosen sensitivity step silently means something stricter in one mode than the other.
    /// Multiply the gate by this to make a step mean the same thing in both, SQUARED because
    /// ``robertsSquared`` works in a squared domain.
    ///
    /// Measured on the real corpus rather than derived: frame 19 pushed through the app's own
    /// Log3G10→709 tone map, coarse magnitude at the 90th percentile 0.01675 → 0.02627. The
    /// textbook derivation — the ratio of the two curves' slopes at middle grey — gives 2.29× and is
    /// WRONG for this purpose, because the gradients a frame actually contains come from every
    /// luminance level, not just mid grey.
    ///
    /// Approximate by construction: our own tone map stands in for the body's SDR JPEG rendering,
    /// which is what the photo feed really carries. Direction and order of magnitude are solid; the
    /// exact figure wants a hardware A/B. HLG stills sit between the two and are not separately
    /// measured — they currently take the same treatment as sRGB. [verify-on-HW]
    public static let displayReferredGradientScale = 1.57

    /// The gate multiplier for a feed rendered at `scale` relative to the calibration curve.
    /// Squared because the gate is compared against ``robertsSquared``, which is quadratic in the
    /// slope; both shells resolve it here so neither has to remember to square it.
    public static func gateScale(gradientScale: Double) -> Double {
        gradientScale * gradientScale
    }

    // MARK: - Reference implementation

    /// The operator: a squared Roberts cross over the 2×2 pixel quad anchored at `(x, y)`.
    ///
    /// This is `CIEdges`, reproduced rather than approximated, and every part of the transcription
    /// is measured — getting any of it wrong silently invalidates every calibrated constant above,
    /// because they all live in its squared domain.
    ///
    /// * It is SQUARED: a 0.2 step gives 0.08 and a 0.4 step 0.32, i.e. `d1² + d2²` over the two
    ///   diagonals — exactly `2·step²` for a vertical edge, and a ratio of 4 between those two
    ///   steps, which is what rules out a linear operator.
    /// * The taps are the quad anchored AT the destination pixel, `+x` and `+y`. Checked against
    ///   the wrong alternatives: ±0.5 corner taps bilinear-average and quarter the response, and a
    ///   central difference spreads the response over two pixels instead of one.
    /// * There is no tap-spacing normalisation. Android used to scale its spacing by the frame's
    ///   long side, so that the same optical blur read the same on a downscaled live feed and on a
    ///   4K clip. `CIEdges` is fixed at one pixel and so is ``reblurRadius``, so the shells are
    ///   fixed at one pixel too and a 4K clip reads finer detail than a live feed does.
    public static func robertsSquared(x: Int, y: Int, sample: (Int, Int) -> Double) -> Double {
        let a = sample(x, y)
        let b = sample(x + 1, y)
        let c = sample(x, y + 1)
        let d = sample(x + 1, y + 1)
        let d1 = d - a
        let d2 = c - b
        return d1 * d1 + d2 * d2
    }

    /// Blur-independent sharpness of one pixel: the fine operator over the coarse one.
    /// ``ratioCeiling`` when perfectly sharp, 1 when fully defocused, and — because both terms
    /// carry the same amplitude — independent of how contrasty the edge is.
    public static func sharpness(fine: Double, coarse: Double) -> Double {
        min(fine / max(coarse, 1e-9), ratioCeiling)
    }

    /// How much of a pixel counts as a real edge rather than sensor noise, on the coarse operator.
    public static func gateOpacity(coarse: Double, gate: Double) -> Double {
        clamped((coarse - gate * gateRampFloor) / max(gate * (1 - gateRampFloor), 1e-12))
    }

    /// Opacity of the painted stroke before the noise gate is applied to it.
    public static func strokeOpacity(sharpness: Double, threshold: Double) -> Double {
        clamped((sharpness - threshold) / antialiasWidth)
    }

    /// Opacity of the dark hairline under the stroke, likewise before the gate.
    public static func underOpacity(sharpness: Double, threshold: Double) -> Double {
        strokeOpacity(
            sharpness: sharpness, threshold: threshold - antialiasWidth * underRampOffset)
    }

    /// Both overlay channels for a whole frame.
    public struct Overlay: Sendable {
        /// Opacity of the painted stroke, after closing.
        public var stroke: [Double]
        /// Opacity of the dark hairline beneath it. NOT closed: morphology is two more passes in a
        /// graph rebuilt every frame, and a hairline drawn under the stroke gains almost nothing
        /// from being continuous. Halves the added per-frame cost.
        public var under: [Double]
    }

    /// The whole detector, on a normalised grey plane in top-down row order.
    ///
    /// The shells render exactly this. Kept as one function rather than a set of helpers precisely
    /// so a transcription can be checked against it end to end — `RunnerTests` renders it against
    /// the live Core Image graph and compares pixels.
    ///
    /// `gateScale` is ``gateScale(gradientScale:)`` for a display-referred feed and 1 for log.
    /// `closing` exists for the shells that cannot afford it in a single pass (see
    /// ``closingOffsets``), so their difference from iOS is expressible as one flag rather than a
    /// second implementation.
    public static func overlay(
        grey: [Double], width: Int, height: Int, sensitivity: Sensitivity,
        gateScale: Double = 1, closing: Bool = true
    ) -> Overlay {
        precondition(grey.count == width * height, "grey plane must be width × height")
        let gate = sensitivity.noiseGate * gateScale
        let threshold = sensitivity.ratioThreshold
        let inset = Int(edgeInset)

        func at(_ plane: [Double], _ x: Int, _ y: Int) -> Double {
            // Edge-clamped, matching the `clampedToExtent()` the Core Image path samples through.
            plane[min(max(y, 0), height - 1) * width + min(max(x, 0), width - 1)]
        }

        // Separable re-blur: horizontal into `rows`, then vertical into `blurred`.
        let taps = reblurWeights.count / 2
        var rows = [Double](repeating: 0, count: width * height)
        var blurred = rows
        for y in 0..<height {
            for x in 0..<width {
                var total = 0.0
                for (index, weight) in reblurWeights.enumerated() {
                    total += weight * at(grey, x + index - taps, y)
                }
                rows[y * width + x] = total
            }
        }
        for y in 0..<height {
            for x in 0..<width {
                var total = 0.0
                for (index, weight) in reblurWeights.enumerated() {
                    total += weight * at(rows, x, y + index - taps)
                }
                blurred[y * width + x] = total
            }
        }

        var stroke = [Double](repeating: 0, count: width * height)
        var under = stroke
        for y in inset..<max(inset, height - inset) {
            for x in inset..<max(inset, width - inset) {
                let fine = robertsSquared(x: x, y: y) { at(grey, $0, $1) }
                let coarse = robertsSquared(x: x, y: y) { at(blurred, $0, $1) }
                let ratio = sharpness(fine: fine, coarse: coarse)
                let gateValue = gateOpacity(coarse: coarse, gate: gate)
                stroke[y * width + x] =
                    strokeOpacity(sharpness: ratio, threshold: threshold) * gateValue
                under[y * width + x] =
                    underOpacity(sharpness: ratio, threshold: threshold) * gateValue
            }
        }
        guard closing, maskClosingRadius > 0 else { return Overlay(stroke: stroke, under: under) }

        // Dilate, then erode, over the measured five-point element. Both stages read the zero
        // border the window above already wrote, so the plane edges never enter the result.
        func morphology(_ plane: [Double], _ pick: (Double, Double) -> Double) -> [Double] {
            var output = plane
            for y in 0..<height {
                for x in 0..<width {
                    var value = plane[y * width + x]
                    for (dx, dy) in closingOffsets {
                        value = pick(value, at(plane, x + dx, y + dy))
                    }
                    output[y * width + x] = value
                }
            }
            return output
        }
        return Overlay(stroke: morphology(morphology(stroke, max), min), under: under)
    }

    private static func clamped(_ value: Double) -> Double { min(max(value, 0), 1) }
}

/// The exposure zone a pixel falls in for the zebra overlay. Highlight (clipping) takes priority
/// over the midtone reference band.
public enum ZebraZone: Equatable, Sendable {
    case none
    case highlight
    case midtone
}

/// Native-luma thresholds for the two zebra bands. Highlight stripes everything at or above
/// `highlightLuma`; midtone stripes a narrow band around `midtoneLuma`. Defaults match the
/// prototype (≈95 signal IRE clip, ≈55 signal IRE midtone, ±5 code values).
public struct ZebraThresholds: Equatable, Sendable {
    public var highlightLuma: Double
    public var midtoneLuma: Double
    public var midtoneTolerance: Double

    public init(highlightLuma: Double, midtoneLuma: Double, midtoneTolerance: Double) {
        self.highlightLuma = highlightLuma
        self.midtoneLuma = midtoneLuma
        self.midtoneTolerance = midtoneTolerance
    }

    public static let `default` = ZebraThresholds(
        highlightLuma: 242, midtoneLuma: 140, midtoneTolerance: 5)
}

/// Zebra exposure stripes. Decides which zone a pixel's luma is in, and whether the moving stripe
/// pattern is "on" at a given screen position — a checkerboard for the highlight (clip) zone and
/// diagonal stripes for the midtone reference band, ported from the prototype.
public enum Zebra {
    /// How strongly the stripe colour replaces the image, per zone (`stripe·f + image·(1−f)`).
    public static let highlightBlend = 0.75
    public static let midtoneBlend = 0.55

    /// Which zebra zone a native luma falls in; highlight wins ties with midtone.
    public static func zone(luma: Double, thresholds: ZebraThresholds = .default) -> ZebraZone {
        if luma >= thresholds.highlightLuma { return .highlight }
        if abs(luma - thresholds.midtoneLuma) <= thresholds.midtoneTolerance { return .midtone }
        return .none
    }

    /// Whether the stripe pattern is opaque at screen pixel `(x, y)` for the given zone:
    /// `(x+y) mod 14 < 7` checkerboard for highlights, `(x−y+140) mod 12 < 6` diagonals for midtones.
    public static func isStripeOn(zone: ZebraZone, x: Int, y: Int) -> Bool {
        switch zone {
        case .none: return false
        case .highlight: return floorMod(x + y, 14) < 7
        case .midtone: return floorMod(x - y + 140, 12) < 6
        }
    }

    /// Euclidean modulo so the diagonal phase stays stable for negative `x − y` (frame edges).
    private static func floorMod(_ value: Int, _ modulus: Int) -> Int {
        ((value % modulus) + modulus) % modulus
    }
}
