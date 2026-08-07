import Foundation
import Testing

@testable import OpenZCineCore

@Test func aSingleTransferIsReportedAsItsOwnRate() {
    var sampler = LinkThroughputSampler()
    #expect(sampler.megabitsPerSecond == nil)

    // 100 KB in 0.1 s = 1 MB/s = 8 Mbps.
    sampler.record(bytes: 100_000, seconds: 0.1)

    #expect(sampler.megabitsPerSecond == 8)
}

/// The smoothing is the point: one frame arriving during a burst of interference must not redraw
/// the operator's idea of their link.
@Test func oneBadFrameMovesTheAverageButDoesNotBecomeIt() {
    var sampler = LinkThroughputSampler()
    for _ in 0..<20 { sampler.record(bytes: 100_000, seconds: 0.1) }
    #expect(sampler.megabitsPerSecond == 8)

    // A frame that took ten times as long.
    sampler.record(bytes: 100_000, seconds: 1.0)

    let smoothed = try! #require(sampler.megabitsPerSecond)
    #expect(smoothed < 8)
    #expect(smoothed > 6)  // nowhere near the 0.8 Mbps the bad frame alone would claim
}

/// A sustained change IS a link change, and the average has to follow it rather than average it
/// away — that is the difference between smoothing and ignoring.
@Test func aSustainedDropIsTrackedWithinAFewFrames() {
    var sampler = LinkThroughputSampler()
    for _ in 0..<20 { sampler.record(bytes: 100_000, seconds: 0.1) }
    for _ in 0..<20 { sampler.record(bytes: 100_000, seconds: 1.0) }

    let settled = try! #require(sampler.megabitsPerSecond)
    #expect(abs(settled - 0.8) < 0.1)
}

/// A frame served from an already-full buffer completes in microseconds and describes the buffer,
/// not the radio.
@Test func implausiblyFastOrEmptySamplesAreNotLinkTruth() {
    var sampler = LinkThroughputSampler()
    sampler.record(bytes: 100_000, seconds: 0.000_001)
    sampler.record(bytes: 0, seconds: 0.1)
    sampler.record(bytes: 100_000, seconds: 0)
    sampler.record(bytes: -1, seconds: 0.1)

    #expect(sampler.megabitsPerSecond == nil)
}

@Test func aResetForgetsTheOldLinkEntirely() {
    var sampler = LinkThroughputSampler()
    sampler.record(bytes: 100_000, seconds: 0.1)
    sampler.reset()

    #expect(sampler.megabitsPerSecond == nil)
    #expect(sampler.formatted == nil)
}

/// The readout keeps a decimal where a decimal carries information and drops it where it does not:
/// the difference between 2.4 and 2.9 Mbps is the difference between two presets, the difference
/// between 47 and 48 is noise.
@Test func theRateReadsAtThePrecisionThatMatters() {
    var slow = LinkThroughputSampler()
    slow.record(bytes: 100_000, seconds: 0.32)
    #expect(slow.formatted == "2.5 Mbps")

    var fast = LinkThroughputSampler()
    fast.record(bytes: 1_000_000, seconds: 0.17)
    #expect(fast.formatted == "47 Mbps")
}

/// What the number is FOR: turning a link measurement into the frame rate a preset can expect.
@Test func aMeasuredLinkAnswersHowManyFramesItCanCarry() {
    var sampler = LinkThroughputSampler()
    // 8 Mbps.
    sampler.record(bytes: 100_000, seconds: 0.1)

    // A 100 KB frame is 0.8 Mbit, so 8 Mbps carries ten of them.
    let rate = try! #require(sampler.sustainableFramesPerSecond(atFrameBytes: 100_000))
    #expect(abs(rate - 10) < 0.001)
    // Half the bytes, twice the frames — the whole reason an operator would drop a preset.
    let smaller = try! #require(sampler.sustainableFramesPerSecond(atFrameBytes: 50_000))
    #expect(abs(smaller - 20) < 0.001)

    #expect(LinkThroughputSampler().sustainableFramesPerSecond(atFrameBytes: 100_000) == nil)
    #expect(sampler.sustainableFramesPerSecond(atFrameBytes: 0) == nil)
}
