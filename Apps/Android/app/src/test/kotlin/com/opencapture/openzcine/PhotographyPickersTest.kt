package com.opencapture.openzcine

import com.opencapture.openzcine.core.CameraControl
import com.opencapture.openzcine.core.CameraControlCapabilities
import com.opencapture.openzcine.core.CameraPropertySnapshot
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNotNull
import kotlin.test.assertNull
import kotlin.test.assertTrue

/** JVM coverage for the photography picker presentations and stills policy. */
class PhotographyPickersTest {
    private val snapshot =
        CameraPropertySnapshot(
            iso = 800,
            isoAuto = false,
            exposureMode = "M",
            shutterSpeed = "1/250",
            iris = "f/2.8",
            whiteBalanceMode = "Auto",
            captureSelector = "photo",
            stillCaptureMode = "Single",
            imageSize = "Size L",
            compression = "RAW+JPEG Fine",
            meteringMode = "Matrix",
            pictureControl = "Standard",
            userModeProgram = null,
            imageArea = "FX",
            rawCompression = "High efficiency",
        )

    private fun settings(
        properties: CameraPropertySnapshot = snapshot,
        timerDelay: Int = 0,
    ) = photographyCaptureSettings(
        properties = properties,
        wbPicker = null,
        photoTimerDelaySeconds = timerDelay,
    )

    @Test
    fun `strip renders the iOS tile order with pinned widths and live values`() {
        val tiles = settings()

        assertEquals(
            listOf(
                MonitorPickerKind.MODE, MonitorPickerKind.ISO, MonitorPickerKind.SHUTTER,
                MonitorPickerKind.IRIS, MonitorPickerKind.DRIVE, MonitorPickerKind.FOCUS,
                MonitorPickerKind.WHITE_BALANCE, MonitorPickerKind.METER,
                MonitorPickerKind.PROFILE,
            ),
            tiles.map { it.kind },
        )
        assertEquals(
            listOf("Auto", "25600", "1/16000", "f/2.8", "Single", "Wide-L", "5560K", "Matrix", "Auto"),
            tiles.map { it.widestValue },
        )
        // Every tile except the caller-supplied WB opens a picker in M.
        assertTrue(tiles.filter { it.kind != MonitorPickerKind.WHITE_BALANCE }.all { it.picker != null })
    }

    @Test
    fun `iso picker seeds auto and manual tabs from camera truth`() {
        val manual = settings().first { it.kind == MonitorPickerKind.ISO }.picker
        assertNotNull(manual)
        // isoAuto false opens Manual (iOS stillISOPickerModeIndex).
        assertEquals(1, manual.initialModeIndex)
        assertEquals("Auto", manual.modes[0].label)
        assertTrue(manual.modes[0].drumLocked)
        assertEquals("On", manual.modes[0].activateRequest?.currentValue)
        assertFalse(manual.modes[0].applyValueOnActivate)
        assertEquals("Off", manual.modes[1].activateRequest?.currentValue)
        assertTrue(manual.modes[1].applyValueOnActivate)
        assertFalse(manual.modes[1].disabled)
        assertEquals("800", manual.modes[1].request.currentValue)

        val auto =
            settings(snapshot.copy(isoAuto = true, iso = 51200))
                .first { it.kind == MonitorPickerKind.ISO }.picker
        assertNotNull(auto)
        assertEquals(0, auto.initialModeIndex)
        // The live Auto value joins the ladder so the locked drum can centre on it.
        assertTrue("51200" in auto.modes[0].request.options)

        // Full-auto program: Manual grays out (iOS pickerModeDisabled).
        val fullAuto =
            settings(snapshot.copy(exposureMode = "Auto"))
                .first { it.kind == MonitorPickerKind.ISO }.picker
        assertNotNull(fullAuto)
        assertTrue(fullAuto.modes[1].disabled)
    }

