package com.opencapture.openzcine.pairing

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class ConnectionFailureMessagesTest {
    @Test
    fun `rejectedInitiator maps to operator guidance about Connect to PC`() {
        val message =
            friendlyCameraConnectionFailure(
                "The camera rejected the PTP-IP handshake: rejectedInitiator.",
            )
        assertTrue(message.contains("didn't recognize this phone"))
        assertTrue(message.contains("Connect to PC"))
    }

    @Test
    fun `empty failure falls back to reachability guidance`() {
        assertEquals(
            "Couldn't reach the camera. Check Wi‑Fi and try again.",
            friendlyCameraConnectionFailure(null),
        )
    }

    @Test
    fun `plain operator text is preserved`() {
        assertEquals(
            "USB cable unplugged.",
            friendlyCameraConnectionFailure("USB cable unplugged."),
        )
    }
}
