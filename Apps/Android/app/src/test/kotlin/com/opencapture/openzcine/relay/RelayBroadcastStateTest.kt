package com.opencapture.openzcine.relay

import com.opencapture.opencine.core.BatteryReading
import com.opencapture.opencine.core.ObservationOrigin
import com.opencapture.opencine.core.ObservationPrecision
import com.opencapture.opencine.core.ObservedValue
import com.opencapture.opencine.core.PowerStatus
import com.opencapture.opencine.nikon.CameraPropertySnapshot
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNull

class RelayBroadcastStateTest {
    private fun state(power: PowerStatus) = relayBroadcastState(
        snapshot = CameraPropertySnapshot(batteryPercent = 80),
        power = power,
        recording = false,
        cameraName = "SIMULATED",
        latestFPS = null,
        allowsControlRequests = false,
    )

    @Test
    fun `the broadcast battery is the common session power, never the legacy percent`() {
        // An unknown common reading stays unknown even though the legacy scalar still travels.
        val unknown = state(PowerStatus.unknown)
        assertEquals(80, unknown.cameraBatteryPercent)
        assertNull(unknown.batteryReading)
        assertNull(unknown.batteryExhausted)

        for (exhausted in listOf(false, true)) {
            val reported = state(PowerStatus(
                battery = ObservedValue(0.25, ObservationOrigin.CAMERA_REPORTED, null,
                    precision = ObservationPrecision.Quantized(0.25)),
                exhausted = ObservedValue(exhausted, ObservationOrigin.CAMERA_REPORTED, null)))
            assertEquals(BatteryReading.Steps(1, 4), reported.batteryReading)
            assertEquals(exhausted, reported.batteryExhausted)
        }
    }
}
