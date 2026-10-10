package com.opencapture.openzcine

import com.opencapture.opencine.appkit.MonitorCaptureChoice
import com.opencapture.opencine.appkit.MonitorCaptureField
import com.opencapture.opencine.core.ISOValue
import com.opencapture.opencine.core.SettingKey
import com.opencapture.opencine.core.SettingValue
import com.opencapture.opencine.cameracontrols.LadderWrite
import com.opencapture.opencine.nikon.CameraControl
import com.opencapture.opencine.nikon.CodecBitDepthOption
import com.opencapture.opencine.vocabulary.CaptureLock
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNotNull
import kotlin.test.assertNull
import kotlin.test.assertTrue

class LadderPickerTest {
    @Test
    fun dualBaseIsoKeepsMarkedValuesAndWritesTheBaseBeforeTheIso() {
        val picker = picker(
            MonitorPickerKind.ISO,
            mode("Low Base", CameraControl.ISO, "800", listOf("800", "1000"), detail = "800 / 4000",
                activate = request(CameraControl.BASE_ISO, "Low", listOf("Low", "High")),
                marked = setOf("800")),
            mode("High Base", CameraControl.ISO, "3200", listOf("3200", "6400"),
                activate = request(CameraControl.BASE_ISO, "High", listOf("Low", "High")),
                marked = setOf("3200")),
        )
        val sheet = videoLadderPresentation(picker)
        assertEquals(listOf("Low Base", "High Base"), sheet.tabs.map { it.label })
        assertEquals("800 / 4000", sheet.tabs[0].detail)
        assertEquals(setOf("800"), sheet.tabs[0].ladder.marked)
        assertEquals(CameraControl.BASE_ISO, sheet.tabs[0].activate?.key)
        assertEquals("Low", sheet.tabs[0].activate?.value)
        assertTrue(sheet.tabs[0].applyOnActivate)
        assertNull(sheet.lock)
    }

    @Test
    fun autoIsoLocksOnlyTheDrum() {
        val picker = picker(
            MonitorPickerKind.ISO,
            mode("Auto On", CameraControl.ISO, "800", listOf("800")),
            mode("Auto Off", CameraControl.ISO, "800", listOf("800")),
            drumLocked = true,
            drumBanner = "ISO is automatic",
        )
        val sheet = videoLadderPresentation(picker)
        assertEquals(CaptureLock.AUTO, sheet.lock)
        assertFalse(sheet.lock!!.freezesSheet)
        assertEquals("ISO is automatic", sheet.lockBanner)
        assertTrue(sheet.tabs[0].applyOnActivate)
    }

    @Test
    fun shutterLockFreezesTheSheetAndDoesNotRewriteTheShutterOnTabChange() {
        val picker = picker(
            MonitorPickerKind.SHUTTER,
            mode("Angle", CameraControl.SHUTTER, "180", listOf("90", "180"),
                activate = request(CameraControl.SHUTTER_MODE, "Angle", listOf("Angle", "Speed"))),
            mode("Speed", CameraControl.SHUTTER, "1/50", listOf("1/50", "1/100"),
                activate = request(CameraControl.SHUTTER_MODE, "Speed", listOf("Angle", "Speed"))),
            interactionLocked = true,
            banner = "Shutter locked on camera",
        )
        val sheet = videoLadderPresentation(picker)
        assertEquals(CaptureLock.CAMERA_CONTROL, sheet.lock)
        assertTrue(sheet.lock!!.freezesSheet)
        assertFalse(sheet.tabs[0].applyOnActivate)
        assertEquals(CameraControl.SHUTTER_MODE, sheet.tabs[1].activate?.key)
        assertEquals("Speed", sheet.tabs[1].activate?.value)
    }

