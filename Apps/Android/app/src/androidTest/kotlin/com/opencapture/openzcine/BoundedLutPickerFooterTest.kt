package com.opencapture.openzcine

import android.graphics.Bitmap
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.size
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.Rect
import androidx.compose.ui.graphics.asAndroidBitmap
import androidx.compose.ui.layout.positionInRoot
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.test.ExperimentalTestApi
import androidx.compose.ui.test.assertCountEquals
import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.captureToImage
import androidx.compose.ui.test.click
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.test.onAllNodesWithText
import androidx.compose.ui.test.performClick
import androidx.compose.ui.test.onAllNodesWithTag
import androidx.compose.ui.test.onAllNodesWithContentDescription
import androidx.compose.ui.test.onNodeWithContentDescription
import androidx.compose.ui.test.onNodeWithTag
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.onRoot
import androidx.compose.ui.test.performTouchInput
import androidx.compose.ui.unit.dp
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import androidx.test.uiautomator.UiDevice
import com.opencapture.opencine.cameracontrols.LUTPicker
import com.opencapture.opencine.cameracontrols.LUTSplitComparisonBar
import com.opencapture.opencine.cameracontrols.LutPickerEntry
import com.opencapture.opencine.cameracontrols.LutPickerLibrary
import java.io.File
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith

/** SIMULATED libraries, actual bounded landscape Compose measure, paint and pointer dispatch. */
@OptIn(ExperimentalTestApi::class)
@RunWith(AndroidJUnit4::class)
class BoundedLutPickerFooterTest {
    @Test
    fun productionNikonLibrariesUseSharedTabsAndRetainHostImportAction() {
        val assists = idleNikonAssists()
        var imports = 0
        composeRule.setContent {
            Box(Modifier.size(360.dp, 260.dp)) {
                NikonLutOptions(assists, null, onOpenRedDownload = {},
                    onRequestLutImport = { imports += 1 }, includesComparison = false)
            }
        }
        composeRule.onNodeWithTag("monitor.lut.tab.Built-in").assertIsDisplayed()
        composeRule.onNodeWithTag("monitor.lut.tab.RED").assertIsDisplayed()
        composeRule.onNodeWithTag("monitor.lut.tab.Custom").performClick()
        composeRule.onNodeWithText("Import .cube").performClick()
        composeRule.runOnIdle { assertEquals(1, imports) }
        composeRule.onAllNodesWithText("Exposure").assertCountEquals(0)
        composeRule.onAllNodesWithText("50/50").assertCountEquals(0)
    }

    @Test
    fun productionNikonStandaloneComparisonHasOneControlAndNoExposure() {
        val assists = idleNikonAssists()
        composeRule.setContent {
            OpenZCineTheme {
                Box(Modifier.size(640.dp, 300.dp)) {
                    NikonLutOptions(assists, null, onOpenRedDownload = {},
                        onRequestLutImport = {}, includesComparison = true)
                }
            }
        }
        composeRule.onAllNodesWithText("50/50").assertCountEquals(1)
        composeRule.onAllNodesWithContentDescription("Exposure compensation in stops").assertCountEquals(0)
        composeRule.onNodeWithText("50/50").performClick()
        composeRule.runOnIdle { assertTrue(assists.shared.splitComparison) }
        composeRule.onNodeWithText("Top / Bottom").performClick()
        composeRule.runOnIdle { assertTrue(!assists.shared.splitVertical) }
    }

    @get:Rule val composeRule = createComposeRule()
    private val instrumentation = InstrumentationRegistry.getInstrumentation()
    private val device = UiDevice.getInstance(instrumentation)

    @Before fun landscape() {
        device.setOrientationLeft()
        composeRule.waitUntil(5_000) { device.displayWidth > device.displayHeight }
    }

    @After fun restoreOrientation() { device.unfreezeRotation() }

    @Test fun shortBoundedSheetKeepsOneCompleteFooterInteractiveWhenItGrows() = proveFooter(220, false)
    @Test fun boundedSheetReservesTheActualExposureAndSplitFooter() = proveFooter(300, true)

