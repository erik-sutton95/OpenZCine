package com.opencapture.openzcine

import android.content.Context
import androidx.compose.ui.test.ExperimentalTestApi
import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.hasContentDescription
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.test.onNodeWithContentDescription
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.performClick
import androidx.compose.ui.test.performScrollTo
import androidx.test.core.app.ApplicationProvider
import androidx.test.ext.junit.runners.AndroidJUnit4
import com.opencapture.monitorui.MonitorAssistTool
import com.opencapture.opencine.nikon.CameraIdentity
import com.opencapture.opencine.nikon.FakeCameraSession
import com.opencapture.monitorui.MonitorLevelStyle
import com.opencapture.openzcine.settings.OperatorSettings
import org.junit.Assert.assertEquals
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith

/**
 * SIMULATED: device rendering contract for every live-monitor assist inspector page, through the
 * production monitor: the shared palette and the shared inspector Pocket and Insta use, with the
 * Nikon option pages it supplies.
 */
@OptIn(ExperimentalTestApi::class)
@RunWith(AndroidJUnit4::class)
class LiveAssistOptionsComposeTest {
    @get:Rule
    val composeRule = createComposeRule()

    @Test
    fun everyConfigurableAssistRendersItsRealPanel() {
        val settings = settings("ope65-live-assist-options")
        val assists = idleNikonAssists()
        val tools =
            nikonLiveAssistChips(photography = false, imageEffects = true)
                .mapNotNull { (it as? NikonAssistChip.Tool)?.tool }
                .filter { it.nikonHasOptions }
        mount(assists, settings)

        tools.forEach { tool ->
            composeRule.runOnIdle { assists.shared.configureTool = tool }
            composeRule.waitUntilAtLeastOneExists(hasContentDescription("Dismiss ${tool.chipLabel}"), 5_000)
            composeRule.onNodeWithContentDescription("Dismiss ${tool.chipLabel}").assertIsDisplayed()
            composeRule.runOnIdle { assertEquals(tool, assists.shared.configureTool) }
        }
    }

    @Test
    fun levelInspectorWritesThePersistedLevelStyle() {
        val settings = settings("ope88-live-level-toolbar")
        val assists = idleNikonAssists()
        mount(assists, settings)

        composeRule.runOnIdle { assists.shared.configureTool = MonitorAssistTool.LEVEL }
        composeRule.waitUntilAtLeastOneExists(hasContentDescription("Dismiss ${MonitorAssistTool.LEVEL.chipLabel}"), 5_000)
        // #228 dropped the "Style" header for iOS parity: the panel is the Horizon/Gauge choice.
        composeRule.onNodeWithText("Horizon").performScrollTo().assertIsDisplayed()
        composeRule.onNodeWithText("Gauge").assertIsDisplayed().performClick()
        composeRule.runOnIdle { assertEquals(MonitorLevelStyle.GAUGE, settings.levelStyle) }
    }

    private fun settings(name: String): OperatorSettings {
        val context = ApplicationProvider.getApplicationContext<Context>()
        val preferences = context.getSharedPreferences(name, Context.MODE_PRIVATE)
        preferences.edit().clear().commit()
        return OperatorSettings(preferences)
    }

    private fun mount(assists: NikonAssists, settings: OperatorSettings) {
        val session = FakeCameraSession(CameraIdentity("SIMULATED", "SIMULATED", "assist-options"), startConnected = true)
        composeRule.setContent { TestMonitorScreen(session, assists, settings) }
        composeRule.waitForIdle()
    }
}
