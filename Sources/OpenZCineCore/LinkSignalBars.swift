import Foundation

/// Maps the 0–100 `CameraLinkHealthScorer` score onto 0–4 signal bars with hysteresis, so the
/// top-bar signal indicator reads steadily instead of flickering when the score hovers at a band
/// boundary.
///
/// Raw bands are health quartiles (matching the connection panel's meter): 1–25 → 1 bar,
/// 26–50 → 2, 51–75 → 3, 76–100 → 4; score 0 → 0 bars. Changing bands requires the score to
/// clear the target band's floor by the hysteresis margin (going up) or drop that margin below
/// the current band's floor (going down). Zero is immediate in both directions — losing or
/// gaining the link should never be damped.
///
/// Pure value type — fully testable without a live camera.
public struct LinkSignalBars: Sendable {
    /// Currently displayed bar count (0–4).
    public private(set) var bars: Int = 0

    private let margin: Int

    /// - Parameter hysteresisMargin: Score points a band boundary must be cleared by before the
    ///   displayed bar count changes (default 6).
    public init(hysteresisMargin: Int = 6) {
        margin = max(0, hysteresisMargin)
    }

    /// Lowest score that maps to `bars` without hysteresis.
    private static func floorScore(of bars: Int) -> Int { 25 * (bars - 1) + 1 }

    /// Raw quartile band for a score, ignoring hysteresis.
    private static func rawBars(score: Int) -> Int {
        guard score > 0 else { return 0 }
        return min(4, max(1, Int((Double(score) / 25.0).rounded(.up))))
    }

    /// Feeds the latest link-health score and returns the (possibly damped) bar count.
    public mutating func update(score: Int) -> Int {
        let raw = Self.rawBars(score: score)
        switch (bars, raw) {
        case (let current, let raw) where raw == current:
            break
        case (_, 0), (0, _):
            // Link lost or first score after a reset — reflect it immediately.
            bars = raw
        case (let current, let raw) where raw > current:
            if score >= Self.floorScore(of: raw) + margin { bars = raw }
        default:
            if score < Self.floorScore(of: bars) - margin { bars = raw }
        }
        return bars
    }
}
