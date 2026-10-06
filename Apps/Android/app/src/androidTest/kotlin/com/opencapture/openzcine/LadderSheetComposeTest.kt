package com.opencapture.openzcine

import android.graphics.Bitmap
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.size
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.asAndroidBitmap
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.captureToImage
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.test.onNodeWithContentDescription
import androidx.compose.ui.test.onNodeWithTag
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.performClick
import androidx.compose.ui.unit.dp
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import com.opencapture.monitorui.MonitorRect
import com.opencapture.opencine.cameracontrols.LocalViewportPortrait
import com.opencapture.opencine.nikon.CameraControl
import com.opencapture.opencine.nikon.CodecBitDepthOption
import java.io.File
import java.io.FileInputStream
import java.io.FileOutputStream
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith

/**
 * Video pickers on the shared ladder sheet: tabs, side steps, the tint pad and the lock line.
 * Landscape captures land in the app's external files under r2a/.
 */
@RunWith(AndroidJUnit4::class)
class LadderSheetComposeTest {
    @get:Rule
    val composeRule = createComposeRule()

    private val frame = MonitorRect(x = 24f, y = 24f, width = 480f, height = 320f)

    @Test
    fun kelvinStepsAndTintTabWriteTheHostKey() {
        val harness = harness()
        saveLegacy(harness, "wb", wb())
        show(harness, wb())
        composeRule.onNodeWithText("KELVIN").assertIsDisplayed()
        composeRule.onNodeWithText("PRESET").assertIsDisplayed()
        composeRule.onNodeWithText("TINT").assertIsDisplayed()
        composeRule.onNodeWithContentDescription("Decrease Kelvin by 10").performClick()
        save("wb-kelvin")
        composeRule.onNodeWithText("TINT").performClick()
        composeRule.onNodeWithContentDescription("Tint Neutral", substring = true).assertIsDisplayed()
        composeRule.runOnIdle {
            assertEquals(listOf(CameraControl.WHITE_BALANCE to "5550K"), harness.writes)
        }
        save("wb-tint")
    }

    @Test
    fun codecDepthsFlankTheRowAndDoNotReplaceIt() {
        val harness = harness()
        saveLegacy(harness, "codec", codec())
        show(harness, codec())
        composeRule.onNodeWithContentDescription("Record H.265 at 10-bit").performClick()
        composeRule.runOnIdle {
            assertEquals(listOf(CameraControl.CODEC to "H.265 10-bit"), harness.writes)
        }
        save("codec")
    }

    @Test
    fun shutterLockShowsTheBannerAndKeepsTheTabs() {
        val harness = harness()
        saveLegacy(harness, "shutter", shutter(locked = true))
        show(harness, shutter(locked = true))
        composeRule.onNodeWithText("Shutter locked on camera", substring = true).assertIsDisplayed()
        composeRule.onNodeWithText("ANGLE").assertIsDisplayed()
        composeRule.onNodeWithText("SPEED").assertIsDisplayed()
        composeRule.runOnIdle { assertTrue(harness.writes.isEmpty()) }
        save("shutter-locked")
    }

    @Test
    fun isoDetailAndAutoLockStayOnTheSharedTabs() {
        val harness = harness()
        saveLegacy(harness, "iso", iso(auto = true))
        show(harness, iso(auto = true))
        composeRule.onNodeWithText("800 / 4000").assertIsDisplayed()
        composeRule.onNodeWithText("ISO is automatic", substring = true).assertIsDisplayed()
        composeRule.onNodeWithText("AUTO OFF").assertIsDisplayed()
        save("iso-auto")
    }

    @Test
    fun focusAreaAndResolutionUseTheHorizontalSheet() {
        val harness = harness()
        saveLegacy(harness, "focus", focus())
        show(harness, focus())
        composeRule.onNodeWithText("Focus dial").assertIsDisplayed()
        composeRule.onNodeWithText("AREA").performClick()
        composeRule.runOnIdle { assertTrue(harness.writes.isEmpty()) }
        save("focus")
        saveLegacy(harness, "resolution", resolution())
        saveLegacy(harness, "iris", iris())
        show(harness, resolution())
        composeRule.onNodeWithText("RESOLUTION").assertIsDisplayed()
        save("resolution")
        show(harness, iris())
        composeRule.onNodeWithText("IRIS").assertIsDisplayed()
        save("iris")
    }

    /** One setContent for the whole test. The rule rejects a second call. */
    private class Harness {
        var legacy by mutableStateOf<MonitorPickerPresentation?>(null)
        var live by mutableStateOf<MonitorPickerPresentation?>(null)
        val writes = mutableListOf<Pair<CameraControl, String>>()
    }

