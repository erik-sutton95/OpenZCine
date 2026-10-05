package com.opencapture.openzcine

import android.content.Context
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.requiredSize
import androidx.compose.runtime.mutableStateOf
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.Rect
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
import com.opencapture.openzcine.bridge.ZoneFrame
import com.opencapture.openzcine.media.LiveAssistOptionsOverlay
import com.opencapture.openzcine.settings.LocalLevelStyle
import com.opencapture.openzcine.settings.OperatorSettings
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
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
    fun liveMovablePanelRecentersThroughItsOwnAccessibilityAction() {
        // #228 removed the options' "Recenter panel" link for iOS parity; the panel owns recenter.
        val context = ApplicationProvider.getApplicationContext<Context>()
        val preferences =
            context.getSharedPreferences("ope68-live-panel-recenter", Context.MODE_PRIVATE)
        preferences.edit().clear().commit()
        val placements =
            context.getSharedPreferences(MonitorAnalysisPanelPlacementStore.STORE_NAME, Context.MODE_PRIVATE)
        placements.edit().clear().commit()
        val store = MonitorAnalysisPanelPlacementStore(context)
        val default = ZoneFrame(60f, 40f, 100f, 60f)
        val layout =
            MonitorAnalysisPanelLayout(
                viewport = ZoneFrame(0f, 0f, 320f, 220f),
                safeBounds = ZoneFrame(40f, 20f, 220f, 140f),
            )
        val moved = ZoneFrame(160f, 100f, 100f, 60f)
        store.save(MonitorAnalysisPanelID.WAVEFORM, moved, layout)
        composeRule.setContent {
            OpenZCineTheme {
                Box(Modifier.requiredSize(320.dp, 220.dp)) {
                    FloatingScopePanel(
                        kind = ScopeKind.WAVEFORM,
                        default = default,
                        panelLayout = layout,
                        scale = 1f,
                        baseWidth = 100f,
                        baseHeight = 60f,
                        placementStore = store,
                        legacyStore = null,
                        placementRevision = 0,
                        hapticsEnabled = false,
                        onPanelFrameChanged = { _, _ -> },
                        onScaleChange = {},
                    ) { modifier -> Box(modifier.fillMaxSize()) }
                    LiveAssistOptionsOverlay(
                        tool = AssistTool.WAVE,
                        anchorBounds = Rect(120f, 120f, 180f, 180f),
                        assistState = AssistState(FeedEffects.NONE, ScopeKind.WAVEFORM),
                        settings = OperatorSettings(preferences),
                        cameraInput = ExposureAssistCameraInput(),
                        lutLibrary = null,
                        onDismiss = {},
                    )
                }
            }
        }

        composeRule.onNodeWithContentDescription("Dismiss ${AssistTool.WAVE.settingsTitle} options")
            .assertIsDisplayed()
        composeRule.onAllNodesWithText("Recenter panel").assertCountEquals(0)
        composeRule.runOnIdle {
            assertEquals(moved, store.resolve(MonitorAnalysisPanelID.WAVEFORM, default, layout))
        }
        val recenter =
            composeRule
                .onNodeWithContentDescription("WAVE analysis panel, movable")
                .fetchSemanticsNode()
                .config[SemanticsActions.CustomActions]
                .single { it.label == "Recenter WAVE panel" }
        composeRule.runOnIdle { recenter.action() }
        composeRule.runOnIdle {
            assertNull(store.storedCenter(MonitorAnalysisPanelID.WAVEFORM))
            assertEquals(default, store.resolve(MonitorAnalysisPanelID.WAVEFORM, default, layout))
        }
        placements.edit().clear().commit()
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
        // #228 dropped the "Style" header for iOS parity: the panel is the Horizon/Gauge choice.
        composeRule.onAllNodesWithText("Style").assertCountEquals(0)
        composeRule.onNodeWithText("Horizon").performScrollTo().assertIsDisplayed()
        composeRule.onNodeWithText("Gauge").assertIsDisplayed().performClick()
        composeRule.runOnIdle { assertEquals(LocalLevelStyle.GAUGE, settings.levelStyle) }

        assertEquals(true, OperatorSettings(preferences).levelAssistEnabled.value)
        assertEquals(LocalLevelStyle.GAUGE, OperatorSettings(preferences).levelStyle)
        preferences.edit().clear().commit()
    }
}
