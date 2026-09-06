package com.opencapture.openzcine.bridge

import androidx.test.ext.junit.runners.AndroidJUnit4
import java.util.TimeZone
import org.junit.Assert.assertEquals
import org.junit.Test
import org.junit.runner.RunWith

/**
 * Swift Foundation on Android only resolves the device zone from the TZ env var; without it
 * `Calendar.current` is UTC and the camera clock sync writes UTC into a local-time body (#369).
 */
@RunWith(AndroidJUnit4::class)
class SwiftCoreTimeZoneTest {
    @Test
    fun loadingTheCorePublishesTheDeviceZoneToSwiftFoundation() {
        SwiftCore.isAvailable
        assertEquals(TimeZone.getDefault().id, System.getenv("TZ"))
    }
}