    @Test
    fun photoModeDisablesTheUserBankTabAndDriveTimersKeepTheShotRow() {
        val modeSheet = videoLadderPresentation(
            picker(
                MonitorPickerKind.MODE,
                mode("Mode", CameraControl.EXPOSURE_MODE, "P", listOf("Auto", "P", "U1"), applyOnActivate = false),
                mode(
                    "U Mode", CameraControl.STILL_USER_MODE_PROGRAM, "P", listOf("P", "S", "A", "M"),
                    applyOnActivate = false, disabled = true,
                ),
            ),
        )
        assertFalse(modeSheet.tabs[0].disabled)
        assertTrue(modeSheet.tabs[1].disabled)
        assertFalse(modeSheet.tabs[1].applyOnActivate)
        assertEquals(CameraControl.STILL_USER_MODE_PROGRAM, modeSheet.tabs[1].key)
        assertNull(modeSheet.tabs[0].field)

        val drivePicker = picker(
            MonitorPickerKind.DRIVE,
            mode(
                "Drive", CameraControl.STILL_DRIVE, "Single", listOf("Single", "Continuous L"),
                applyOnActivate = false, disabled = true,
            ),
            mode(
                "Built-in Timer", CameraControl.STILL_DRIVE, "On", listOf("Off", "On"),
                applyOnActivate = false, showsTimerShots = true,
            ),
            mode(
                "App-timer", CameraControl.STILL_DRIVE, "Off", StillPickerPolicy.APP_TIMER_OPTIONS,
                applyOnActivate = false, showsTimerShots = true,
            ),
        )
        val drive = videoLadderPresentation(drivePicker)
        assertTrue(drive.tabs[0].disabled)
        assertFalse(ladderShowsTimerShots(drivePicker, drive.tabs[0]))
        assertTrue(ladderShowsTimerShots(drivePicker, drive.tabs[1]))
        assertTrue(ladderShowsTimerShots(drivePicker, drive.tabs[2]))
        val write = requestForLadderWrite(drivePicker, LadderWrite(CameraControl.STILL_DRIVE, "5s"))
        assertNotNull(write)
        assertTrue("5s" in write.options)
        assertFalse("Single" in write.options)

        val meter = videoLadderPresentation(
            picker(
                MonitorPickerKind.METER,
                mode("METER", CameraControl.STILL_METER, "Matrix", listOf("Matrix", "Spot")),
            ),
        )
        assertEquals(listOf("Matrix", "Spot"), meter.tabs.single().ladder.values)
        assertNull(meter.tabs.single().field)
    }

    @Test
    fun kelvinGrowsAndStepsLandWhilePresetUsesTheCoreField() {
        val field = MonitorCaptureField(
            key = SettingKey.WHITE_BALANCE,
            title = "WB",
            selection = SettingValue.WhiteBalance(com.opencapture.opencine.core.WhiteBalanceValue.Preset("Sunny")),
            choices = listOf(
                MonitorCaptureChoice(SettingValue.WhiteBalance(com.opencapture.opencine.core.WhiteBalanceValue.Preset("Sunny")), "Sunny"),
                MonitorCaptureChoice(SettingValue.WhiteBalance(com.opencapture.opencine.core.WhiteBalanceValue.Kelvin(5560)), "5560K"),
            ),
            editor = null,
        )
        val picker = picker(
            MonitorPickerKind.WHITE_BALANCE,
            mode("Kelvin", CameraControl.WHITE_BALANCE, "5560K", listOf("5560K", "5880K")),
            mode("Preset", CameraControl.WHITE_BALANCE, "Sunny", listOf("Sunny", "Cloudy")),
            mode("Tint", CameraControl.WHITE_BALANCE_TINT, "Neutral", listOf("Neutral")),
        )
        val sheet = videoLadderPresentation(picker, field)
        val kelvin = sheet.tabs[0]
        assertNull(kelvin.field)
        assertEquals(listOf("5550K", "5560K"), kelvin.values?.invoke("5550K")?.filter { it == "5550K" || it == "5560K" })
        val steps = kelvin.steps?.invoke("5560K")
        assertNotNull(steps)
        assertEquals("\u221210", steps.first.label)
        assertEquals("5550K", steps.first.value)
        assertTrue(steps.first.lands)
        assertEquals("5570K", steps.second.value)
        assertNotNull(sheet.tabs[1].field)
        assertEquals(listOf("Sunny"), sheet.tabs[1].field?.choices?.map { it.label })
        val tint = sheet.tabs[2]
        assertNotNull(tint.tint)
        assertEquals(0, tint.tint?.greenMagenta)
        assertEquals(0, tint.tint?.amberBlue)
        assertFalse(tint.applyOnActivate)
        assertNull(tint.field)
    }

    @Test
    fun focusTabsDoNotWriteOnActivation() {
        val picker = picker(
            MonitorPickerKind.FOCUS,
            mode("AF Mode", CameraControl.FOCUS_MODE, "AF-C", listOf("AF-S", "AF-C", "MF")),
            mode("Area", CameraControl.FOCUS_AREA, "Wide", listOf("Wide", "Subject")),
            mode("Subject", CameraControl.FOCUS_SUBJECT, "Auto", listOf("Auto", "People")),
        )
        val sheet = videoLadderPresentation(picker)
        assertTrue(sheet.tabs.all { !it.applyOnActivate && it.field == null && it.steps == null })
        assertEquals(CameraControl.FOCUS_AREA, sheet.tabs[1].key)
    }

