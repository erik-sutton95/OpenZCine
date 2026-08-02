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

    /**
     * The escalation classifier, mirroring iOS `isSavedProfileUnavailable`: a hangup during a
     * saved-profile attempt means the camera-side profile never met this initiator — the field
     * shape (`pairing=skipped → "The camera ended the connection"`) that motivated the iOS
     * re-pair fallback. Refusal tokens escalate too; ordinary reachability failures do not.
     */
    @Test
    fun `saved profile unavailable covers hangups and refusals but not reachability`() {
        assertEquals(true, indicatesSavedProfileUnavailable("The camera closed the connection."))
        assertEquals(true, indicatesSavedProfileUnavailable("handshake rejectedInitiator (1)"))
        assertEquals(true, indicatesSavedProfileUnavailable("savedProfileRequired"))
        assertEquals(false, indicatesSavedProfileUnavailable("Connection timed out"))
        assertEquals(false, indicatesSavedProfileUnavailable(null))
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
