package com.opencapture.openzcine

import android.os.BatteryManager
import com.opencapture.openzcine.core.CameraPropertySnapshot
import com.opencapture.openzcine.core.CameraStorageStatus
import com.opencapture.openzcine.core.LiveFrameTimecode
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNull
import kotlin.test.assertTrue

class MonitorReadoutsTest {
    @Test
    fun `camera snapshot projects every monitor readout without demo fallbacks`() {
        val readouts =
            monitorCameraReadouts(
                CameraPropertySnapshot(
                    resolution = "6K 16:9",
                    frameRate = 25,
                    codec = "R3D NE",
                    batteryPercent = 80,
                    externalPower = false,
                    storage =
                        CameraStorageStatus(
                            totalCapacityBytes = 1_000_000_000_000L,
                            freeSpaceBytes = 470_000_000_000L,
                        ),
                ),
            )

        assertEquals("6K 16:9", readouts.resolution)
        assertEquals("R3D NE", readouts.codec)
        assertEquals("470 GB · 47%", readouts.media)
        assertEquals("25.00", readouts.framesPerSecond)
        assertEquals(80, readouts.batteryPercent)
        assertEquals(false, readouts.externalPower)
    }

    @Test
    fun `missing blank and malformed camera values stay visibly unavailable`() {
        val missing = monitorCameraReadouts(CameraPropertySnapshot())
        assertEquals(UNAVAILABLE_MONITOR_VALUE, missing.resolution)
        assertEquals(UNAVAILABLE_MONITOR_VALUE, missing.codec)
        assertEquals(UNAVAILABLE_MONITOR_VALUE, missing.media)
        assertEquals(UNAVAILABLE_MONITOR_VALUE, missing.framesPerSecond)
        assertNull(missing.batteryPercent)

        val malformed =
            monitorCameraReadouts(
                CameraPropertySnapshot(
                    resolution = " ",
                    codec = "",
                    frameRate = 0,
                    batteryPercent = 101,
                    storage = CameraStorageStatus(100L, 101L),
                ),
            )
        assertEquals(UNAVAILABLE_MONITOR_VALUE, malformed.resolution)
        assertEquals(UNAVAILABLE_MONITOR_VALUE, malformed.codec)
        assertEquals(UNAVAILABLE_MONITOR_VALUE, malformed.media)
        assertEquals(UNAVAILABLE_MONITOR_VALUE, malformed.framesPerSecond)
        assertNull(malformed.batteryPercent)
    }

    @Test
    fun `battery labels distinguish percentage external power and unavailable`() {
        assertEquals("0%", batteryReadoutLabel(0))
        assertEquals("80%", batteryReadoutLabel(80, externalPower = true))
        assertEquals("EXT", batteryReadoutLabel(null, externalPower = true))
        assertEquals(UNAVAILABLE_MONITOR_VALUE, batteryReadoutLabel(Int.MIN_VALUE))
        val poweredPercentage = monitorBatteryPresentation(80, externalPower = true)
        assertEquals("80%", poweredPercentage.label)
        assertEquals(80, poweredPercentage.percent)
        assertTrue(poweredPercentage.externalPower)
        val poweredOnly = monitorBatteryPresentation(null, externalPower = true)
        assertEquals("EXT", poweredOnly.label)
        assertTrue(poweredOnly.externalPower)
        assertFalse(monitorBatteryPresentation(80, externalPower = false).externalPower)
        assertNull(readPhoneBatteryPercent(null))
    }

    @Test
    fun `phone battery broadcast preserves percentage and charging state`() {
        val charging =
            phoneBatteryReadout(
                level = 167,
                scale = 200,
                status = BatteryManager.BATTERY_STATUS_CHARGING,
                fallbackPercent = null,
            )
        assertEquals(84, charging.percent)
        assertEquals(true, charging.externalPower)

        val full =
            phoneBatteryReadout(
                level = 100,
                scale = 100,
                status = BatteryManager.BATTERY_STATUS_FULL,
                fallbackPercent = null,
            )
        assertEquals(true, full.externalPower)

        val unplugged =
            phoneBatteryReadout(
                level = -1,
                scale = 0,
                status = BatteryManager.BATTERY_STATUS_DISCHARGING,
                fallbackPercent = 62,
            )
        assertEquals(62, unplugged.percent)
        assertEquals(false, unplugged.externalPower)
    }

    @Test
    fun `timecode uses exact enabled camera fields and never an elapsed clock`() {
        val camera = LiveFrameTimecode(on = true, hour = 1, minute = 2, second = 3, frame = 4)
        assertEquals(camera, authoritativeTimecode(camera))
        assertEquals("01:02:03:04", cameraTimecodeLabel(camera))

        val disabled = camera.copy(on = false)
        assertNull(authoritativeTimecode(disabled))
        assertEquals(UNAVAILABLE_TIMECODE, cameraTimecodeLabel(disabled))
        assertEquals(UNAVAILABLE_TIMECODE, cameraTimecodeLabel(null))
    }

    @Test
    fun `out of range timecode is unavailable rather than normalized`() {
        val invalid = LiveFrameTimecode(on = true, hour = 24, minute = 0, second = 0, frame = 0)

        assertNull(authoritativeTimecode(invalid))
        assertEquals(UNAVAILABLE_TIMECODE, cameraTimecodeLabel(invalid))
    }
}
