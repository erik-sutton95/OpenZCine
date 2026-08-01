import Testing

@testable import OpenZCineCore

/// The relay serves every viewer from one encode, so bitrate follows the slowest link that is
/// supposed to keep up: sustained saturation steps down promptly, recovery is deliberately slow.
@Test func bitrateStepsDownOnSustainedSaturation() {
    var adaptation = RelayBitrateAdaptation(now: 0)
    #expect(adaptation.bitsPerSecond == 10_000_000)
    var changed: Int?
    // A 6-second window at 10 ticks/s: runs of three consecutive saturated ticks — the stream
    // genuinely outrunning the drain, not per-frame pacing blips.
    for tick in 0..<60 {
        let now = Double(tick) / 10
        let result = adaptation.recordTick(saturated: tick % 5 < 3, now: now)
        if result != nil { changed = result }
    }
    #expect(changed == 7_000_000)
}

@Test func bitrateHoldsThroughBriefBlips() {
    var adaptation = RelayBitrateAdaptation(now: 0)
    // 6 seconds with a single saturated tick — far under the step-down threshold.
    for tick in 0..<60 {
        let now = Double(tick) / 10
        #expect(adaptation.recordTick(saturated: tick == 3, now: now) == nil)
    }
    #expect(adaptation.bitsPerSecond == 10_000_000)
}

/// The field regression: a two-frame in-flight cap at stream rate makes every viewer momentarily
/// "full" on isolated ticks all the time. Counting those as congestion walked multi-watcher
/// sessions down the ladder and the slow-recovery rule kept them there. Alternating
/// saturated/clean ticks — 50% raw saturation, zero consecutive — must not move the rate.
@Test func bitrateIgnoresAlternatingPacingBackpressure() {
    var adaptation = RelayBitrateAdaptation(now: 0)
    for tick in 0..<120 {
        let now = Double(tick) / 10
        #expect(adaptation.recordTick(saturated: tick % 2 == 0, now: now) == nil)
    }
    #expect(adaptation.bitsPerSecond == 10_000_000)
}

@Test func bitrateRecoversOneRungAfterSustainedCleanRunning() {
    var adaptation = RelayBitrateAdaptation(now: 0)
    // Force one step down.
    var now = 0.0
    for tick in 0..<60 {
        now = Double(tick) / 10
        _ = adaptation.recordTick(saturated: true, now: now)
    }
    #expect(adaptation.bitsPerSecond == 7_000_000)
    // Clean for the required recovery period — one rung back, not a jump to the top.
    var recovered: Int?
    for tick in 0..<400 {
        now += Double(tick) / 400 + 0.1
        if let change = adaptation.recordTick(saturated: false, now: now) {
            recovered = change
            break
        }
    }
    #expect(recovered == 10_000_000)
}

/// The QP cap steps WITH the rate: strict at full budget, relaxed on the low rungs — a cap the
/// rate controller cannot honor on grainy log content would turn a step-down into a no-op right
/// when shrinking the stream is the whole point.
@Test func frameQPCapRelaxesAsTheRateStepsDown() {
    var adaptation = RelayBitrateAdaptation(now: 0)
    #expect(adaptation.maxFrameQP == 36)
    var now = 0.0
    for tick in 0..<60 {
        now = Double(tick) / 10
        _ = adaptation.recordTick(saturated: true, now: now)
    }
    #expect(adaptation.bitsPerSecond == 7_000_000)
    #expect(adaptation.maxFrameQP == 39)
    for tick in 0..<600 {
        now += Double(tick) / 10
        _ = adaptation.recordTick(saturated: true, now: now)
    }
    #expect(adaptation.bitsPerSecond == 3_000_000)
    #expect(adaptation.maxFrameQP == 45)
}

@Test func bitrateNeverLeavesTheLadder() {
    var adaptation = RelayBitrateAdaptation(now: 0)
    var now = 0.0
    // Hammer saturation far past the floor.
    for tick in 0..<600 {
        now = Double(tick) / 10
        _ = adaptation.recordTick(saturated: true, now: now)
    }
    #expect(adaptation.bitsPerSecond == 3_000_000)
}
