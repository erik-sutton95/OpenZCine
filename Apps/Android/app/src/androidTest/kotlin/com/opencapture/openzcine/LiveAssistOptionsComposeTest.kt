package com.opencapture.openzcine

import android.content.Context
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.ui.semantics.SemanticsActions
import androidx.compose.ui.test.ExperimentalTestApi
import androidx.compose.ui.test.assertCountEquals
import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.hasContentDescription
import androidx.compose.ui.test.hasTestTag
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.test.onAllNodesWithText
import androidx.compose.ui.test.onNodeWithContentDescription
import androidx.compose.ui.test.onNodeWithTag
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.performClick
import androidx.compose.ui.test.performScrollTo
import androidx.compose.ui.test.performSemanticsAction
import androidx.test.core.app.ApplicationProvider
import androidx.test.ext.junit.runners.AndroidJUnit4
import com.opencapture.monitorui.MonitorAssistTool
import com.opencapture.opencine.appkit.MonitorControlModel
import com.opencapture.opencine.nikon.CameraIdentity
import com.opencapture.opencine.nikon.FakeCameraSession
import com.opencapture.opencine.nikon.NikonOpenCineSession
import com.opencapture.openzcine.bridge.SwiftCore
import com.opencapture.openzcine.settings.LocalLevelStyle
import com.opencapture.openzcine.settings.OperatorSettings
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith

/** Device rendering contract for every live-monitor assist inspector page, on the mounted monitor. */
@OptIn(ExperimentalTestApi::class)
@RunWith(AndroidJUnit4::class)
class LiveAssistOptionsComposeTest {
    @get:Rule
    val composeRule = createComposeRule()

    @Test
    fun everyConfigurableAssistOpensItsRealPanelInTheMonitorInspector() {
        assertTrue("Image effects need the staged Swift core", SwiftCore.isAvailable)
        val context = ApplicationProvider.getApplicationContext<Context>()
        val preferences =
            context.getSharedPreferences("ope65-live-assist-options", Context.MODE_PRIVATE)
        preferences.edit().clear().commit()
        val assists = idleNikonAssists()
        showMonitor(assists, OperatorSettings(preferences))
        val tools =
            nikonLiveAssistChips(photography = false, imageEffects = true)
                .mapNotNull { (it as? NikonAssistChip.Tool)?.tool }
                .filter { it.nikonHasOptions }

        tools.forEach { tool ->
            composeRule.runOnIdle { assists.shared.configureTool = tool }
            // The shared inspector names a tool by its palette chip (DE-SQ, not DESQ).
            composeRule.waitUntilAtLeastOneExists(hasContentDescription("Close ${tool.chipLabel}"), 5_000)
            composeRule.onNodeWithContentDescription("Close ${tool.chipLabel}").assertIsDisplayed()
            // The shared inspector drops a tool the monitor does not offer; this one stays.
            composeRule.runOnIdle { assertEquals(tool, assists.shared.configureTool) }
            composeRule.onNodeWithContentDescription("Close ${tool.chipLabel}")
                .performSemanticsAction(SemanticsActions.OnClick)
            composeRule.runOnIdle { assertNull(assists.shared.configureTool) }
        }

        preferences.edit().clear().commit()
    }

    @Test
    fun levelPaletteTapAndLongPressShareThePersistedCameraFirstConfiguration() {
        val context = ApplicationProvider.getApplicationContext<Context>()
        val preferences =
            context.getSharedPreferences("ope88-live-level-toolbar", Context.MODE_PRIVATE)
        preferences.edit().clear().commit()
        val settings = OperatorSettings(preferences)
        val stores =
            listOf("ope88-live-level-assist", "ope88-live-level-operator", "ope88-live-level-playback")
                .map { context.getSharedPreferences(it, Context.MODE_PRIVATE).apply { edit().clear().commit() } }
        fun restored() = restoreNikonAssists(stores[0], stores[1], stores[2])
        val assists = restored()
        showMonitor(assists, settings)

        composeRule.waitUntilAtLeastOneExists(hasTestTag("monitor.assists.expand"), 5_000)
        composeRule.onNodeWithTag("monitor.assists.expand").performSemanticsAction(SemanticsActions.OnClick)
        val off = hasContentDescription("${MonitorAssistTool.LEVEL.title}, off")
        composeRule.waitUntilAtLeastOneExists(off, 5_000)
        composeRule.onNode(off).performSemanticsAction(SemanticsActions.OnClick)
        composeRule.runOnIdle { assertEquals(true, assists.shared.isOn(MonitorAssistTool.LEVEL)) }
        // The live level follows the device's sensors and never settles, so the clock steps by hand.
        composeRule.mainClock.autoAdvance = false
        composeRule.onNodeWithContentDescription("${MonitorAssistTool.LEVEL.title}, on")
            .performSemanticsAction(SemanticsActions.OnLongClick)
        composeRule.mainClock.advanceTimeBy(1_000)
        composeRule.runOnIdle {
            assertEquals(MonitorAssistTool.LEVEL, assists.shared.configureTool)
            assertEquals(true, assists.shared.isOn(MonitorAssistTool.LEVEL))
        }
        // #228 dropped the "Style" header for iOS parity: the panel is the Horizon/Gauge choice.
        composeRule.onAllNodesWithText("Style").assertCountEquals(0)
        composeRule.onNodeWithText("Horizon").performScrollTo()
        composeRule.mainClock.advanceTimeBy(1_000)
        composeRule.onNodeWithText("Horizon").assertIsDisplayed()
        composeRule.onNodeWithText("Gauge").assertIsDisplayed().performClick()
        composeRule.mainClock.advanceTimeBy(1_000)
        composeRule.runOnIdle { assertEquals(LocalLevelStyle.GAUGE, settings.levelStyle) }
        composeRule.mainClock.autoAdvance = true

        assertEquals(true, restored().shared.isOn(MonitorAssistTool.LEVEL))
        assertEquals(LocalLevelStyle.GAUGE, OperatorSettings(preferences).levelStyle)
        preferences.edit().clear().commit()
        stores.forEach { it.edit().clear().commit() }
    }

    private fun showMonitor(assists: NikonAssists, settings: OperatorSettings) {
        val session = FakeCameraSession(CameraIdentity("SIMULATED", "SIMULATED", "live-assist-options"), startConnected = true)
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
    }
}
