package com.opencapture.openzcine

import android.content.Context
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.height
import androidx.compose.runtime.mutableStateOf
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.Rect
import androidx.compose.ui.semantics.SemanticsActions
import androidx.compose.ui.test.ExperimentalTestApi
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
import com.opencapture.openzcine.media.LiveAssistOptionsOverlay
import com.opencapture.openzcine.settings.OperatorSettings
import org.junit.Assert.assertEquals
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith

/** Device rendering contract for every real live-monitor assist configuration panel. */
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
        val assistState = AssistState(FeedEffects.NONE, null)
        val activeTool = mutableStateOf(AssistTool.LUT)
        composeRule.setContent {
            OpenZCineTheme {
                LiveAssistOptionsOverlay(
                    tool = activeTool.value,
                    anchorBounds = Rect(120f, 120f, 180f, 180f),
                    assistState = assistState,
                    settings = settings,
                    cameraInput = ExposureAssistCameraInput(),
                    lutLibrary = null,
                    onDismiss = {},
                )
            }
        }

        AssistTool.entries.filter(AssistTool::hasConfiguration).forEach { tool ->
            composeRule.runOnIdle { activeTool.value = tool }
            composeRule.waitForIdle()
            composeRule
                .onNodeWithContentDescription("Dismiss ${tool.settingsTitle} options")
                .assertIsDisplayed()
            composeRule.onAllNodesWithText(tool.settingsTitle.uppercase())[0].assertIsDisplayed()
        }

        preferences.edit().clear().commit()
    }

    @Test
    fun liveMovablePanelOptionsExposeAnExplicitRecenterAction() {
        val context = ApplicationProvider.getApplicationContext<Context>()
        val preferences =
            context.getSharedPreferences("ope68-live-panel-recenter", Context.MODE_PRIVATE)
        preferences.edit().clear().commit()
        val settings = OperatorSettings(preferences)
        var recenterCount = 0
        composeRule.setContent {
            OpenZCineTheme {
                LiveAssistOptionsOverlay(
                    tool = AssistTool.WAVE,
                    anchorBounds = Rect(120f, 120f, 180f, 180f),
                    assistState = AssistState(FeedEffects.NONE, ScopeKind.WAVEFORM),
                    settings = settings,
                    cameraInput = ExposureAssistCameraInput(),
                    lutLibrary = null,
                    onRecenterPanel = { recenterCount += 1 },
                    onDismiss = {},
                )
            }
        }

        composeRule.onNodeWithText("Recenter panel").performScrollTo().performClick()

        composeRule.runOnIdle { assertEquals(1, recenterCount) }
        preferences.edit().clear().commit()
    }

    @Test
    fun levelToolbarTapAndLongPressShareThePersistedCameraFirstConfiguration() {
        val context = ApplicationProvider.getApplicationContext<Context>()
        val preferences =
            context.getSharedPreferences("ope88-live-level-toolbar", Context.MODE_PRIVATE)
        preferences.edit().clear().commit()
        val settings = OperatorSettings(preferences)
        val assistState = AssistState(FeedEffects.NONE, null)
        val optionsOpen = mutableStateOf(false)
        val anchor = mutableStateOf<Rect?>(null)
        composeRule.setContent {
            OpenZCineTheme {
                Box(Modifier.fillMaxSize()) {
                    AssistToolbar(
                        state = assistState,
                        visibleTools = listOf(AssistTool.LEVEL),
                        framingConfiguration = settings.localFramingAssistConfiguration,
                        onToggleFramingTool = settings::toggleLocalFramingTool,
                        hapticsEnabled = false,
                        onLongPressToolAnchored = { tool, bounds ->
                            if (tool == AssistTool.LEVEL) {
                                anchor.value = bounds
                                optionsOpen.value = true
                            }
                        },
                        modifier = Modifier.align(Alignment.BottomCenter).height(58.dp),
                    )
                    if (optionsOpen.value) {
                        LiveAssistOptionsOverlay(
                            tool = AssistTool.LEVEL,
                            anchorBounds = anchor.value,
                            assistState = assistState,
                            settings = settings,
                            cameraInput = ExposureAssistCameraInput(),
                            lutLibrary = null,
                            onDismiss = { optionsOpen.value = false },
                        )
                    }
                }
            }
        }

        val level = composeRule.onNodeWithContentDescription(AssistTool.LEVEL.settingsTitle)
        level.performClick()
        composeRule.runOnIdle { assertEquals(true, settings.levelAssistEnabled.value) }
        level.performSemanticsAction(SemanticsActions.OnLongClick)
        composeRule.runOnIdle { assertEquals(true, settings.levelAssistEnabled.value) }
        composeRule.onNodeWithText("Style").performScrollTo().assertIsDisplayed()
        composeRule.onNodeWithText("Horizon").assertIsDisplayed()
        composeRule.onNodeWithText("Gauge").assertIsDisplayed()

        assertEquals(true, OperatorSettings(preferences).levelAssistEnabled.value)
        preferences.edit().clear().commit()
    }
}
