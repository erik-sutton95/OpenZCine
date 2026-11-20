package com.opencapture.openzcine

import com.opencapture.opencine.nikon.SavedCameraTransport
import com.opencapture.opencine.streaming.StreamConnectionRoute
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNull

/** The stream route comes from the monitor's connection mode alone (the shared eligibility reads it). */
class LiveStreamAdoptionTest {
    @Test
    fun eachConnectionModeMapsToItsRoute() {
        val routes = SavedCameraTransport.entries.associateWith { liveStreamRoute(true, false, it) }
        assertEquals(
            mapOf(
                SavedCameraTransport.CAMERA_ACCESS_POINT to StreamConnectionRoute.CAMERA_WIFI,
                SavedCameraTransport.PHONE_HOTSPOT to StreamConnectionRoute.DEVICE_HOTSPOT,
                SavedCameraTransport.INFRASTRUCTURE to StreamConnectionRoute.SHARED_WIFI,
                SavedCameraTransport.USB_C to StreamConnectionRoute.USB_CABLE,
            ),
            routes,
        )
    }

    @Test
    fun hdmiCaptureIsTheCaptureCardWithoutASavedSetup() {
        assertEquals(StreamConnectionRoute.CAPTURE_CARD, liveStreamRoute(true, true, null))
    }

    @Test
    fun noSessionOrNoSavedSetupIsNoCamera() {
        assertNull(liveStreamRoute(false, false, SavedCameraTransport.USB_C))
        assertNull(liveStreamRoute(false, true, null))
        assertNull(liveStreamRoute(true, false, null))
    }
}
