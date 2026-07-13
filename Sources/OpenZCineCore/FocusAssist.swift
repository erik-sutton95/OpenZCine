import Foundation

/// Focus-peaking edge detection: a pixel is "in focus" where the local luma gradient is steep.
/// Ported from the prototype's single-pass kernel — the L1 (taxicab) magnitude of the luma
/// difference to the right and below the pixel, thresholded. This is the reference/CPU form; the
/// shell may render the same idea on the GPU, but the threshold and metric are defined here.
public enum Peaking {
    /// Default edge threshold (≈13% of full scale), matching the prototype's `mag > 34`.
    public static let defaultThreshold = 34.0

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
    }

    /// L1 magnitude of the luma gradient: `|center − right| + |center − below|`.
    public static func gradientMagnitude(center: Double, right: Double, below: Double) -> Double {
        abs(center - right) + abs(center - below)
    }

    /// Whether a pixel is an in-focus edge (gradient strictly above the threshold).
    public static func isEdge(
        center: Double, right: Double, below: Double, threshold: Double = defaultThreshold
    ) -> Bool {
        gradientMagnitude(center: center, right: right, below: below) > threshold
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
