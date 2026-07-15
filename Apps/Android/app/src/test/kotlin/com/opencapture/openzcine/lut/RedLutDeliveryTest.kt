package com.opencapture.openzcine.lut

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertTrue

class RedLutDeliveryTest {
    @Test
    fun `versioned Swift RED policy wire maps all states and rejects stale records`() {
        assertEquals(RedLutNetworkAvailability.AVAILABLE, redNetworkAvailability("1\u001F0"))
        assertEquals(RedLutNetworkAvailability.ON_CAMERA_ACCESS_POINT, redNetworkAvailability("1\u001F1"))
        assertEquals(RedLutNetworkAvailability.NO_INTERNET, redNetworkAvailability("1\u001F2"))
        assertEquals(RedLutNetworkAvailability.SWIFT_CORE_UNAVAILABLE, redNetworkAvailability(null))
        assertEquals(RedLutNetworkAvailability.SWIFT_CORE_UNAVAILABLE, redNetworkAvailability("2\u001F0"))
        assertEquals(RedLutNetworkAvailability.SWIFT_CORE_UNAVAILABLE, redNetworkAvailability("1\u001F99"))
        assertEquals(RedLutNetworkAvailability.SWIFT_CORE_UNAVAILABLE, redNetworkAvailability("1\u001F+0"))
    }

    @Test
    fun `public RED configuration remains fail closed without authorized endpoint and terms`() {
        val readiness =
            RedLutDownloadReadiness(
                network = RedLutNetworkAvailability.AVAILABLE,
                configuration = RedLutDownloadConfiguration.UNCONFIGURED,
            )

        assertFalse(readiness.canEnterWorkflow)
        assertFalse(readiness.configurationMessage.isNullOrBlank())
    }

    @Test
    fun `RED workflow configuration requires real HTTPS endpoint terms and authorization`() {
        assertFalse(
            RedLutDownloadConfiguration(
                endpoint = "http://delivery.example.invalid/ipp2",
                termsUrl = "https://www.example.invalid/terms",
                termsRevision = "2026-07",
                authorizedForThisBuild = true,
            ).isAuthorized,
        )
        assertFalse(
            RedLutDownloadConfiguration(
                endpoint = "https://delivery.example.invalid/ipp2",
                termsUrl = "https://www.example.invalid/terms",
                termsRevision = "2026-07",
                authorizedForThisBuild = false,
            ).isAuthorized,
        )
        assertTrue(
            RedLutDownloadConfiguration(
                endpoint = "https://delivery.example.invalid/ipp2",
                termsUrl = "https://www.example.invalid/terms",
                termsRevision = "2026-07",
                authorizedForThisBuild = true,
            ).isAuthorized,
        )
    }
}