    @Test
    fun `mode picker gates the U-bank inner program to the banks`() {
        val outside = settings().first { it.kind == MonitorPickerKind.MODE }.picker
        assertNotNull(outside)
        assertEquals(listOf("Mode", "U Mode"), outside.modes.map { it.label })
        assertTrue(outside.modes[1].disabled)
        assertEquals(CameraControl.EXPOSURE_MODE, outside.modes[0].request.control)
        assertEquals(
            CameraControl.STILL_USER_MODE_PROGRAM,
            outside.modes[1].request.control,
        )

        val inBank =
            settings(snapshot.copy(exposureMode = "U2", userModeProgram = "A"))
                .first { it.kind == MonitorPickerKind.MODE }.picker
        assertNotNull(inBank)
        assertFalse(inBank.modes[1].disabled)
        assertEquals("A", inBank.modes[1].request.currentValue)
    }

    @Test
    fun `shutter and iris gray outside their programs including U banks`() {
        // M allows both.
        assertTrue(settings().first { it.kind == MonitorPickerKind.SHUTTER }.picker != null)
        assertTrue(settings().first { it.kind == MonitorPickerKind.IRIS }.picker != null)

        // A: aperture stays, shutter grays (live readout, no picker).
        val aperturePriority = settings(snapshot.copy(exposureMode = "A"))
        val shutterTile = aperturePriority.first { it.kind == MonitorPickerKind.SHUTTER }
        assertNull(shutterTile.picker)
        assertTrue(shutterTile.dimmed)
        assertEquals("1/250", shutterTile.value)
        assertFalse(aperturePriority.first { it.kind == MonitorPickerKind.IRIS }.dimmed)

        // S: shutter stays, iris grays.
        val shutterPriority = settings(snapshot.copy(exposureMode = "S"))
        assertNull(shutterPriority.first { it.kind == MonitorPickerKind.IRIS }.picker)
        assertNotNull(shutterPriority.first { it.kind == MonitorPickerKind.SHUTTER }.picker)

        // A U bank resolves through its inner program (U1 running as S).
        val bank = settings(snapshot.copy(exposureMode = "U1", userModeProgram = "S"))
        assertNull(bank.first { it.kind == MonitorPickerKind.IRIS }.picker)
        assertNotNull(bank.first { it.kind == MonitorPickerKind.SHUTTER }.picker)
    }

    @Test
    fun `shutter picker prefers the camera speed enum over the ladder`() {
        val cameraEnum =
            snapshot.copy(
                controlCapabilities =
                    CameraControlCapabilities(shutterValues = listOf("1/125", "1/250", "1/500")),
            )
        val picker = settings(cameraEnum).first { it.kind == MonitorPickerKind.SHUTTER }.picker
        assertNotNull(picker)
        assertEquals(listOf("1/125", "1/250", "1/500"), picker.modes[0].request.options)
        assertEquals("1/250", picker.modes[0].request.currentValue)

        // Ladder fallback keeps Bulb and the whole-second forms.
        val fallback = settings().first { it.kind == MonitorPickerKind.SHUTTER }.picker
        assertNotNull(fallback)
        assertTrue("Bulb" in fallback.modes[0].request.options)
        assertTrue("30s" in fallback.modes[0].request.options)
    }

    @Test
    fun `drive picker mirrors the iOS timer tab exclusivity`() {
        val idle = settings().first { it.kind == MonitorPickerKind.DRIVE }.picker
        assertNotNull(idle)
        assertEquals(listOf("Drive", "Built-in Timer", "App-timer"), idle.modes.map { it.label })
        assertFalse(idle.modes[0].disabled)
        assertTrue(idle.modes[1].showsTimerShots)
        assertTrue(idle.modes[2].showsTimerShots)
        // Quick and Self-timer never appear in the Drive drum.
        assertFalse("Quick" in idle.modes[0].request.options)
        assertFalse("Self-timer" in idle.modes[0].request.options)

        // Body timer engaged: Drive + App-timer gray, Built-in reads On.
        val bodyTimer =
            settings(snapshot.copy(stillCaptureMode = "Self-timer"))
                .first { it.kind == MonitorPickerKind.DRIVE }.picker
        assertNotNull(bodyTimer)
        assertTrue(bodyTimer.modes[0].disabled)
        assertEquals("On", bodyTimer.modes[1].request.currentValue)
        assertTrue(bodyTimer.modes[2].disabled)

        // App timer armed: Built-in grays, App reads its delay.
        val appTimer =
            settings(timerDelay = 5).first { it.kind == MonitorPickerKind.DRIVE }.picker
        assertNotNull(appTimer)
        assertTrue(appTimer.modes[1].disabled)
        assertEquals("5s", appTimer.modes[2].request.currentValue)
    }

