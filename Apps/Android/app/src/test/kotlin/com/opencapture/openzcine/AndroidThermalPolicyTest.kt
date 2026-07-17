package com.opencapture.openzcine

import android.os.PowerManager
import kotlin.test.Test
import kotlin.test.assertEquals

class AndroidThermalPolicyTest {
    @Test
    fun `host thermal statuses map monotonically to the shared tiers`() {
        assertEquals(AndroidThermalTier.NOMINAL, androidThermalTierFor(PowerManager.THERMAL_STATUS_NONE))
        assertEquals(AndroidThermalTier.FAIR, androidThermalTierFor(PowerManager.THERMAL_STATUS_LIGHT))
        assertEquals(AndroidThermalTier.FAIR, androidThermalTierFor(PowerManager.THERMAL_STATUS_MODERATE))
        assertEquals(AndroidThermalTier.SERIOUS, androidThermalTierFor(PowerManager.THERMAL_STATUS_SEVERE))
        assertEquals(AndroidThermalTier.CRITICAL, androidThermalTierFor(PowerManager.THERMAL_STATUS_CRITICAL))
        assertEquals(AndroidThermalTier.CRITICAL, androidThermalTierFor(PowerManager.THERMAL_STATUS_SHUTDOWN))
    }

    @Test
    fun `scope cadence mirrors iOS count and thermal shedding`() {
        // ~12 Hz base (iOS scopes refresh ~10 Hz; ticking faster only burns
        // decode + raster + redraw on the hardware floor), 10 Hz when >3.
        assertEquals(83_333_333L, scopePeriodNanos(3, AndroidThermalTier.NOMINAL))
        assertEquals(100_000_000L, scopePeriodNanos(4, AndroidThermalTier.FAIR))
        assertEquals(250_000_000L, scopePeriodNanos(1, AndroidThermalTier.SERIOUS))
        assertEquals(500_000_000L, scopePeriodNanos(5, AndroidThermalTier.CRITICAL))
    }
}