    private fun harness(): Harness {
        val harness = Harness()
        composeRule.setContent {
            val legacy = harness.legacy
            val live = harness.live
            if (legacy != null) {
                Box(Modifier.testTag("legacy_sheet").size(480.dp, 320.dp)) {
                    PickerPanelBody(
                        picker = legacy,
                        frame = MonitorRect(0f, 0f, 480f, 320f),
                        controlsEnabled = true,
                        pendingControl = null,
                        feedback = null,
                        onSelect = { _, _ -> },
                        onDismiss = {},
                    )
                }
            }
            if (live != null) {
                CompositionLocalProvider(LocalViewportPortrait provides false) {
                    MonitorControlPickerPanel(
                        picker = live,
                        frame = frame,
                        controlsEnabled = true,
                        pendingControl = null,
                        feedback = null,
                        onSelect = { request, label -> harness.writes += request.control to label },
                        onDismiss = {},
                        slideFromTop = live.kind.isTopBarPicker(),
                        onToggleMfScrub = {},
                    )
                }
            }
        }
        return harness
    }

    private fun show(harness: Harness, picker: MonitorPickerPresentation) {
        composeRule.runOnIdle {
            harness.legacy = null
            harness.live = picker
        }
        composeRule.waitForIdle()
    }

    private fun save(name: String) {
        writePng(name, composeRule.onNodeWithTag("ladder_sheet").captureToImage())
    }

    /** The vertical accent drum, captured beside the sheet that replaces it. */
    private fun saveLegacy(harness: Harness, name: String, picker: MonitorPickerPresentation) {
        composeRule.runOnIdle {
            harness.live = null
            harness.legacy = picker
        }
        composeRule.waitForIdle()
        writePng("$name-before", composeRule.onNodeWithTag("legacy_sheet").captureToImage())
    }

    private fun writePng(name: String, image: androidx.compose.ui.graphics.ImageBitmap) {
        val dir = InstrumentationRegistry.getInstrumentation().targetContext.getExternalFilesDir("r2a")
        check(dir != null)
        val file = File(dir, "$name.png")
        FileOutputStream(file).use { out ->
            image.asAndroidBitmap().compress(Bitmap.CompressFormat.PNG, 100, out)
        }
        // executeShellCommandRw returns (stdout, stdin). The connected run uninstalls the app
        // and deletes external files, so the bytes also land on a path the host can pull.
        publish(name, file.readBytes())
    }

    private fun publish(name: String, bytes: ByteArray) {
        val automation = InstrumentationRegistry.getInstrumentation().uiAutomation
        val pipes = automation.executeShellCommandRw("sh")
        val stdin = FileOutputStream(pipes[1].fileDescriptor)
        stdin.write("mkdir -p /data/local/tmp/r2a\ncat > /data/local/tmp/r2a/$name.png\n".toByteArray())
        stdin.write(bytes)
        stdin.flush()
        pipes[1].close()
        FileInputStream(pipes[0].fileDescriptor).use { it.readBytes() }
        val listed = automation.executeShellCommand("wc -c /data/local/tmp/r2a/$name.png")
        val text = FileInputStream(listed.fileDescriptor).bufferedReader().readText()
        val count = text.trim().substringBefore(" ").toLongOrNull()
        check(count == bytes.size.toLong()) { "publish $name wrote $count of ${bytes.size}: $text" }
    }

    private fun wb() = MonitorPickerPresentation(
        kind = MonitorPickerKind.WHITE_BALANCE,
        title = "WB",
        subtitle = "Kelvin / preset / tint",
        modes = listOf(
            MonitorPickerModePresentation(
                label = "Kelvin",
                request = CommandControlRequest(title = "WB", control = CameraControl.WHITE_BALANCE, currentValue = "5560K", options = listOf("5560K", "5880K")),
            ),
            MonitorPickerModePresentation(
                label = "Preset",
                request = CommandControlRequest(title = "WB", control = CameraControl.WHITE_BALANCE, currentValue = "Sunny", options = listOf("Sunny", "Cloudy")),
            ),
            MonitorPickerModePresentation(
                label = "Tint",
                request = CommandControlRequest(title = "Tint", control = CameraControl.WHITE_BALANCE_TINT, currentValue = "Neutral", options = listOf("Neutral")),
            ),
        ),
    )

