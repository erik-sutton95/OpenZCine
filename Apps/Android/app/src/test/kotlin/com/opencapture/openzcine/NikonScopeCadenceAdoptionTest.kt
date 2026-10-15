package com.opencapture.openzcine

import com.opencapture.opencine.media.ScopeSampler
import kotlin.test.Test
import kotlin.test.assertEquals

/** The real JPEG scope adapter uses the cadence of every shared scope consumer. */
class NikonScopeCadenceAdoptionTest {
    @Test
    fun `scope cadence matches the shared sparse and dense assist policy`() {
        val heat = mapOf(
            AndroidThermalTier.NOMINAL to 1.0,
            AndroidThermalTier.FAIR to 1.0,
            AndroidThermalTier.SERIOUS to 3.0,
            AndroidThermalTier.CRITICAL to 5.0,
        )
        for ((tier, multiplier) in heat) {
            for (count in 1..5) {
                assertEquals(ScopeSampler.minIntervalNs(count, multiplier),
                    scopePeriodNanos(count, tier), "count=$count, tier=$tier")
            }
        }
    }
}
