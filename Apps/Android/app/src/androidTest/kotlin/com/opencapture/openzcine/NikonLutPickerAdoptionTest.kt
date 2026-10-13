package com.opencapture.openzcine

import android.content.Context
import android.graphics.Bitmap
import androidx.compose.foundation.layout.Column
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.ui.graphics.asAndroidBitmap
import androidx.compose.ui.test.ExperimentalTestApi
import androidx.compose.ui.test.captureToImage
import androidx.compose.ui.test.hasContentDescription
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.test.onNodeWithTag
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.onRoot
import androidx.compose.ui.test.performClick
import androidx.compose.ui.test.performTouchInput
import androidx.compose.ui.test.onNodeWithContentDescription
import androidx.compose.ui.test.click
import androidx.compose.ui.geometry.Offset
import androidx.test.core.app.ApplicationProvider
import androidx.test.ext.junit.runners.AndroidJUnit4
import com.opencapture.monitorui.MonitorAssistTool
import com.opencapture.opencine.appkit.MonitorControlModel
import com.opencapture.opencine.nikon.CameraIdentity
import com.opencapture.opencine.nikon.FakeCameraSession
import com.opencapture.opencine.nikon.NikonOpenCineSession
import com.opencapture.openzcine.settings.OperatorSettings
import java.io.File
import org.junit.Assert.assertEquals
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith

/**
 * A2-60 (Android): the live look menu is the shared LUT picker, its tabs Nikon's libraries (RED
 * as a value with its download action, imported cubes on the shared file list).
 */
@OptIn(ExperimentalTestApi::class)
@RunWith(AndroidJUnit4::class)
class NikonLutPickerAdoptionTest {
    @get:Rule val composeRule = createComposeRule()

    @Test
    fun theLookMenuIsTheSharedPickerWithNikonsLibraries() {
        val assists = idleNikonAssists()
        var downloads = 0
        var imports = 0
        composeRule.setContent {
            OpenZCineTheme {
                Column { NikonLutOptions(assists, null, { downloads += 1 }, { imports += 1 }) }
            }
        }
        for (tab in listOf("Built-in", "RED", "Custom")) {
            composeRule.onNodeWithTag("monitor.lut.tab.$tab").assertExists()
        }
        composeRule.onNodeWithTag("monitor.lut.tab.RED").performClick()
        composeRule.onNodeWithText("Download from RED").performClick()
        composeRule.runOnIdle { assertEquals(1, downloads) }
        composeRule.onNodeWithTag("monitor.lut.tab.Custom").performClick()
        composeRule.onNodeWithText("Import a .cube file to add your own look.").assertExists()
        composeRule.onNodeWithText("Import .cube").performClick()
        composeRule.runOnIdle { assertEquals(1, imports) }
    }

    @Test fun comparisonTouchBelongsToTheInspectorAndClosingRestoresTheMonitorRail() {
        val context = ApplicationProvider.getApplicationContext<Context>()
        val preferences = context.getSharedPreferences("f11-lut-modal", Context.MODE_PRIVATE)
        preferences.edit().clear().commit()
        val settings = OperatorSettings(preferences)
        val assists = idleNikonAssists()
        val session = FakeCameraSession(CameraIdentity("SIMULATED", "SIMULATED", "lut-modal"), startConnected = true)
        composeRule.setContent {
            val scope = rememberCoroutineScope()
            val common = remember { NikonOpenCineSession(session, scope) }
            val control = remember { MonitorControlModel(scope).also { it.bind(common) } }
            DisposableEffect(Unit) { onDispose { control.unbind() } }
            OpenZCineTheme {
                MonitorScreen(session, common, control, rememberTestOperatorSession(assists, settings), frameSource = null,
                    assists = assists, operatorSettings = settings, liveViewEnabled = false, sessionRecoveryEnabled = false)
            }
        }
        composeRule.onNodeWithTag("monitor.system.settings").assertExists()
        composeRule.runOnIdle { assists.shared.configureTool = MonitorAssistTool.LUT }
        composeRule.waitUntilAtLeastOneExists(hasContentDescription("Close ${MonitorAssistTool.LUT.label}"), 5_000)
        val before = assists.shared.splitComparison
        // Real pointer dispatch at the switch side of the row, where the persistent rail overlapped.
        composeRule.onNodeWithText("50/50").performTouchInput {
            click(Offset(width.toFloat() - 10f, height.toFloat() / 2f))
        }
        composeRule.runOnIdle {
            assertEquals(!before, assists.shared.splitComparison)
            assertEquals(MonitorAssistTool.LUT, assists.shared.configureTool)
        }
        for (id in listOf("monitor.system.lock", "monitor.system.display", "monitor.system.settings")) {
            composeRule.onNodeWithTag(id).assertDoesNotExist()
        }
        val image = composeRule.onRoot().captureToImage().asAndroidBitmap()
        val metrics = context.resources.displayMetrics
        val orientation = if (metrics.widthPixels > metrics.heightPixels) "landscape" else "portrait"
        File(context.getExternalFilesDir(null), "f11-lut-modal-$orientation.png").outputStream().use {
            image.compress(Bitmap.CompressFormat.PNG, 100, it)
        }
        composeRule.onNodeWithContentDescription("Close ${MonitorAssistTool.LUT.label}").performTouchInput { click() }
        composeRule.runOnIdle { assertEquals(null, assists.shared.configureTool) }
        for (id in listOf("monitor.system.lock", "monitor.system.display", "monitor.system.settings")) {
            composeRule.onNodeWithTag(id).assertExists()
        }
        preferences.edit().clear().commit()
    }

    /** Evidence: the monitor's LUT inspector in the current orientation, saved for adb pull. */
    @Test
    fun lutInspectorScreen() {
        val context = ApplicationProvider.getApplicationContext<Context>()
        val preferences = context.getSharedPreferences("f11-lut-screens", Context.MODE_PRIVATE)
        preferences.edit().clear().commit()
        val settings = OperatorSettings(preferences)
        val assists = idleNikonAssists()
        val session = FakeCameraSession(CameraIdentity("SIMULATED", "SIMULATED", "lut-screens"), startConnected = true)
        composeRule.setContent {
            val scope = rememberCoroutineScope()
            val common = remember { NikonOpenCineSession(session, scope) }
            val control = remember { MonitorControlModel(scope).also { it.bind(common) } }
            DisposableEffect(Unit) { onDispose { control.unbind() } }
            OpenZCineTheme {
                MonitorScreen(session, common, control, rememberTestOperatorSession(assists, settings), frameSource = null,
                    assists = assists, operatorSettings = settings, liveViewEnabled = false, sessionRecoveryEnabled = false)
            }
        }
        composeRule.runOnIdle { assists.shared.configureTool = MonitorAssistTool.LUT }
        composeRule.waitUntilAtLeastOneExists(hasContentDescription("Close ${MonitorAssistTool.LUT.label}"), 5_000)
        composeRule.waitForIdle()
        val metrics = context.resources.displayMetrics
        val orientation = if (metrics.widthPixels > metrics.heightPixels) "landscape" else "portrait"
        val image = composeRule.onRoot().captureToImage().asAndroidBitmap()
        File(context.getExternalFilesDir(null), "f11-lut-inspector-$orientation.png").outputStream().use {
            image.compress(Bitmap.CompressFormat.PNG, 100, it)
        }
        preferences.edit().clear().commit()
    }
}
