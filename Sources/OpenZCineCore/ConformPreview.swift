import Foundation

/// Slow-motion conform preview: play a high-frame-rate clip at the rate it will be conformed to in
/// the edit, so motion, performance, stabilisation and focus can be judged before the setup changes.
///
/// Real-time playback confirms a clip was captured; it does not show how 60 or 120 fps will FEEL
/// once conformed. The rule is one line — the preview speed is the target timeline rate over the
/// source capture rate, so 60 → 24 plays at 40% — and everything below exists to keep that line
/// honest.
///
/// ## Three values, kept apart
///
/// The failure mode this design is built against is collapsing three different numbers into one:
///
/// 1. the **capture rate** the sensor actually ran at,
/// 2. the **target rate** the operator is conforming to,
/// 3. the **playback clock** and the duration it produces.
///
/// They diverge exactly where it matters. Footage recorded with an in-camera slow-motion playback
/// rate is already conformed — its container plays at 24 while the sensor ran at 120 — so treating
/// the container's nominal rate as the capture rate would conform it a second time and show 40% of
/// 40%. Hence ``Source/captureRate`` is a separate input the shell must resolve from the most
/// authoritative metadata it has, and ``Source/isAlreadyConformed`` exists to say "do not touch
/// this one" rather than guessing.
///
/// ## Refusing rather than guessing
///
/// Where the source cannot be trusted — variable frame rate, or metadata that never arrived —
/// ``availability(for:)`` returns a refusal instead of a plausible number. A conform preview that
/// is quietly wrong is worse than one that is unavailable: the operator would be judging a
/// performance at a speed the edit will never reproduce, and nothing on screen would say so.
///
/// This is a PREVIEW TRANSFORM. It never modifies the source clip and never implies a conformed
/// export exists.
public enum ConformPreview {

    /// Timeline rates offered as conform targets: the broadcast and cinema standards an operator
    /// would actually cut to. Ordered as presented.
    public static let targetRates: [Double] = [23.976, 24, 25, 29.97, 30]

    /// Frame rates within this many fps are the same rate for LABELLING — enough to absorb the
    /// rounding a container's rational rate arrives with, small enough that 23.976 still prints
    /// differently from 24.
    public static let rateTolerance: Double = 0.01

    /// A target must be at least this much slower, RELATIVELY, to count as a conform.
    ///
    /// An absolute tolerance cannot do this job. The 1000/1001 pulldown pairs sit 0.024–0.03 fps
    /// apart (23.976 against 24, 29.97 against 30) and are the same shooting rate, not a slow-motion
    /// conform — but 24 against 25 is only 1 fps apart and IS one. A 1% relative floor separates
    /// them: the pulldown pairs differ by 0.1%, while 24/25 differs by 4%.
    public static let conformFloor: Double = 0.99

    /// What the shell managed to learn about the clip. Every field is something the player can only
    /// answer after the asset loads, which is why this is an input rather than something derived
    /// here.
    public struct Source: Equatable, Sendable {
        /// The rate the SENSOR ran at, from the most authoritative metadata available — not the
        /// container's nominal playback rate unless that is genuinely all there is. `nil` when
        /// nothing trustworthy arrived.
        public var captureRate: Double?
        /// True when the frame rate varies across the clip, so no single conform factor is correct.
        public var isVariableFrameRate: Bool
        /// True when the camera already applied a slow-motion playback rate, i.e. the file plays
        /// conformed. Previewing a conform on top of that would apply the factor twice.
        public var isAlreadyConformed: Bool

        public init(
            captureRate: Double? = nil,
            isVariableFrameRate: Bool = false,
            isAlreadyConformed: Bool = false
        ) {
            self.captureRate = captureRate
            self.isVariableFrameRate = isVariableFrameRate
            self.isAlreadyConformed = isAlreadyConformed
        }
    }

    /// Whether a conform preview can be offered, and if not, why — the reason is shown to the
    /// operator rather than the control simply being missing.
    public enum Availability: Equatable, Sendable {
        /// Offerable, with the target rates that are strictly slower than the capture rate.
        case available([Double])
        /// No trustworthy capture rate, so any factor would be a guess.
        case unknownRate
        /// The rate varies across the clip; one factor cannot be right for all of it.
        case variableRate
        /// The camera already conformed this clip; previewing again would double the factor.
        case alreadyConformed
        /// Nothing to conform to — the clip is not faster than the slowest target offered.
        case notHighFrameRate

