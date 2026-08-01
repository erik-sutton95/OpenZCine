import Testing

@testable import OpenZCineCore

/// The discriminator behind #297: a replaying body whose command channel still answers is
/// busy (menu, playback, review) and gets patience; anything else stays on the restart path,
/// which is what keeps #283's genuinely wedged body self-healing.
@Test func bodyBusyHoldRequiresBothReplayAndAHealthyChannel() {
    #expect(
        BodyBusyHoldPolicy.shouldHold(isRepeatingLastFrame: true, commandChannelAnswers: true))
    #expect(
        !BodyBusyHoldPolicy.shouldHold(isRepeatingLastFrame: true, commandChannelAnswers: false))
    #expect(
        !BodyBusyHoldPolicy.shouldHold(isRepeatingLastFrame: false, commandChannelAnswers: true))
    #expect(
        !BodyBusyHoldPolicy.shouldHold(
            isRepeatingLastFrame: false, commandChannelAnswers: false))
}

/// The hold outlasts a menu session and still ends: a wedge recovers unattended.
@Test func bodyBusyHoldIsGenerousButBounded() {
    #expect(BodyBusyHoldPolicy.maxHoldSeconds >= 120)
    #expect(BodyBusyHoldPolicy.maxHoldSeconds <= 600)
    #expect(BodyBusyHoldPolicy.holdPullIntervalSeconds >= 1)
}
