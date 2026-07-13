import Testing

@testable import OpenZCineCore

@Suite("ReconnectBackoff")
struct ReconnectBackoffTests {
    // Midpoint jitter (0.5) yields the un-jittered value, so these pin the exponential schedule.
    @Test func firstAttemptUsesBaseDelay() {
        let backoff = ReconnectBackoff(
            baseSeconds: 0.5, maxSeconds: 30, multiplier: 2, jitterFraction: 0.3)
        #expect(backoff.delaySeconds(forAttempt: 0, jitter: 0.5) == 0.5)
    }

    @Test func growsExponentially() {
        let backoff = ReconnectBackoff(
            baseSeconds: 0.5, maxSeconds: 30, multiplier: 2, jitterFraction: 0.3)
        #expect(backoff.delaySeconds(forAttempt: 1, jitter: 0.5) == 1.0)
        #expect(backoff.delaySeconds(forAttempt: 2, jitter: 0.5) == 2.0)
        #expect(backoff.delaySeconds(forAttempt: 3, jitter: 0.5) == 4.0)
    }

    @Test func clampsToMaximum() {
        let backoff = ReconnectBackoff(
            baseSeconds: 0.5, maxSeconds: 30, multiplier: 2, jitterFraction: 0.3)
        #expect(backoff.delaySeconds(forAttempt: 20, jitter: 0.5) == 30)
    }

    @Test func jitterSpreadsBelowAndAbove() {
        let backoff = ReconnectBackoff(
            baseSeconds: 0.5, maxSeconds: 30, multiplier: 2, jitterFraction: 0.3)
        // attempt 3 → un-jittered 4.0; jitter 0 → -30%, jitter 1 → +30%.
        #expect(abs(backoff.delaySeconds(forAttempt: 3, jitter: 0) - 2.8) < 1e-9)
        #expect(abs(backoff.delaySeconds(forAttempt: 3, jitter: 1) - 5.2) < 1e-9)
    }

    @Test func jitterNeverExceedsMaximum() {
        let backoff = ReconnectBackoff(
            baseSeconds: 0.5, maxSeconds: 30, multiplier: 2, jitterFraction: 0.3)
        #expect(backoff.delaySeconds(forAttempt: 20, jitter: 1) == 30)
    }

    @Test func negativeAttemptTreatedAsFirst() {
        let backoff = ReconnectBackoff(
            baseSeconds: 0.5, maxSeconds: 30, multiplier: 2, jitterFraction: 0.3)
        #expect(backoff.delaySeconds(forAttempt: -3, jitter: 0.5) == 0.5)
    }

    @Test func jitterSampleIsClampedToUnitRange() {
        let backoff = ReconnectBackoff(
            baseSeconds: 1, maxSeconds: 30, multiplier: 2, jitterFraction: 0.5)
        // Out-of-range jitter samples clamp to [0, 1] rather than over/under-shooting.
        #expect(
            backoff.delaySeconds(forAttempt: 0, jitter: -1)
                == backoff.delaySeconds(forAttempt: 0, jitter: 0))
        #expect(
            backoff.delaySeconds(forAttempt: 0, jitter: 2)
                == backoff.delaySeconds(forAttempt: 0, jitter: 1))
    }
}