        /// The offered targets, or empty when unavailable.
        public var targets: [Double] {
            if case .available(let rates) = self { return rates }
            return []
        }

        public var isAvailable: Bool { !targets.isEmpty }

        /// Operator-facing reason the control is inert. `nil` when it is available.
        public var unavailableReason: String? {
            switch self {
            case .available: nil
            case .unknownRate: "Frame rate unavailable for this clip"
            case .variableRate: "Variable frame rate — conform preview unavailable"
            case .alreadyConformed: "Already conformed in camera"
            case .notHighFrameRate: "Not a high-frame-rate clip"
            }
        }
    }

    /// Whether a conform preview can be offered for `source`, and which targets.
    ///
    /// The refusals are ordered by how badly each would mislead: an unusable rate first, then a
    /// rate that cannot be a single number, then a clip that is already conformed.
    public static func availability(for source: Source) -> Availability {
        guard let rate = source.captureRate, rate.isFinite, rate > 0 else { return .unknownRate }
        if source.isVariableFrameRate { return .variableRate }
        if source.isAlreadyConformed { return .alreadyConformed }
        // Meaningfully slower, so a clip shot at 24 is offered neither "conform to 24" (a no-op)
        // nor "conform to 23.976" (pulldown, not slow motion) — see `conformFloor`.
        let targets = targetRates.filter { $0 < rate * conformFloor }
        return targets.isEmpty ? .notHighFrameRate : .available(targets)
    }

    /// Playback speed for a conform: the target timeline rate over the source capture rate.
    /// 60 → 24 is 0.4. Returns 1 for a degenerate source rather than a division by zero.
    public static func speed(captureRate: Double, targetRate: Double) -> Double {
        guard captureRate.isFinite, captureRate > 0, targetRate.isFinite, targetRate > 0 else {
            return 1
        }
        return targetRate / captureRate
    }

    /// How long the clip runs once conformed: real time divided by the speed. A 6 s clip at 40%
    /// runs 15 s.
    public static func conformedDuration(sourceSeconds: Double, speed: Double) -> Double {
        guard sourceSeconds.isFinite, sourceSeconds >= 0, speed.isFinite, speed > 0 else {
            return 0
        }
        return sourceSeconds / speed
    }

    /// The source frame a conformed playhead is sitting on. Seeking stays anchored to SOURCE frame
    /// indices — the conform is a clock change, not a re-timing of the media, so scrubbing must
    /// still land on real frames.
    public static func sourceFrameIndex(
        conformedSeconds: Double, captureRate: Double, speed: Double
    ) -> Int {
        guard conformedSeconds.isFinite, conformedSeconds >= 0, captureRate > 0, speed > 0 else {
            return 0
        }
        return Int((conformedSeconds * speed * captureRate).rounded(.down))
    }

    /// A frame rate as an operator writes it: whole rates plain, pulldown rates to two places.
    /// 24 → "24", 23.976 → "23.98", 29.97 → "29.97", 59.94 → "59.94".
    public static func rateLabel(_ rate: Double) -> String {
        guard rate.isFinite, rate > 0 else { return "—" }
        let whole = rate.rounded()
        if abs(rate - whole) < rateTolerance { return String(Int(whole)) }
        return String(format: "%.2f", rate)
    }

    /// The conform stated in full, so the operator can never be unsure what they are watching:
    /// `60 → 24 fps · 40%`.
    ///
    /// The percentage is deliberately alongside the rates rather than instead of them. The rates
    /// say what the edit will do; the percentage says what the eye is seeing, and an operator
    /// judging a performance needs both.
    public static func label(captureRate: Double, targetRate: Double) -> String {
        let percent = speed(captureRate: captureRate, targetRate: targetRate) * 100
        // Integer only when it genuinely is one: 40% prints "40", 20.83% prints "20.8". A 0.5
        // threshold here would be met by every value, which is the bug this replaced.
        let formatted =
            abs(percent - percent.rounded()) < 0.05
            ? String(Int(percent.rounded())) : String(format: "%.1f", percent)
        return "\(rateLabel(captureRate)) → \(rateLabel(targetRate)) fps · \(formatted)%"
    }

    /// Audio during a conform preview.
    ///
    /// Muted, and labelled as muted. Playing a track at 40% without pitch correction is misleading
    /// in a way that is easy to miss — it still sounds like audio, just wrong — and pitch-corrected
    /// audio is a bigger piece of work that wants the playback clock settled first. Silence the
    /// operator has been told about is the honest first version.
    public static let audioLabel = "Audio muted during conform preview"
}
