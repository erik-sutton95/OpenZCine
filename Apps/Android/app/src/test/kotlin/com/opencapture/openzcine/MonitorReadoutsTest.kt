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

    @Test
    fun `resolution label classes width like iOS MonitorTextFormat`() {
        assertEquals("6K · 25p", monitorResolutionLabel("6048x3402", 25, fallback = "held"))
        assertEquals("4K · 24p", monitorResolutionLabel("4032x2268", 24, fallback = "held"))
        assertEquals("8K · 30p", monitorResolutionLabel("7680x4320", 30, fallback = "held"))
        assertEquals("1920 · 50p", monitorResolutionLabel("1920x1080", 50, fallback = "held"))
        assertEquals("held", monitorResolutionLabel(null, 24, fallback = "held"))
        assertEquals("held", monitorResolutionLabel("garbage", 24, fallback = "held"))
    }

    @Test
    fun `codec labels collapse exactly like iOS`() {
        assertEquals("R3D NE", monitorCodecShortLabel("R3D NE 12-bit R3D"))
        assertEquals("ProRes RAW HQ", monitorCodecShortLabel("ProRes RAW HQ"))
        assertEquals("R3D NE", monitorCodecCompactLabel("R3D NE 12-bit R3D", fallback = "held"))
        assertEquals("PR RAW HQ", monitorCodecCompactLabel("ProRes RAW HQ", fallback = "held"))
        assertEquals("H.265", monitorCodecCompactLabel("H.265 10-bit", fallback = "held"))
        assertEquals("held", monitorCodecCompactLabel(null, fallback = "held"))
    }

    @Test
    fun `media status estimates minutes with the iOS bitrate table`() {
        val storage =
            com.opencapture.openzcine.core.CameraStorageStatus(
                totalCapacityBytes = 1_000_000_000_000L,
                freeSpaceBytes = 470_000_000_000L,
            )
        val status =
            monitorMediaStatus(storage, "R3D NE 12-bit R3D", "6048x3402", 25)
        requireNotNull(status)
        assertEquals(470L, status.gigabytesFree)
        assertEquals(47L, status.percentFree)
        assertEquals("470 GB · 47%", status.capacityLabel)
        // 600 Mbps base × (6048·3402 / 3840·2160) × (25/24) ≈ 1550 Mbps →
        // 470 GB ≈ 40 minutes, rounded down like iOS.
        assertEquals(status.minutesRemaining, status.minutesRemaining.coerceIn(35, 45))
        assertEquals("${status.minutesRemaining} Min", status.durationLabel)
        assertNull(monitorMediaStatus(null, "R3D NE", "6048x3402", 25))
    }
}