    private fun codec() = MonitorPickerPresentation(
        kind = MonitorPickerKind.CODEC,
        title = "CODEC",
        subtitle = "Recording codec",
        modes = listOf(
            MonitorPickerModePresentation(
                label = "Codec",
                request = CommandControlRequest(
                    title = "CODEC",
                    control = CameraControl.CODEC,
                    currentValue = "H.265",
                    options = listOf("H.264", "H.265"),
                    bitDepths = listOf(
                        CodecBitDepthOption("H.265", "8-bit", "H.265 8-bit"),
                        CodecBitDepthOption("H.265", "10-bit", "H.265 10-bit"),
                    ),
                    bitDepthSelection = "10-bit",
                ),
            ),
        ),
    )

    private fun shutter(locked: Boolean) = MonitorPickerPresentation(
        kind = MonitorPickerKind.SHUTTER,
        title = "SHUTTER",
        subtitle = "Angle / speed",
        modes = listOf(
            MonitorPickerModePresentation(
                label = "Angle",
                request = CommandControlRequest(title = "SHUTTER", control = CameraControl.SHUTTER, currentValue = "180", options = listOf("90", "180")),
                activateRequest = CommandControlRequest(title = "Mode", control = CameraControl.SHUTTER_MODE, currentValue = "Angle", options = listOf("Angle", "Speed")),
            ),
            MonitorPickerModePresentation(
                label = "Speed",
                request = CommandControlRequest(title = "SHUTTER", control = CameraControl.SHUTTER, currentValue = "1/50", options = listOf("1/50", "1/100")),
                activateRequest = CommandControlRequest(title = "Mode", control = CameraControl.SHUTTER_MODE, currentValue = "Speed", options = listOf("Angle", "Speed")),
            ),
        ),
        interactionLocked = locked,
        lockBanner = if (locked) "Shutter locked on camera. Hold anywhere to unlock" else null,
    )

    private fun iso(auto: Boolean) = MonitorPickerPresentation(
        kind = MonitorPickerKind.ISO,
        title = "ISO",
        subtitle = "Sensitivity",
        modes = listOf(
            MonitorPickerModePresentation(
                label = "Auto On",
                detail = "800 / 4000",
                request = CommandControlRequest(title = "ISO", control = CameraControl.ISO, currentValue = "800", options = listOf("400", "800", "1600")),
                markedValues = setOf("800"),
                applyValueOnActivate = false,
            ),
            MonitorPickerModePresentation(
                label = "Auto Off",
                request = CommandControlRequest(title = "ISO", control = CameraControl.ISO, currentValue = "800", options = listOf("400", "800", "1600")),
                applyValueOnActivate = false,
            ),
        ),
        drumInteractionLocked = auto,
        drumLockBanner = if (auto) "ISO is automatic" else null,
    )

    private fun focus() = MonitorPickerPresentation(
        kind = MonitorPickerKind.FOCUS,
        title = "FOCUS",
        subtitle = "Mode / area / subject",
        modes = listOf(
            MonitorPickerModePresentation(label = "AF Mode", request = CommandControlRequest(title = "FOCUS", control = CameraControl.FOCUS_MODE, currentValue = "AF-C", options = listOf("AF-S", "AF-C", "MF"))),
            MonitorPickerModePresentation(label = "Area", request = CommandControlRequest(title = "FOCUS", control = CameraControl.FOCUS_AREA, currentValue = "Wide", options = listOf("Wide", "Subject"))),
            MonitorPickerModePresentation(label = "Subject", request = CommandControlRequest(title = "FOCUS", control = CameraControl.FOCUS_SUBJECT, currentValue = "Auto", options = listOf("Auto", "People"))),
        ),
    )

    private fun iris() = MonitorPickerPresentation(
        kind = MonitorPickerKind.IRIS,
        title = "IRIS",
        subtitle = "Aperture",
        modes = listOf(
            MonitorPickerModePresentation(
                label = "Iris",
                request = CommandControlRequest(title = "IRIS", control = CameraControl.IRIS, currentValue = "f/2.8", options = listOf("f/2", "f/2.8", "f/4")),
            ),
        ),
    )

    private fun resolution() = MonitorPickerPresentation(
        kind = MonitorPickerKind.RESOLUTION,
        title = "RESOLUTION",
        subtitle = "Frame size",
        modes = listOf(
            MonitorPickerModePresentation(
                label = "Resolution",
                request = CommandControlRequest(title = "RESOLUTION", control = CameraControl.RESOLUTION_FRAMERATE, currentValue = "4K24", options = listOf("4K24", "4K30")),
            ),
        ),
    )
}
