package com.opencapture.openzcine.pairing

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNull
import kotlin.test.assertTrue

class CameraApAvailabilityTrackerTest {
    @Test
    fun `duplicate availability does not count as a camera AP restart`() {
        val tracker = CameraApAvailabilityTracker<String>()

        tracker.requestStarted()
        assertEquals(
            CameraApAvailabilityTracker.AvailableResult(
                shouldBind = true,
                reassociationGeneration = null,
            ),
            tracker.onAvailable("original"),
        )
        assertEquals(1L, tracker.nextReassociationGeneration())

        assertEquals(
            CameraApAvailabilityTracker.AvailableResult(
                shouldBind = false,
                reassociationGeneration = null,
            ),
            tracker.onAvailable("original"),
        )
        assertEquals(1L, tracker.nextReassociationGeneration())
    }

    @Test
    fun `loss then new availability completes the next reassociation generation`() {
        val tracker = CameraApAvailabilityTracker<String>()

        tracker.requestStarted()
        tracker.onAvailable("original")
        val expectedGeneration = tracker.nextReassociationGeneration()

        assertTrue(tracker.onLost("original"))
        assertEquals(
            CameraApAvailabilityTracker.AvailableResult(
                shouldBind = true,
                reassociationGeneration = expectedGeneration,
            ),
            tracker.onAvailable("replacement"),
        )
        assertEquals(2L, tracker.nextReassociationGeneration())
    }

    @Test
    fun `a stale loss cannot clear a newer active network`() {
        val tracker = CameraApAvailabilityTracker<String>()

        tracker.requestStarted()
        tracker.onAvailable("original")
        assertFalse(tracker.onLost("stale"))

        assertEquals(
            CameraApAvailabilityTracker.AvailableResult(
                shouldBind = false,
                reassociationGeneration = null,
            ),
            tracker.onAvailable("original"),
        )
        assertTrue(tracker.onLost("original"))
    }

    @Test
    fun `a replacement callback counts as reassociation when Android omits loss`() {
        val tracker = CameraApAvailabilityTracker<String>()

        tracker.requestStarted()
        tracker.onAvailable("original")

        assertEquals(
            CameraApAvailabilityTracker.AvailableResult(
                shouldBind = true,
                reassociationGeneration = 1L,
            ),
            tracker.onAvailable("replacement"),
        )
    }

    @Test
    fun `unavailable blocks new restart waits without pretending the network was lost`() {
        val tracker = CameraApAvailabilityTracker<String>()

        tracker.requestStarted()
        tracker.onAvailable("original")
        tracker.onUnavailable()

        assertNull(tracker.nextReassociationGeneration())
        assertFalse(tracker.onLost("stale"))
        assertTrue(tracker.onLost("original"))
    }

    @Test
    fun `release clears the old request before a new request begins`() {
        val tracker = CameraApAvailabilityTracker<String>()

        tracker.requestStarted()
        tracker.onAvailable("original")
        tracker.release()

        assertNull(tracker.nextReassociationGeneration())
        assertEquals(
            CameraApAvailabilityTracker.AvailableResult(
                shouldBind = false,
                reassociationGeneration = null,
            ),
            tracker.onAvailable("stale"),
        )
    }
}
