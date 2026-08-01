import Foundation

/// Steps the relay's video bitrate against observed viewer backpressure.
///
/// The broadcaster serves every viewer from ONE encode, so the stream must fit the slowest link
/// that is supposed to keep up. Saturation is the signal the send path already produces: a tick
/// where no viewer could accept a frame (the encode was skipped) means the stream is outrunning
/// the network, and quality is worth trading for delivery. Recovery is deliberately slower than
/// degradation — a set network that just choked once will choke again, and oscillating bitrate
/// reads worse on a monitor than a steady, slightly softer picture.
public struct RelayBitrateAdaptation: Equatable, Sendable {
    /// Bits per second, best first. The relay carries LOG footage that every watcher grades
    /// through a LUT — quantization noise invisible in the flat image gets contrast-stretched
    /// into blotching, so the ladder is deliberately generous for the content, not the pixel
    /// count. The floor keeps a usable picture on a genuinely bad channel rather than none.
    public static let ladder = [10_000_000, 7_000_000, 4_500_000, 3_000_000]

    /// Fraction of saturated ticks in a window that forces a step DOWN.
    public static let stepDownSaturation = 0.3
    /// Saturation must stay below this for `stepUpAfterCleanSeconds` before a step UP.
    public static let stepUpSaturation = 0.05
    /// Window over which saturation is judged.
    public static let windowSeconds: TimeInterval = 5
    /// Clean time required before recovering one rung.
    public static let stepUpAfterCleanSeconds: TimeInterval = 30

    /// Index into `ladder` for the current rate.
    public private(set) var rungIndex = 0
    public var bitsPerSecond: Int { Self.ladder[rungIndex] }

    private var windowStartedAt: TimeInterval
    private var ticksInWindow = 0
    private var saturatedTicksInWindow = 0
    private var previousTickSaturated = false
    private var cleanSince: TimeInterval

    public init(now: TimeInterval = 0) {
        windowStartedAt = now
        cleanSince = now
    }

    /// Records one broadcast tick. Returns the new bitrate when the rung changed, else nil.
    ///
    /// A single saturated tick is PACING, not congestion: with a two-frame in-flight cap at
    /// stream rate, every viewer is momentarily "full" all the time. Only consecutive
    /// saturated ticks — the stream outrunning the drain for real — count toward stepping
    /// down; counting the blips is what walked multi-watcher sessions to the floor and kept
    /// them there.
    public mutating func recordTick(saturated: Bool, now: TimeInterval) -> Int? {
        ticksInWindow += 1
        if saturated && previousTickSaturated { saturatedTicksInWindow += 1 }
        previousTickSaturated = saturated
        guard now - windowStartedAt >= Self.windowSeconds, ticksInWindow > 0 else { return nil }

        let saturation = Double(saturatedTicksInWindow) / Double(ticksInWindow)
        ticksInWindow = 0
        saturatedTicksInWindow = 0
        windowStartedAt = now

        if saturation > Self.stepDownSaturation {
            cleanSince = now
            if rungIndex < Self.ladder.count - 1 {
                rungIndex += 1
                return bitsPerSecond
            }
            return nil
        }
        if saturation > Self.stepUpSaturation {
            // Not bad enough to drop, not clean enough to climb — the clean clock restarts.
            cleanSince = now
            return nil
        }
        if rungIndex > 0, now - cleanSince >= Self.stepUpAfterCleanSeconds {
            rungIndex -= 1
            cleanSince = now
            return bitsPerSecond
        }
        return nil
    }
}
