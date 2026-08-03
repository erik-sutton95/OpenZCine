import Testing

@testable import OpenZCineCore

@Test func adaptiveQualityHoldsOnAHealthyStream() {
    var policy = LiveViewAdaptiveQuality()
    var now = 0.0
    for _ in 0..<100 {
        now += 0.1
        #expect(policy.recordFrame(intervalSeconds: 0.1, now: now) != .stepDown)
    }
}

@Test func adaptiveQualityStepsDownOnSustainedCongestionAndOnASpike() {
    // Sustained: EWMA drifts over the congestion threshold within a handful of slow frames.
    var sustained = LiveViewAdaptiveQuality()
    var now = 0.0
    var verdicts: [LiveViewAdaptiveQuality.Verdict] = []
    for _ in 0..<10 {
        now += 0.7
        verdicts.append(sustained.recordFrame(intervalSeconds: 0.7, now: now))
    }
    #expect(verdicts.contains(.stepDown))

    // Spike: one near-deadline frame steps down immediately, without waiting out the EWMA.
    var spiked = LiveViewAdaptiveQuality()
    #expect(spiked.recordFrame(intervalSeconds: 0.1, now: 1) == .hold)
    #expect(spiked.recordFrame(intervalSeconds: 3.0, now: 4) == .stepDown)
}

@Test func adaptiveQualityCoolsDownBetweenSteps() {
    var policy = LiveViewAdaptiveQuality()
    var now = 0.0
    var downs = 0
    // 20 s of continuous heavy congestion: the cooldown limits the ladder to one step per 8 s —
    // a step restarts the stream, so thrashing would cost more than either tier.
    for _ in 0..<20 {
        now += 1.0
        if policy.recordFrame(intervalSeconds: 1.0, now: now) == .stepDown { downs += 1 }
    }
    #expect(downs >= 2)
    #expect(downs <= 3)
}

@Test func adaptiveQualityStepsUpOnlyAfterSustainedHealth() {
    var policy = LiveViewAdaptiveQuality()
    var now = 0.0
    // Congest once so the ladder has somewhere to recover from.
    now += 3.0
    #expect(policy.recordFrame(intervalSeconds: 3.0, now: now) == .stepDown)

    // 30 s of health: not enough yet.
    var sawEarlyStepUp = false
    for _ in 0..<300 {
        now += 0.1
        if policy.recordFrame(intervalSeconds: 0.1, now: now) == .stepUp { sawEarlyStepUp = true }
    }
    #expect(!sawEarlyStepUp)

    // Another 20 s crosses the 45 s streak → exactly one step up (streak restarts after it).
    var stepUps = 0
    for _ in 0..<200 {
        now += 0.1
        if policy.recordFrame(intervalSeconds: 0.1, now: now) == .stepUp { stepUps += 1 }
    }
    #expect(stepUps == 1)

    // A restart voids the streak: no step-up rides stale health across a reconfigure.
    policy.noteStreamRestart()
    var postRestartStepUps = 0
    for _ in 0..<100 {
        now += 0.1
        if policy.recordFrame(intervalSeconds: 0.1, now: now) == .stepUp { postRestartStepUps += 1 }
    }
    #expect(postRestartStepUps == 0)
}
