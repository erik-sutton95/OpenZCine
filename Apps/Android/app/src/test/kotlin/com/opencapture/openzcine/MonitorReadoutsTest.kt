package com.opencapture.openzcine

import com.opencapture.opencine.cameracontrols.MonitorOperatorExposureReading
import com.opencapture.opencine.cameracontrols.cameraPowerReading
import com.opencapture.opencine.core.ObservationOrigin
import com.opencapture.opencine.core.ObservedValue
import com.opencapture.opencine.core.ISOValue
import com.opencapture.opencine.core.SettingValue
import com.opencapture.opencine.nikon.NikonCameraBatteryGauge
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
    fun `the body exposure indicator reaches the shared gauge in shared EV words`() {
        // A1-32: the 1/6 EV indicator feeds the shared gauge; A5-16: it spells 0.0 and U+2212 like every EV.
        fun stops(sixths: Int?, lit: Boolean?) =
            nikonExposureStops(CameraPropertySnapshot(evIndicatorSixths = sixths, evIndicatorLit = lit))
        assertEquals("0.0", MonitorOperatorExposureReading(stops(0, true)).label)
        assertEquals("\u22120.3", MonitorOperatorExposureReading(stops(-2, true)).label)
        assertEquals("+1.0", MonitorOperatorExposureReading(stops(6, null)).label)
        assertNull(stops(6, false), "an unlit indicator is unknown")
        assertNull(stops(null, true))
    }

    @Test
    fun `camera-owned strip values read dimmed and a locked shutter carries the padlock and hold`() {
        // ZAA-141 / ZAA-113: baseline dimmed body-owned cells, drew the lock glyph, and a hold on
        // the SHUTTER cell toggled MovieTVLock.
        fun setting(kind: MonitorPickerKind, locked: Boolean = false, dimmed: Boolean = false) =
            MonitorCaptureSettingPresentation(kind, kind.name, "1/50", "1/16000", null, null,
                controlLocked = locked, dimmed = dimmed)
        val locked = nikonReadoutCue(setting(MonitorPickerKind.SHUTTER, locked = true, dimmed = true), photography = false)
        assertEquals(NikonReadoutCue(dimmed = true, badge = com.opencapture.monitorui.MonitorIcon.LOCK,
            holdTogglesShutterLock = true), locked)
        assertTrue(nikonReadoutCue(setting(MonitorPickerKind.SHUTTER), photography = false).holdTogglesShutterLock)
        val programOwned = nikonReadoutCue(setting(MonitorPickerKind.SHUTTER, dimmed = true), photography = true)
        assertEquals(NikonReadoutCue(dimmed = true, badge = null, holdTogglesShutterLock = false), programOwned)
        assertEquals(NikonReadoutCue(false, null, false), nikonReadoutCue(setting(MonitorPickerKind.ISO), photography = false))
    }

    @Test
    fun `a camera-owned strip value has no quick drum`() {
        // CodeRabbit #462: the R3D NE ISO lock while recording dims ISO; a press must not open its drum.
        val locked = NikonReadoutCue(dimmed = true, badge = com.opencapture.monitorui.MonitorIcon.LOCK,
            holdTogglesShutterLock = false)
        val free = NikonReadoutCue(dimmed = false, badge = null, holdTogglesShutterLock = false)
        assertFalse(nikonReadoutQuickEnabled(MonitorPickerKind.ISO, false, false, true, locked))
        assertTrue(nikonReadoutQuickEnabled(MonitorPickerKind.ISO, false, false, true, free))
        assertFalse(nikonReadoutQuickEnabled(MonitorPickerKind.SHUTTER, true, null, false, locked))
        assertTrue(nikonReadoutQuickEnabled(MonitorPickerKind.SHUTTER, false, false, true, free))
        assertFalse(nikonReadoutQuickEnabled(MonitorPickerKind.SHUTTER, false, null, true, free))
    }

    @Test
    fun `movie auto ISO shows the working ISO on the strip`() {
        // ZAA-142: baseline strip read "A3200" while movie Auto ISO is on, "Auto" only unreported.
        val auto = SettingValue.Iso(ISOValue.Auto)
        val properties = CameraPropertySnapshot(iso = 3200, isoAuto = true, codec = "H.265 10-bit MOV",
            captureSelector = "video")
        assertEquals("A3200", nikonCommonReadoutLabel(auto, properties))
        assertEquals("Auto", nikonCommonReadoutLabel(auto, properties.copy(iso = null)))
        assertEquals("800", nikonCommonReadoutLabel(SettingValue.Iso(ISOValue.Manual(800)), properties))
        assertNull(nikonCommonReadoutLabel(null, properties))
    }

    @Test
    fun `the image area tag leads the common recording label, as the body shows it`() {
        // Twin of the Swift NikonRecordingFormatLabelTests vectors.
        assertEquals("[FX] 6K · 25p", nikonRecordingFormatLabel("6K · 25p", imageArea = "FX"))
        assertEquals("[DX] 4K · 50p", nikonRecordingFormatLabel("4K · 50p", imageArea = "DX"))
        assertEquals("4K · 50p", nikonRecordingFormatLabel("4K · 50p", imageArea = null))
        assertNull(nikonRecordingFormatLabel(null, imageArea = "FX"))
    }

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
        assertEquals("25", readouts.framesPerSecond, "A5-09: the shared label never invents decimals")
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
        // The session's typed power for a raw BatteryLevel, read by the shared live chrome.
        fun sessionBatteryReading(rawLevel: Int?, externalPower: Boolean?) = cameraPowerReading(
            NikonCameraBatteryGauge.gauge(rawLevel ?: 0).powerStatus.copy(externalPower =
                externalPower?.let { ObservedValue(it, ObservationOrigin.CAMERA_REPORTED, null) } ?: ObservedValue.unknown))
        // A5-01, #303: BatteryLevel only carries 1/20/40/60/80/100, so "60%" claimed a precision
        // the body never sent (it reads 60 for anything from 40 to 59 percent).
        val sixty = requireNotNull(sessionBatteryReading(60, externalPower = true))
        assertNull(sixty.percent)
        assertEquals(3, sixty.bars)
        assertEquals(5, sixty.barCount)
        assertTrue(sixty.camera)
        assertEquals(true, sixty.charging)
        assertFalse(sixty.warning)
        assertFalse(sixty.exhausted)
        // An off-step value rounds up to the step it sits under; two bars warns.
        val low = requireNotNull(sessionBatteryReading(39, externalPower = null))
        assertEquals(2, low.bars)
        assertTrue(low.warning)
        // The blinking shutter-disabled step pulses.
        val critical = requireNotNull(sessionBatteryReading(1, externalPower = false))
        assertEquals(1, critical.bars)
        assertTrue(critical.exhausted)
        // An unread battery is absent, never an empty red cell, unless the body reports external
        // power: then the pill reads EXT with the bolt, as before the shared surface (ZAA-304).
        val external = requireNotNull(sessionBatteryReading(null, externalPower = true))
        assertNull(external.bars)
        assertNull(external.percent)
        assertEquals(true, external.externalPower)
        assertNull(sessionBatteryReading(0, externalPower = null))
        assertNull(sessionBatteryReading(null, externalPower = false))
    }

    @Test
    fun `the FORMAT readout says Format in movie and photo mode like iOS`() {
        // Z-ANDROID-FORMAT-TITLE (Root ruling): iOS titles the readout "Format" in both modes.
        assertEquals("Format", MONITOR_FORMAT_READOUT_TITLE)
    }

    @Test
    fun `a storage tap steps free space, free percentage, then the estimated time`() {
        // Hardware pass 3.4 (Z + ZR): the tap skipped the percentage although the card reports a
        // capacity. The shared live surface (Pocket, Insta) steps free, percent, time; iOS twin
        // `LiveMediaReadout.videoForms`.
        val card = com.opencapture.opencine.media.StorageReadout(595_840_000_000L, 1_024_000_000_000L)
        assertEquals(listOf("595.84 GB", "58%", "~51 Min"), liveMediaForms(card, "~51 Min", portrait = false))
        assertEquals(listOf("596GB", "58%", "~51 Min"), liveMediaForms(card, "~51 Min", portrait = true))
        assertEquals(listOf("595.84 GB", "58%"), liveMediaForms(card, null, portrait = false))
        val noCapacity = com.opencapture.opencine.media.StorageReadout(595_840_000_000L, null)
        assertEquals(listOf("595.84 GB", "~51 Min"), liveMediaForms(noCapacity, "~51 Min", portrait = false))
        assertEquals(listOf("\u2014"), liveMediaForms(null, null, portrait = false))
        val relayed = com.opencapture.opencine.nikon.MediaStatus(596, 58, 51, freeBytes = 595_840_000_000L)
        assertEquals(listOf("595.84 GB", "58%", "~51 Min"), relayedMediaForms(relayed, portrait = false))
        assertEquals(listOf("596GB", "58%", "~51 Min"), relayedMediaForms(relayed, portrait = true))
    }
}

