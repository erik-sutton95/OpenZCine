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
}
