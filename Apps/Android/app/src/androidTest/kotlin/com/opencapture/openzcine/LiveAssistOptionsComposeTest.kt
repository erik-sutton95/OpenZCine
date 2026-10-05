package com.opencapture.openzcine

import android.content.Context
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.height
import androidx.compose.runtime.mutableStateOf
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.semantics.SemanticsActions
import androidx.compose.ui.test.ExperimentalTestApi
import androidx.compose.ui.test.assertCountEquals
import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.test.onAllNodesWithText
import androidx.compose.ui.test.onNodeWithContentDescription
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.performClick
import androidx.compose.ui.test.performSemanticsAction
import androidx.compose.ui.test.performScrollTo
import androidx.compose.ui.unit.dp
import androidx.test.core.app.ApplicationProvider
import androidx.test.ext.junit.runners.AndroidJUnit4
import com.opencapture.monitorui.MonitorAssistTool
import com.opencapture.openzcine.settings.LocalLevelStyle
import com.opencapture.openzcine.settings.OperatorSettings
import org.junit.Assert.assertEquals
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith

/** Device rendering contract for every live-monitor assist inspector page. */
@OptIn(ExperimentalTestApi::class)
@RunWith(AndroidJUnit4::class)
class LiveAssistOptionsComposeTest {
    @get:Rule
    val composeRule = createComposeRule()

    @Test
    fun everyConfigurableAssistRendersItsRealPanel() {
        val context = ApplicationProvider.getApplicationContext<Context>()
        val preferences =
            context.getSharedPreferences("ope65-live-assist-options", Context.MODE_PRIVATE)
        preferences.edit().clear().commit()
        val settings = OperatorSettings(preferences)
        val assists = idleNikonAssists()
        val tools =
            nikonLiveAssistChips(photography = false, imageEffects = true)
                .mapNotNull { (it as? NikonAssistChip.Tool)?.tool }
                .filter { it.nikonHasOptions }
        val activeTool = mutableStateOf(MonitorAssistTool.LUT)
        composeRule.setContent {
            OpenZCineTheme {
                BoxWithConstraints(Modifier.fillMaxSize()) {
                    NikonAssistInspector(
                        activeTool.value, tools, assists, settings, ExposureAssistCameraInput(), null,
                        maxWidth.value, maxHeight.value, onDismiss = {},
                    )
                }
            }
        }

        tools.forEach { tool ->
            composeRule.runOnIdle { activeTool.value = tool }
            composeRule.waitForIdle()
            composeRule.onNodeWithContentDescription("Dismiss ${tool.title}").assertIsDisplayed()
            composeRule.onAllNodesWithText(tool.title, ignoreCase = true)[0].assertIsDisplayed()
        }

        preferences.edit().clear().commit()
    }

    @Test
    fun levelToolbarTapAndLongPressShareThePersistedCameraFirstConfiguration() {
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
        composeRule.setContent {
            OpenZCineTheme {
                BoxWithConstraints(Modifier.fillMaxSize()) {
                    NikonAssistPalette(
                        listOf(NikonAssistChip.Tool(MonitorAssistTool.LEVEL)), assists,
                        playback = false, portrait = false, locked = false,
                        modifier = Modifier.align(Alignment.BottomCenter).height(58.dp),
                    )
                    assists.shared.configureTool?.let { tool ->
                        NikonAssistInspector(
                            tool, listOf(MonitorAssistTool.LEVEL), assists, settings, ExposureAssistCameraInput(), null,
                            maxWidth.value, maxHeight.value, onDismiss = { assists.shared.configureTool = null },
                        )
                    }
                }
            }
        }

        val level = composeRule.onNodeWithContentDescription(MonitorAssistTool.LEVEL.title, substring = true)
        level.performClick()
        composeRule.runOnIdle { assertEquals(true, assists.shared.isOn(MonitorAssistTool.LEVEL)) }
        level.performSemanticsAction(SemanticsActions.OnLongClick)
        composeRule.runOnIdle {
            assertEquals(MonitorAssistTool.LEVEL, assists.shared.configureTool)
            assertEquals(true, assists.shared.isOn(MonitorAssistTool.LEVEL))
        }
        // #228 dropped the "Style" header for iOS parity: the panel is the Horizon/Gauge choice.
        composeRule.onAllNodesWithText("Style").assertCountEquals(0)
        composeRule.onNodeWithText("Horizon").performScrollTo().assertIsDisplayed()
        composeRule.onNodeWithText("Gauge").assertIsDisplayed().performClick()
        composeRule.runOnIdle { assertEquals(LocalLevelStyle.GAUGE, settings.levelStyle) }

        assertEquals(true, restored().shared.isOn(MonitorAssistTool.LEVEL))
        assertEquals(LocalLevelStyle.GAUGE, OperatorSettings(preferences).levelStyle)
        preferences.edit().clear().commit()
        stores.forEach { it.edit().clear().commit() }
    }
}
