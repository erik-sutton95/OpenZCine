package com.opencapture.openzcine

import com.opencapture.opencine.nikon.CameraPropertySnapshot
import com.opencapture.opencine.nikon.CameraStorageStatus
import com.opencapture.opencine.nikon.LiveFrameTimecode
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNull
import kotlin.test.assertTrue

class MonitorReadoutsTest {
    @Test
    fun `monitor and multicam preserve the camera frame counter`() {
        val camera = LiveFrameTimecode(on = true, hour = 1, minute = 2, second = 3, frame = 17)
        assertEquals("01:02:03:17", monitorTimecodeLabel(camera))
        assertEquals("01:02:03:18", monitorTimecodeLabel(camera.copy(frame = 18)))
        assertEquals("00:00:00:00", monitorTimecodeLabel(camera.copy(hour = 0, minute = 0, second = 0, frame = 0)))
        assertNull(monitorTimecodeLabel(null))
        assertNull(monitorTimecodeLabel(camera.copy(on = false)))
        assertNull(monitorTimecodeLabel(camera.copy(hour = 24)))
        assertNull(monitorTimecodeLabel(camera.copy(frame = -1)))
    }

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
    fun `the camera battery is the body's five step gauge, never a percent`() {
        // A5-01, #303: BatteryLevel only carries 1/20/40/60/80/100, so "60%" claimed a precision
        // the body never sent (it reads 60 for anything from 40 to 59 percent).
        val sixty = requireNotNull(nikonCameraBatteryReading(60, externalPower = true))
        assertNull(sixty.percent)
        assertEquals(3, sixty.bars)
        assertEquals(5, sixty.barCount)
        assertTrue(sixty.camera)
        assertEquals(true, sixty.charging)
        assertFalse(sixty.warning)
        assertFalse(sixty.exhausted)
        // An off-step value rounds up to the step it sits under; two bars warns.
        val low = requireNotNull(nikonCameraBatteryReading(39, externalPower = null))
        assertEquals(2, low.bars)
        assertTrue(low.warning)
        // The blinking shutter-disabled step pulses.
        val critical = requireNotNull(nikonCameraBatteryReading(1, externalPower = false))
        assertEquals(1, critical.bars)
        assertTrue(critical.exhausted)
        // An unread battery is absent, never an empty red cell.
        assertNull(nikonCameraBatteryReading(null, externalPower = true))
        assertNull(nikonCameraBatteryReading(0, externalPower = null))
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
            CameraStorageStatus(
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
