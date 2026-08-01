import Testing

@testable import OpenZCineCore

/// The relay serves every viewer from one encode, so bitrate follows the slowest link that is
/// supposed to keep up: sustained saturation steps down promptly, recovery is deliberately slow.
@Test func bitrateStepsDownOnSustainedSaturation() {
    var adaptation = RelayBitrateAdaptation(now: 0)
    #expect(adaptation.bitsPerSecond == 6_000_000)
    var changed: Int?
    // A 6-second window at 10 ticks/s, 40% of them saturated.
    for tick in 0..<60 {
        let now = Double(tick) / 10
        let result = adaptation.recordTick(saturated: tick % 5 < 2, now: now)
        if result != nil { changed = result }
    }
    #expect(changed == 4_000_000)
}

@Test func bitrateHoldsThroughBriefBlips() {
    var adaptation = RelayBitrateAdaptation(now: 0)
    // 6 seconds with a single saturated tick — far under the step-down threshold.
    for tick in 0..<60 {
        let now = Double(tick) / 10
        #expect(adaptation.recordTick(saturated: tick == 3, now: now) == nil)
    }
    #expect(adaptation.bitsPerSecond == 6_000_000)
}

@Test func bitrateRecoversOneRungAfterSustainedCleanRunning() {
    var adaptation = RelayBitrateAdaptation(now: 0)
    // Force one step down.
    var now = 0.0
    for tick in 0..<60 {
        now = Double(tick) / 10
        _ = adaptation.recordTick(saturated: true, now: now)
    }
    #expect(adaptation.bitsPerSecond == 4_000_000)
    // Clean for the required recovery period — one rung back, not a jump to the top.
    var recovered: Int?
    for tick in 0..<400 {
        now += Double(tick) / 400 + 0.1
        if let change = adaptation.recordTick(saturated: false, now: now) {
            recovered = change
            break
        }
    }
    #expect(recovered == 6_000_000)
}

@Test func bitrateNeverLeavesTheLadder() {
    var adaptation = RelayBitrateAdaptation(now: 0)
    var now = 0.0
    // Hammer saturation far past the floor.
    for tick in 0..<600 {
        now = Double(tick) / 10
        _ = adaptation.recordTick(saturated: true, now: now)
    }
    #expect(adaptation.bitsPerSecond == 2_500_000)
}
