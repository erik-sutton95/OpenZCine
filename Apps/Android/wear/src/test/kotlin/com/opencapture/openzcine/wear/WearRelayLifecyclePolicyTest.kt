package com.opencapture.openzcine.wear

import kotlin.test.Test
import kotlin.test.assertFalse
import kotlin.test.assertNull
import kotlin.test.assertTrue

class WearRelayLifecyclePolicyTest {
    @Test
    fun `reachable phone is not fresh monitor state without a new snapshot`() {
        val freshness = WatchRelayFreshness(maximumAgeMillis = 6_000L)

        assertFalse(freshness.isFresh(100L))
        assertNull(freshness.remainingMillis(100L))

        freshness.accept(100L)
        assertTrue(freshness.isFresh(6_099L))
        assertFalse(freshness.isFresh(6_100L))
        assertTrue(freshness.remainingMillis(6_100L) == 0L)

        freshness.clear()
        assertFalse(freshness.isFresh(6_100L))
    }

    @Test
    fun `record reply requires exact phone node and request identifier`() {
        val pending = PendingWearCommand(nodeID = "phone-a", requestID = 42L)

        assertTrue(pending.matches(nodeID = "phone-a", requestID = 42L))
        assertFalse(pending.matches(nodeID = "phone-b", requestID = 42L))
        assertFalse(pending.matches(nodeID = "phone-a", requestID = 43L))
    }

    @Test
    fun `three-slot preview cannot regress to an older arrival`() {
        val sequence = LatestWearFrameSequence()

        assertTrue(sequence.accept(40L))
        assertTrue(sequence.accept(42L))
        assertFalse(sequence.accept(41L))
        assertFalse(sequence.accept(42L))
        sequence.clear()
        assertTrue(sequence.accept(1L))
    }
}
