package com.opencapture.openzcine.pairing

import com.opencapture.opencine.nikon.CameraConnectionFailure
import com.opencapture.opencine.nikon.NikonBodyWake
import java.nio.file.Path
import kotlin.io.path.readText
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/** The copy for a failed connect comes from the typed failure, never from its message (A4-45). */
class ConnectionFailureMessagesTest {
    @Test
    fun `a refused initiator maps to guidance about Connect to PC, whatever the message says`() {
        val message = friendlyCameraConnectionFailure(CameraConnectionFailure.REJECTED_INITIATOR, "Init_Fail 1")
        assertTrue(message.contains("didn't recognize this phone"))
        assertTrue(message.contains("Connect to PC"))
    }

    /**
     * An unspecified Init_Fail is not a forgotten phone (iOS `isRejectedInitiator` reads only
     * rejectedInitiator); the old text classifier matched its "rejected the PTP-IP handshake".
     */
    @Test
    fun `an unreachable camera gets reachability guidance and no packet text`() {
        assertEquals(
            "Couldn't reach the camera. Check Wi‑Fi and try again.",
            friendlyCameraConnectionFailure(
                CameraConnectionFailure.UNREACHABLE,
                "The camera rejected the PTP-IP handshake: unspecified.",
            ),
        )
        assertFalse(CameraConnectionFailure.UNREACHABLE.savedProfileUnavailable)
    }

    /** Hardware pass 2026-10-25 (3.7): a body the wake never heard read "Couldn't reach". */
    @Test
    fun `a body the wake never heard gets the shared silent copy iOS shows`() {
        assertEquals(
            NikonBodyWake.silentMessage(""),
            friendlyCameraConnectionFailure(CameraConnectionFailure.CAMERA_SILENT, "anything"),
        )
    }

    @Test
    fun `empty failure falls back to reachability guidance`() {
        assertEquals(
            "Couldn't reach the camera. Check Wi‑Fi and try again.",
            friendlyCameraConnectionFailure(null, null),
        )
        assertEquals(
            "Couldn't reach the camera. Check Wi‑Fi and try again.",
            friendlyCameraConnectionFailure(CameraConnectionFailure.OTHER, " "),
        )
    }

    /**
     * The transport's non-numeric-host refusal is an implementation detail, never operator
     * copy: it reaches this mapper only if some path hands the dialer a non-dialable key
     * (#327), and the operator's remedy is the rejoin/rediscover flow, not address formatting.
     */
    @Test
    fun `numeric IPv4 transport refusal maps to rejoin guidance`() {
        assertEquals(
            "Couldn't find the camera's address on its network. Rejoin the camera's Wi‑Fi and try again.",
            friendlyCameraConnectionFailure(CameraConnectionFailure.NON_NUMERIC_HOST, "anything"),
        )
    }

    @Test
    fun `typed failures with their own copy`() {
        assertEquals(
            "The camera didn't respond in time. Check Wi‑Fi and try again.",
            friendlyCameraConnectionFailure(CameraConnectionFailure.TIMEOUT, "Init timed out."),
        )
        assertEquals(
            "The camera ended the connection. Try again.",
            friendlyCameraConnectionFailure(CameraConnectionFailure.CONNECTION_CLOSED, null),
        )
        assertTrue(
            friendlyCameraConnectionFailure(CameraConnectionFailure.PAIRING_CHALLENGE_UNAVAILABLE, null)
                .contains("did not provide a pairing code"),
        )
        assertTrue(
            friendlyCameraConnectionFailure(CameraConnectionFailure.SAVED_PROFILE_REQUIRED, null)
                .contains("needs to pair with this phone again"),
        )
    }

    @Test
    fun `plain operator text is preserved`() {
        assertEquals("USB cable unplugged.", friendlyCameraConnectionFailure(null, "USB cable unplugged."))
        val busy = "Another device is connected to this camera. Disconnect it there, then try again."
        assertEquals(busy, friendlyCameraConnectionFailure(CameraConnectionFailure.BUSY, busy))
    }

    /**
     * A raw protocol or transport error reaches this mapper as an untyped failure; the operator
     * gets the reachability copy, never the dump (ZAB-147, the old "ptp-ip"/"0x" sanitizer).
     */
    @Test
    fun `a technical failure detail falls back to reachability guidance`() {
        assertEquals(
            "Couldn't reach the camera. Check Wi‑Fi and try again.",
            friendlyCameraConnectionFailure(CameraConnectionFailure.OTHER, "PTP-IP response 0x2019"),
        )
        assertEquals(
            "Couldn't reach the camera. Check Wi‑Fi and try again.",
            friendlyCameraConnectionFailure(null, "USB bulk transfer failed 0x80070005"),
        )
        assertEquals(
            "Couldn't reach the camera. Check Wi‑Fi and try again.",
            friendlyCameraConnectionFailure(
                CameraConnectionFailure.OTHER,
                "java.lang.IllegalStateException: unexpected packet",
            ),
        )
        assertEquals(
            "Couldn't reach the camera. Check Wi‑Fi and try again.",
            friendlyCameraConnectionFailure(
                CameraConnectionFailure.OTHER,
                "read failed: errno 54 (Connection reset by peer)",
            ),
        )
    }

    /** No pairing source classifies failure words again (the producer types them). */
    @Test
    fun `no connect failure is classified by its text`() {
        val pairing = Path.of(requireNotNull(System.getProperty("openzcine.repositoryRoot")))
            .resolve("Apps/Android/app/src/main/kotlin/com/opencapture/openzcine/pairing")
        for (name in listOf("ConnectionFailureMessages.kt", "SavedCameraConnector.kt", "PairingExperience.kt")) {
            val source = pairing.resolve(name).readText()
            for (token in listOf("rejectedinitiator", "closed the connection", "savedprofilerequired", "numeric ipv4")) {
                assertFalse("$name classifies \"$token\"", source.lowercase().contains("contains(\"$token"))
            }
        }
    }
}
