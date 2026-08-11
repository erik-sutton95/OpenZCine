package com.opencapture.openzcine.relay

import com.opencapture.openzcine.core.RelayControlLease
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNull
import kotlin.test.assertTrue

/**
 * The Kotlin half of the control-lease table. Every case here is a case of the Swift core's
 * `RelayControlLeaseTests` — the rule lives in two languages and only stays one rule because both
 * halves are checked against the same rows.
 */
class RelayControlLeaseTest {
    private val t0 = 1_000_000L

    /** The blink this exists for: drop, come back inside the window, still holding the camera. */
    @Test
    fun `a watcher that comes back keeps the control it held`() {
        val lease = RelayControlLease()

        assertTrue(lease.park("watcher-a", t0))
        assertTrue(lease.isParked(t0 + 5_000))
        assertTrue(lease.claim("watcher-a", t0 + 5_000))
        // Claimed once and only once — a second socket cannot inherit the same parked claim.
        assertFalse(lease.claim("watcher-a", t0 + 6_000))
    }

    /**
     * The window has to outlast the watcher's OWN idea of having dropped, or it can never be
     * used: a stalled session is not declared dead for 8 s, and the rejoin ticks every 3 s after.
     */
    @Test
    fun `the window outlasts the watchers own stall deadline`() {
        assertTrue(RelayControlLease.DEFAULT_WINDOW_MILLIS >= 14_000)
        val lease = RelayControlLease()
        lease.park("watcher-a", t0)
        assertTrue(lease.isParked(t0 + 14_000))
    }

    /** And it does end. A watcher that walked off set does not hold the camera indefinitely. */
    @Test
    fun `a watcher that never comes back loses the camera`() {
        val lease = RelayControlLease(windowMillis = 20_000)
        lease.park("watcher-a", t0)

        assertFalse(lease.isParked(t0 + 20_001))
        assertNull(lease.parkedWatcherId(t0 + 20_001))
        assertFalse(lease.claim("watcher-a", t0 + 20_001))
    }

    /** A parked claim belongs to ONE device. This token presses record, so a near-miss is a miss. */
    @Test
    fun `only the watcher that held it can resume it`() {
        val lease = RelayControlLease()
        lease.park("watcher-a", t0)

        assertFalse(lease.claim("watcher-b", t0 + 1_000))
        assertFalse(lease.claim(null, t0 + 1_000))
        assertFalse(lease.claim("", t0 + 1_000))
        // Refused claims leave the real holder's claim intact.
        assertTrue(lease.claim("watcher-a", t0 + 2_000))
    }

    /**
     * A watcher we could never recognise on return is not parked at all — freezing the camera for
     * a device that can never come back would be worse than the behaviour this replaces.
     */
    @Test
    fun `an unrecognisable watcher releases immediately as before`() {
        val lease = RelayControlLease()

        assertFalse(lease.park(null, t0))
        assertFalse(lease.isParked(t0))

        assertFalse(lease.park("", t0))
        assertFalse(lease.isParked(t0))
    }

    /** The operator never waits out the window, and a deliberate hand-back is not a disconnection. */
    @Test
    fun `reclaiming and releasing both end the claim at once`() {
        val lease = RelayControlLease()
        lease.park("watcher-a", t0)

        lease.clear()

        assertFalse(lease.isParked(t0 + 1_000))
        assertFalse(lease.claim("watcher-a", t0 + 1_000))
    }

    /** Both halves agree on the number, not just the shape. */
    @Test
    fun `the window matches the swift core`() {
        assertEquals(20_000L, RelayControlLease.DEFAULT_WINDOW_MILLIS)
    }
}