    private fun proveFooter(heightDp: Int, exposure: Boolean) {
        var split by mutableStateOf(false)
        var vertical by mutableStateOf(true)
        var stops by mutableStateOf(0.0)
        val entries = listOf(LutPickerEntry("first", "First"), LutPickerEntry("second", "Second"))
        var selected by mutableStateOf("first")
        composeRule.setContent {
            OpenZCineTheme {
                Box(Modifier.size(640.dp, heightDp.dp).testTag("bounded.picker.parent")) {
                    LUTPicker(listOf(LutPickerLibrary("SIMULATED", entries, true, selected,
                        onSelect = { selected = it.id }, caption = "SIMULATED catalog")),
                        modifier = Modifier.testTag("bounded.picker.body"), embedded = false,
                        footer = {
                            LUTSplitComparisonBar(split, vertical, if (exposure) stops else null,
                                onToggleSplit = { split = !split }, onSplitVertical = { vertical = it },
                                onExposure = { stops = it },
                                modifier = Modifier.heightIn(min = 44.dp).testTag("bounded.picker.footer"))
                        })
                }
            }
        }
        assertCompleteFooter(heightDp)
        composeRule.onNodeWithText("50/50").assertIsDisplayed().performTouchInput { click() }
        composeRule.runOnIdle { assertTrue("Real pointer enables comparison", split) }
        assertCompleteFooter(heightDp)
        composeRule.onNodeWithText("Top / Bottom").assertIsDisplayed().performTouchInput { click() }
        composeRule.runOnIdle { assertTrue("Real pointer changes comparison orientation", !vertical) }
        assertCompleteFooter(heightDp)
        if (exposure) {
            composeRule.onNodeWithContentDescription("Exposure compensation in stops")
                .assertIsDisplayed().performTouchInput { click(centerRight) }
            composeRule.runOnIdle { assertTrue("The actual slider changes input stops", stops > 0.0 && stops <= 3.0) }
        }
        val image = composeRule.onRoot().captureToImage().asAndroidBitmap()
        File(instrumentation.targetContext.getExternalFilesDir(null), "f11-bounded-picker-$heightDp.png")
            .outputStream().use { image.compress(Bitmap.CompressFormat.PNG, 100, it) }
        composeRule.onNodeWithText("50/50").performTouchInput { click() }
        composeRule.runOnIdle { assertTrue("Real pointer disables comparison", !split) }
        assertCompleteFooter(heightDp)
    }

    private fun rawBounds(tag: String): Rect {
        val coordinates = composeRule.onNodeWithTag(tag, useUnmergedTree = true)
            .fetchSemanticsNode().layoutInfo.coordinates
        val position = coordinates.positionInRoot()
        return Rect(position.x, position.y, position.x + coordinates.size.width, position.y + coordinates.size.height)
    }

    private fun assertCompleteFooter(heightDp: Int) {
        composeRule.onAllNodesWithTag("bounded.picker.footer", useUnmergedTree = true).assertCountEquals(1)
        val parent = rawBounds("bounded.picker.parent")
        val footer = rawBounds("bounded.picker.footer")
        val painted = composeRule.onNodeWithTag("bounded.picker.footer", useUnmergedTree = true)
            .fetchSemanticsNode().boundsInRoot
        val density = instrumentation.targetContext.resources.displayMetrics.density
        assertEquals("Actual bounded host height", heightDp * density, parent.height, 1f)
        assertTrue("Complete footer has a real area", footer.width > 0f && footer.height >= 44f * density - 1f)
        assertTrue("Footer top stays in bounded host", footer.top >= parent.top - 1f)
        assertTrue("Footer bottom stays in bounded host", footer.bottom <= parent.bottom + 1f)
        assertTrue("Footer sides stay in bounded host", footer.left >= parent.left - 1f && footer.right <= parent.right + 1f)
        assertEquals("Footer is fully painted vertically", footer.height, painted.height, 1f)
        assertEquals("Footer is fully painted horizontally", footer.width, painted.width, 1f)
    }
}
