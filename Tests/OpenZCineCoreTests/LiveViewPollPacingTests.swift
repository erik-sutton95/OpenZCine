import Testing

@testable import OpenZCineCore

/// A poll is a PTP round trip on the live-view channel; the next frame queues behind it. These
/// pin the trade: fast links keep the responsive baseline, slow links spread polls out instead
/// of hitching the feed on a fixed cadence (the router-path "stutters every few frames" report).
@Test func pollPacingKeepsTheBaselineOnAFastLink() {
    // ~10 ms round trip against a 33 ms frame period — the camera-AP shape.
    #expect(
        LiveViewPollPacing.eventPollStride(
            roundTripMilliseconds: 10, framePeriodMilliseconds: 33.3) == 4)
    #expect(
        LiveViewPollPacing.idlePollStrideMultiplier(
            roundTripMilliseconds: 10, framePeriodMilliseconds: 33.3) == 1)
}

@Test func pollPacingKeepsTheBaselineBeforeAnythingIsMeasured() {
    #expect(
        LiveViewPollPacing.eventPollStride(
            roundTripMilliseconds: nil, framePeriodMilliseconds: 33.3) == 4)
    #expect(
        LiveViewPollPacing.idlePollStrideMultiplier(
            roundTripMilliseconds: nil, framePeriodMilliseconds: 33.3) == 1)
}

@Test func pollPacingSpreadsPollsAsTheirCostApproachesAFrame() {
    // ~20 ms through a router: more than half a frame slot — halve the cadence.
    #expect(
        LiveViewPollPacing.eventPollStride(
            roundTripMilliseconds: 20, framePeriodMilliseconds: 33.3) == 8)
    // A poll that costs a whole frame slot.
    #expect(
        LiveViewPollPacing.eventPollStride(
            roundTripMilliseconds: 40, framePeriodMilliseconds: 33.3) == 12)
    // A poll that costs two or more frame slots — the congested-router shape.
    #expect(
        LiveViewPollPacing.eventPollStride(
            roundTripMilliseconds: 80, framePeriodMilliseconds: 33.3) == 20)
    #expect(
        LiveViewPollPacing.idlePollStrideMultiplier(
            roundTripMilliseconds: 80, framePeriodMilliseconds: 33.3) == 5)
}

@Test func pollPacingSurvivesADegenerateFramePeriod() {
    #expect(
        LiveViewPollPacing.eventPollStride(
            roundTripMilliseconds: 40, framePeriodMilliseconds: 0) == 4)
}
