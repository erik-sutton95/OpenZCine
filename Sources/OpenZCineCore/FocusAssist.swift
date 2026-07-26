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
/// The fix is to measure the blur radius instead, which is what the gradient RATIO at two scales
/// gives: sample the gradient at spacing `h` and at `2h` and divide. Amplitude cancels exactly —
/// the result depends only on `sigma`, running from ``wideTapSharpRatio`` for a perfectly sharp
/// edge down to 1 for a fully defocused one. One threshold then holds from a dim texture to a
/// blown highlight. (Classical edge-based defocus estimation, cf. Zhuo & Sim, *Defocus map
/// estimation from a single image*, Pattern Recognition 2011, which recovers `sigma` from the
/// same ratio against a re-blurred copy.)
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
/// This is the reference form. The shells render the same metric on the GPU — Core Image on iOS,
/// GLES/Vulkan/AGSL on Android — but the metric and its thresholds are defined here.
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
    /// (and noisier) edges count. The concrete threshold the renderer uses is the shell's concern;
    /// this is the operator-facing level the UI sets and the config persists. Raw values match the
    /// settings segmented control ("Low" / "Med" / "High").
    public enum Sensitivity: String, CaseIterable, Codable, Sendable, Identifiable {
        case low = "Low"
        case medium = "Med"
        case high = "High"

        public var id: String { rawValue }

        /// How sharp an edge must read before it is painted, as a two-scale gradient ratio
        /// (see ``Peaking`` for why a ratio and not a magnitude). Higher = stricter.
        ///
        /// The two renderers sample the coarse scale differently — the GPU shells take a second
        /// central difference at twice the spacing (8 taps, no extra pass), Core Image re-blurs
        /// and runs its own 3×3 operator — so the same optical blur lands on a different number
        /// and the tables cannot be shared. They are kept side by side deliberately: the
        /// operator-facing step is what has to match, not the constant.
        ///
        /// Ratios run from `wideTapSharpRatio` (perfectly sharp) down to 1 (fully defocused).
        public var wideTapRatioThreshold: Double {
            switch self {
            case .low: 1.45
            case .medium: 1.35
            case .high: 1.25
            }
        }

        /// Core Image equivalent of ``wideTapRatioThreshold``. Core Image reaches the coarse
        /// scale by re-blurring (``reblurRadius``) and re-running its own 3×3 operator, which
        /// spreads the same optical blur over a wider range than the wide-tap kernel does.
        /// Measured against the same synthetic edge set: in-focus detail lands at 2.49…2.90,
        /// defocused background at 1.08…1.33, so these sit inside that gap.
        /// Shifted in step with ``reblurNoiseGate`` — a sensitivity step moves BOTH, so shifting
        /// only the gate would have handed Med the old Low's floor with Med's looser ratio bar
        /// and a 2.6:1 discrimination instead of the 7.4:1 the old Low actually delivered. Med
        /// now reproduces the old Low exactly.
        public var reblurRatioThreshold: Double {
            switch self {
            case .low: 2.30
            case .medium: 2.10
            case .high: 1.90
            }
        }

        /// ``noiseGate`` for the Core Image path. Roughly 40× smaller than the wide-tap gate
        /// purely because `CIEdges` normalises differently — measured, not derived: the weakest
        /// in-focus edge reaches 0.00048 while heavy sensor noise tops out near 0.000035.
        /// Re-anchored and widened, and the two changes are inseparable from
        /// ``maskClosingRadius`` — read that first.
        ///
        /// Med is 0.00058 rather than the old 0.00020 and yet paints exactly as much: closing
        /// fattens what survives, so the gate has to tighten by the same amount to land back on
        /// the old density. Measured, that trade is free — Med keeps its ink and its
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
        public var reblurNoiseGate: Double {
            switch self {
            case .low: 0.00522
            case .medium: 0.00174
            case .high: 0.00058
            }
        }

        /// Minimum coarse-gradient energy before a pixel is considered at all, in code value
        /// (0…1) per pixel. Sensor noise is not lens-blurred, so it always reads as perfectly
        /// sharp — the ratio cannot reject it and this gate is what keeps shadows from sparkling.
        ///
        /// It moves far less between steps than the ratio does, and deliberately so: this is a
        /// noise floor, a property of the sensor, while the ratio is the actual focus strictness.
        /// Driving it hard with the sensitivity blinds the low settings to low-contrast subjects —
        /// which is the "misses things clearly in the focus plane" half of the original complaint.
        /// The floor stays under the coarse gradient of a 5%-contrast in-focus edge (~0.012).
        public var noiseGate: Double {
            switch self {
            case .low: 0.011
            case .medium: 0.008
            case .high: 0.005
            }
        }
    }

    /// Ratio a perfectly sharp edge produces under the wide-tap kernel: the coarse difference
    /// spans twice the distance for the same step, so it is exactly 2 before noise.
    public static let wideTapSharpRatio = 2.0

    /// Blur radius Core Image re-blurs by to reach the coarse scale.
    public static let reblurRadius = 1.0

    /// Core Image reaches the ratio with a divide blend, which saturates at 1. Scaling the
    /// numerator down by this first keeps the quotient in range for ratios up to 4 — without it
    /// every sharp edge clamps to the same value and the ramp has nothing left to work with.
    public static let reblurRatioScale = 0.25

    /// Half-width of the antialiasing ramp on the peaking decision, as a fraction of the noise
    /// gate. Deliberately narrow — peaking reads as a drawn line, not a glow.
    public static let edgeSoftness = 0.35

    /// Border (in source pixels) where peaking never fires; the kernels would sample outside.
    public static let edgeInset = 6.0

    /// Radius, in source pixels, of the morphological CLOSING applied to the finished overlay.
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

    /// Tap spacing is normalised to this long side so the same optical blur reads the same on a
    /// downscaled live feed and on a 4K clip.
    public static let referenceLongSide = 1000.0

    /// How much larger gradients read on a DISPLAY-REFERRED feed than on the log feed the gates were
    /// calibrated against — the reason peaking behaves differently in photography mode.
    ///
    /// The ratio is transfer-curve invariant, as documented above, but the noise ``Sensitivity``
    /// gates are absolute magnitudes, and a display-referred preview spends far more code value per
    /// stop through the midtones than a log curve does. Same scene, same optical blur, larger
    /// numbers — so a gate calibrated on log sits effectively lower on an SDR photo feed, and the
    /// operator's chosen sensitivity step silently means something stricter in one mode than the
    /// other. Multiply the gate by this (SQUARED where the detector works in a squared domain, as
    /// Core Image's does) to make a step mean the same thing in both.
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

    /// Central-difference gradient magnitude across a horizontal and a vertical pair, normalised
    /// to a per-pixel slope so the fine and coarse scales are directly comparable.
    /// `spacing` is the tap distance in pixels (1 for the fine scale, 2 for the coarse one).
    public static func gradientMagnitude(
        left: Double, right: Double, up: Double, down: Double, spacing: Double
    ) -> Double {
        let dx = right - left
        let dy = down - up
        return (dx * dx + dy * dy).squareRoot() * 0.5 / max(spacing, 1)
    }

    /// Blur-independent sharpness of one pixel: the fine gradient over the coarse one.
    /// ``wideTapSharpRatio`` when perfectly sharp, 1 when fully defocused, and — because both
    /// terms carry the same amplitude — independent of how contrasty the edge is.
    /// Returns 1 (defocused) where there is no measurable edge at all.
    public static func sharpnessRatio(fine: Double, coarse: Double) -> Double {
        guard coarse > 0 else { return 1 }
        return min(wideTapSharpRatio, fine / coarse)
    }

    /// Whether a pixel should be painted: sharp enough AND carrying a real edge rather than noise.
    public static func isEdge(
        fine: Double, coarse: Double, sensitivity: Sensitivity = .medium
    ) -> Bool {
        guard coarse >= sensitivity.noiseGate else { return false }
        return sharpnessRatio(fine: fine, coarse: coarse) >= sensitivity.wideTapRatioThreshold
    }
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
