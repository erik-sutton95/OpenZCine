/// White-balance Kelvin (colour-temperature) ladder for Nikon cinema / Z bodies.
///
/// Source of truth:
/// - **Range** — Nikon ZR Reference Guide, White balance → K [Choose color temperature]:
///   approx. **2500–10000 K**.
/// - **Dial steps** — ~10 mired increments, the values the body shows when rotating
///   the colour-temperature dial (e.g. **5560 K**, not round **5600 K**). Round
///   values like 5600 only appear via digit entry / fine-tune, so they are not on
///   the drum.
///
/// Colour temperature is a continuous UINT16 Kelvin on the wire; the drum mirrors
/// the body dial so operators land on the same numbers they see on-camera.
public enum WhiteBalanceKelvinPolicy: Sendable {
    /// Inclusive lower bound (Kelvin).
    public static let minimumKelvin: Int = 2_500

    /// Inclusive upper bound (Kelvin).
    public static let maximumKelvin: Int = 10_000

    /// Default Kelvin when the body has no live colour-temperature readout.
    /// Nikon's dial step nearest "daylight" (not the round 5600 used in prose).
    public static let defaultKelvin: Int = 5_560

    /// Fine-adjust step (Kelvin) beside a drum value — matches the body's
    /// digit-entry / fine-tune resolution of 10 K.
    public static let fineStepKelvin: Int = 10

    /// Body dial colour-temperature steps (Kelvin), ~10 mired apart.
    ///
    /// Mired-native series (5560 / 5880 / 6250 …) rather than the interleaved
    /// "round" companions (5600 / 5900 / 6300 …) that only show under fine adjust.
    public static let kelvinSteps: [Int] = [
        2_500, 2_560, 2_630, 2_700, 2_780, 2_860, 2_940, 3_030, 3_130, 3_230,
        3_330, 3_450, 3_570, 3_700, 3_850, 4_000, 4_170, 4_350, 4_550, 4_760,
        5_000, 5_260, 5_560, 5_880, 6_250, 6_670, 7_140, 7_690, 8_330, 9_090,
        10_000,
    ]

    /// Drum labels (`"5560K"`).
    public static let kelvinOptions: [String] = kelvinSteps.map(label(for:))

    /// Default drum selection label.
    public static let defaultLabel: String = label(for: defaultKelvin)

    /// Format a Kelvin integer as a picker / readout label.
    public static func label(for kelvin: Int) -> String { "\(kelvin)K" }

    /// Parse `"5560K"` / `"5560"` → Kelvin, or nil when not a temperature label.
    public static func kelvin(from label: String) -> Int? {
        let trimmed = label.trimmingCharacters(in: .whitespacesAndNewlines)
        let numeric =
            trimmed.hasSuffix("K") || trimmed.hasSuffix("k")
            ? String(trimmed.dropLast())
            : trimmed
        guard let value = Int(numeric), isInDocumentedRange(value) else { return nil }
        return value
    }

    /// Whether `label` is a Kelvin readout in the documented body range.
    public static func isKelvinLabel(_ label: String) -> Bool {
        kelvin(from: label) != nil
    }

    /// Whether a raw Kelvin integer sits in Nikon's documented 2500–10000 range.
    public static func isInDocumentedRange(_ kelvin: Int) -> Bool {
        (minimumKelvin...maximumKelvin).contains(kelvin)
    }

    /// Nearest official dial step to `kelvin` (clamped into range).
    public static func nearestStep(to kelvin: Int) -> Int {
        let clamped = min(max(kelvin, minimumKelvin), maximumKelvin)
        return kelvinSteps.min(by: { abs($0 - clamped) < abs($1 - clamped) }) ?? defaultKelvin
    }

    /// Nudge a Kelvin label by `delta` Kelvin (typically ±``fineStepKelvin``),
    /// clamped to the documented 2500–10000 range. Returns nil when `label` is
    /// not a Kelvin readout.
    public static func fineAdjust(from label: String, delta: Int) -> String? {
        guard let current = kelvin(from: label) else { return nil }
        let next = min(max(current + delta, minimumKelvin), maximumKelvin)
        return self.label(for: next)
    }

    /// Whether `delta` can still move `label` within the documented range.
    public static func canFineAdjust(from label: String, delta: Int) -> Bool {
        guard let current = kelvin(from: label) else { return false }
        let next = current + delta
        return isInDocumentedRange(next) && next != current
    }

    /// Drum options, optionally inserting a live off-ladder Kelvin so the wheel
    /// can centre on the body's current temperature without snapping away
    /// (e.g. a fine-tuned 5600 K still appears while selected).
    public static func options(including liveLabel: String? = nil) -> [String] {
        guard let liveLabel,
            let live = kelvin(from: liveLabel),
            !kelvinSteps.contains(live)
        else {
            return kelvinOptions
        }
        var steps = kelvinSteps
        steps.append(live)
        steps.sort()
        return steps.map(label(for:))
    }

    /// Prefer a denser camera-advertised Kelvin enum when it is richer than the
    /// documented dial ladder; otherwise use the body dial steps (sparse demo /
    /// fake enums must not shrink the drum).
    public static func options(cameraAdvertised: [String], including liveLabel: String? = nil)
        -> [String]
    {
        let fromCamera =
            cameraAdvertised
            .compactMap(kelvin(from:))
            .filter { isInDocumentedRange($0) }
        let uniqueCamera = Array(Set(fromCamera)).sorted()
        let baseSteps =
            uniqueCamera.count > kelvinSteps.count
            ? uniqueCamera
            : kelvinSteps
        guard let liveLabel,
            let live = kelvin(from: liveLabel),
            !baseSteps.contains(live)
        else {
            return baseSteps.map(label(for:))
        }
        return (baseSteps + [live]).sorted().map(label(for:))
    }
}
