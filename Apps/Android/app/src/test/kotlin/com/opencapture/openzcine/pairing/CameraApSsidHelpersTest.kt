package com.opencapture.openzcine.pairing

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNull
import kotlin.test.assertTrue

class CameraApSsidHelpersTest {
    /**
     * Mirrors the shared core's `isNikonZAccessPoint` fixtures (CameraWiFiSSIDTests) — the
     * Kotlin matcher is a transcription of that algorithm, and these cases are the drift alarm.
     * The old lax matcher accepted `nikon_zr_abcde`; the core requires a serial digit, so the
     * two disagreed about what counts as a camera network.
     */
    @Test
    fun `recognizes Nikon soft-AP SSIDs`() {
        assertTrue(looksLikeNikonAccessPointSsid("NIKON_ZR_01234"))
        assertTrue(looksLikeNikonAccessPointSsid(" nikon_zr_01234 "))
        assertTrue(looksLikeNikonAccessPointSsid("NIKONZ_8_X12345"))
        assertFalse(looksLikeNikonAccessPointSsid("nikon_zr_abcde"))
        assertFalse(looksLikeNikonAccessPointSsid("NIKON_Z"))
        assertFalse(looksLikeNikonAccessPointSsid("NIKON_Z9 AP!"))
        assertFalse(looksLikeNikonAccessPointSsid("HomeWifi"))
        assertFalse(looksLikeNikonAccessPointSsid(""))
    }

    @Test
    fun `prefix fallback uses brand prefix only`() {
        assertEquals("NIKON_ZR_", nikonAccessPointPrefix("NIKON_ZR_01234"))
        assertEquals("NIKON_Z", nikonAccessPointPrefix("NIKON_Z9_AP"))
        assertNull(nikonAccessPointPrefix("HomeWifi"))
    }
}
