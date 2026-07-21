package com.opencapture.openzcine.pairing

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNull
import kotlin.test.assertTrue

class CameraApSsidHelpersTest {
    @Test
    fun `recognizes Nikon soft-AP SSIDs`() {
        assertTrue(looksLikeNikonAccessPointSsid("NIKON_ZR_01234"))
        assertTrue(looksLikeNikonAccessPointSsid(" nikon_zr_abcde "))
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