    @Test
    fun codecBitDepthIsTwoStepsThatDoNotLand() {
        val depth = listOf(
            CodecBitDepthOption("H.265", "8-bit", "H.265 8-bit"),
            CodecBitDepthOption("H.265", "10-bit", "H.265 10-bit"),
        )
        val codec = mode("Codec", CameraControl.CODEC, "H.265", listOf("H.264", "H.265"))
            .copy(request = request(CameraControl.CODEC, "H.265", listOf("H.264", "H.265")).copy(
                bitDepths = depth,
                bitDepthSelection = "10-bit",
            ))
        val sheet = videoLadderPresentation(picker(MonitorPickerKind.CODEC, codec))
        val steps = sheet.tabs.single().steps?.invoke("H.265")
        assertNotNull(steps)
        assertEquals("8-bit" to "H.265 8-bit", steps.first.label to steps.first.value)
        assertEquals("10-bit" to "H.265 10-bit", steps.second.label to steps.second.value)
        assertFalse(steps.first.lands)
        assertFalse(steps.first.selected)
        assertTrue(steps.second.selected)
        assertNull(sheet.tabs.single().steps?.invoke("H.264"))
    }

    @Test
    fun resolutionHasNoStepsAndIrisUsesTheCoreField() {
        val resolution = videoLadderPresentation(
            picker(MonitorPickerKind.RESOLUTION, mode("Resolution", CameraControl.RESOLUTION_FRAMERATE, "4K 24p", listOf("4K 24p", "4K 30p"))),
        )
        assertNull(resolution.tabs.single().steps)
        assertNull(resolution.tabs.single().field)
        val irisField = MonitorCaptureField(
            key = SettingKey.APERTURE,
            title = "IRIS",
            selection = null,
            choices = listOf(MonitorCaptureChoice(SettingValue.Aperture(2.8), "f/2.8")),
            editor = null,
        )
        val iris = videoLadderPresentation(
            picker(MonitorPickerKind.IRIS, mode("Iris", CameraControl.IRIS, "f/2.8", listOf("f/2.8", "f/4"))),
            irisField,
        )
        assertNotNull(iris.tabs.single().field)
        assertTrue(ladderUsesCoreDrum(MonitorPickerKind.IRIS, irisMode()))
    }

    @Test
    fun aFineKelvinWriteStillFindsTheWhiteBalanceRequest() {
        val picker = picker(
            MonitorPickerKind.WHITE_BALANCE,
            mode("Kelvin", CameraControl.WHITE_BALANCE, "5560K", listOf("5560K")),
        )
        val write = com.opencapture.opencine.cameracontrols.LadderWrite(CameraControl.WHITE_BALANCE, "5550K")
        assertEquals(CameraControl.WHITE_BALANCE, requestForLadderWrite(picker, write)?.control)
    }

    private fun irisMode() = mode("Iris", CameraControl.IRIS, "f/2.8", listOf("f/2.8"))

    private fun picker(
        kind: MonitorPickerKind,
        vararg modes: MonitorPickerModePresentation,
        interactionLocked: Boolean = false,
        banner: String? = null,
        drumLocked: Boolean = false,
        drumBanner: String? = null,
    ) = MonitorPickerPresentation(
        kind = kind,
        title = kind.name,
        subtitle = "video",
        modes = modes.toList(),
        interactionLocked = interactionLocked,
        lockBanner = banner,
        drumInteractionLocked = drumLocked,
        drumLockBanner = drumBanner,
    )

    private fun mode(
        label: String,
        control: CameraControl,
        current: String,
        options: List<String>,
        detail: String? = null,
        activate: CommandControlRequest? = null,
        marked: Set<String> = emptySet(),
        applyOnActivate: Boolean = true,
        disabled: Boolean = false,
        showsTimerShots: Boolean = false,
    ) = MonitorPickerModePresentation(
        label = label,
        request = request(control, current, options),
        detail = detail,
        activateRequest = activate,
        markedValues = marked,
        applyValueOnActivate = applyOnActivate,
        disabled = disabled,
        showsTimerShots = showsTimerShots,
    )

    private fun request(control: CameraControl, current: String, options: List<String>) = CommandControlRequest(
        title = control.name,
        control = control,
        currentValue = current,
        options = options,
    )
}
