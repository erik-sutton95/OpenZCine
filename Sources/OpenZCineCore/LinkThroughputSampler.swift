import Foundation

/// How fast the camera link actually carries bytes, smoothed across frames.
///
/// RTT is deliberately sampled from small commands only: a frame fetch carries the whole JPEG, so
/// its duration measures payload transfer rather than command latency, and feeding it into the
/// poll pacing made the stride react to picture size as if the link had slowed.
///
/// That same measurement is the RIGHT one for a different question, and nothing was asking it. On
/// 2.4 GHz the binding constraint is not latency — it is airtime. A link can answer a keep-alive in
/// 30 ms and still take a second and a half to move one 100 KB frame, and the operator sees only
/// that the picture is slow. Bytes ÷ seconds over the frame fetch is that number, free, once per
/// frame.
///
/// EWMA at the same α as the round-trip average, and for the same reason: one frame arriving during
/// a microwave burst should not redraw the operator's idea of their link.
public struct LinkThroughputSampler: Sendable, Equatable {
    /// Weight given to each new sample. Matches the command round-trip average — a few frames to
    /// track a genuine change, enough inertia to ignore one bad one.
    public static let smoothingFactor = 0.25

    /// Samples below this are discarded as measurement noise rather than link truth: a frame
    /// served from a buffer that was already full can complete in microseconds and would otherwise
    /// report an implausible megabit figure.
    public static let minimumSampleSeconds = 0.002

    public private(set) var megabitsPerSecond: Double?

    public init() {}

    /// Folds one completed transfer in. Samples with no bytes, no time, or an implausibly short
    /// duration are ignored — they describe the buffer, not the radio.
    public mutating func record(bytes: Int, seconds: Double) {
        guard bytes > 0, seconds >= Self.minimumSampleSeconds else { return }
        let sample = (Double(bytes) * 8 / 1_000_000) / seconds
        guard sample.isFinite, sample > 0 else { return }
        if let previous = megabitsPerSecond {
            megabitsPerSecond = previous + Self.smoothingFactor * (sample - previous)
        } else {
            megabitsPerSecond = sample
        }
    }

    /// A session ends and the next link is a different link.
    public mutating func reset() {
        megabitsPerSecond = nil
    }

    /// Operator-facing rate, e.g. `"6.4 Mbps"`. `nil` until a frame has been measured.
    public var formatted: String? {
        guard let megabitsPerSecond else { return nil }
        if megabitsPerSecond >= 10 {
            return "\(Int(megabitsPerSecond.rounded())) Mbps"
        }
        return String(format: "%.1f Mbps", megabitsPerSecond)
    }

    /// Roughly how many frames of `bytes` this link can carry per second, for saying what a
    /// preset would cost before the operator picks it. `nil` until measured.
    ///
    /// Deliberately throughput-only: it answers "can the wire carry this", not "will the body
    /// send it that fast". A camera with its own frame-rate ceiling can come in under this, and
    /// the honest reading of a gap between the two is that something OTHER than the link is the
    /// limit — which is worth knowing rather than hiding.
    public func sustainableFramesPerSecond(atFrameBytes bytes: Int) -> Double? {
        guard let megabitsPerSecond, bytes > 0 else { return nil }
        let megabitsPerFrame = Double(bytes) * 8 / 1_000_000
        guard megabitsPerFrame > 0 else { return nil }
        return megabitsPerSecond / megabitsPerFrame
    }
}