    @Test
    fun `focus picker routes three independent stills controls`() {
        val picker = settings().first { it.kind == MonitorPickerKind.FOCUS }.picker
        assertNotNull(picker)
        assertEquals(
            listOf(
                CameraControl.STILL_FOCUS_MODE,
                CameraControl.STILL_FOCUS_AREA,
                CameraControl.STILL_FOCUS_SUBJECT,
            ),
            picker.modes.map { it.request.control },
        )
        assertTrue(picker.modes.none { it.applyValueOnActivate })
    }

    @Test
    fun `top bar pickers cover size tabs and the quality pair`() {
        val pickers = photographyTopBarPickers(snapshot)

        val size = pickers.getValue(MonitorPickerKind.SIZE)
        assertEquals(listOf("Area", "Size"), size.modes.map { it.label })
        assertEquals(CameraControl.STILL_IMAGE_AREA, size.modes[0].request.control)
        assertEquals("FX", size.modes[0].request.currentValue)
        assertEquals(CameraControl.STILL_IMAGE_SIZE, size.modes[1].request.control)
        assertEquals("Size L", size.modes[1].request.currentValue)

        // Camera-reported resolution strings take over the Size drum verbatim.
        val cameraSizes =
            photographyTopBarPickers(
                snapshot.copy(
                    imageSize = "6048x4032",
                    controlCapabilities =
                        CameraControlCapabilities(
                            imageSizes = listOf("6048x4032", "4528x3024", "3024x2016"),
                        ),
                ),
            ).getValue(MonitorPickerKind.SIZE)
        assertEquals(
            listOf("6048x4032", "4528x3024", "3024x2016"),
            cameraSizes.modes[1].request.options,
        )
        assertEquals("6048x4032", cameraSizes.modes[1].request.currentValue)

        val quality = pickers.getValue(MonitorPickerKind.QUALITY)
        assertEquals(CameraControl.STILL_QUALITY, quality.modes[0].request.control)
        assertEquals("RAW+JPEG Fine", quality.modes[0].request.currentValue)
        assertTrue(MonitorPickerKind.SIZE.isTopBarPicker())
        assertTrue(MonitorPickerKind.QUALITY.isTopBarPicker())
    }

    @Test
    fun `quality config decomposes and recomposes the camera labels`() {
        assertEquals(
            StillQualityConfig(rawEnabled = true, tier = "Off", starred = false),
            StillQualityConfig.parse("RAW"),
        )
        assertEquals(
            StillQualityConfig(rawEnabled = true, tier = "Fine", starred = false),
            StillQualityConfig.parse("RAW+JPEG Fine"),
        )
        assertEquals(
            StillQualityConfig(rawEnabled = false, tier = "Normal", starred = true),
            StillQualityConfig.parse("JPEG Normal★"),
        )
        assertNull(StillQualityConfig.parse("TIFF"))
        assertNull(StillQualityConfig.parse(null))

        // Round trips (the write path's label form).
        for (label in listOf(
            "RAW", "RAW+JPEG Fine", "RAW+JPEG Basic★", "JPEG Fine★", "JPEG Basic",
        )) {
            assertEquals(label, StillQualityConfig.parse(label)?.compressionLabel())
        }
        // The unwritable both-off state has no label.
        assertNull(
            StillQualityConfig(rawEnabled = false, tier = "Off", starred = false)
                .compressionLabel(),
        )
    }

    @Test
    fun `photo timer labels round trip`() {
        assertEquals("Off", photoTimerLabel(0))
        assertEquals("5s", photoTimerLabel(5))
        assertEquals(0, photoTimerSeconds("Off"))
        assertEquals(10, photoTimerSeconds("10s"))
    }
}
