package com.opencapture.openzcine

import android.content.Context
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.requiredSize
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.semantics.SemanticsActions
import androidx.compose.ui.test.ExperimentalTestApi
import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.junit4.v2.createComposeRule
import androidx.compose.ui.test.onNodeWithContentDescription
import androidx.compose.ui.test.performTouchInput
import androidx.compose.ui.unit.dp
import androidx.test.core.app.ApplicationProvider
import androidx.test.ext.junit.runners.AndroidJUnit4
import com.opencapture.openzcine.bridge.ZoneFrame
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith

/** Device gesture contract for clamp, persistence, removal, and accessibility recenter. */
@OptIn(ExperimentalTestApi::class)
@RunWith(AndroidJUnit4::class)
class MonitorAnalysisPanelComposeTest {
    @get:Rule
    val composeRule = createComposeRule()

    @Test
    fun scopeDragClampsPersistsAcrossRemovalAndRecenters() {
        val context = ApplicationProvider.getApplicationContext<Context>()
        clearPlacementStores(context)
        val store = MonitorAnalysisPanelPlacementStore(context)
        val visible = mutableStateOf(true)
        val placementRevision = mutableIntStateOf(0)
        var reportedFrame: ZoneFrame? = null
        val default = ZoneFrame(60f, 40f, 100f, 60f)
        val layout =
            MonitorAnalysisPanelLayout(
                viewport = ZoneFrame(0f, 0f, 320f, 220f),
                safeBounds = ZoneFrame(40f, 20f, 220f, 140f),
            )
        composeRule.setContent {
            OpenZCineTheme {
                Box(Modifier.requiredSize(320.dp, 220.dp)) {
                    if (visible.value) {
                        FloatingScopePanel(
                            kind = ScopeKind.WAVEFORM,
                            default = default,
                            panelLayout = layout,
                            scale = 1f,
                            baseWidth = 100f,
                            baseHeight = 60f,
                            placementStore = store,
                            legacyStore = null,
                            placementRevision = placementRevision.intValue,
                            hapticsEnabled = false,
                            onPanelFrameChanged = { id, frame ->
                                if (id == MonitorAnalysisPanelID.WAVEFORM) reportedFrame = frame
                            },
                            onScaleChange = {},
                        ) { modifier ->
                            Box(modifier.fillMaxSize().background(Color.Black))
                        }
                    }
                }
            }
        }
        val panel = composeRule.onNodeWithContentDescription("WAVE analysis panel, movable")
        composeRule.runOnIdle { assertEquals(default, reportedFrame) }

        panel.performTouchInput {
            down(center)
            advanceEventTime(700)
            moveBy(Offset(1_000f, 1_000f))
            advanceEventTime(50)
            up()
        }
        composeRule.runOnIdle {
            assertEquals(
                ZoneFrame(160f, 100f, 100f, 60f),
                store.resolve(MonitorAnalysisPanelID.WAVEFORM, default, layout),
            )
            assertEquals(ZoneFrame(160f, 100f, 100f, 60f), reportedFrame)
            visible.value = false
        }
        composeRule.runOnIdle { assertNull(reportedFrame) }
        composeRule.runOnIdle { visible.value = true }
        composeRule.onNodeWithContentDescription("WAVE analysis panel, movable").assertIsDisplayed()

        composeRule.runOnIdle {
            store.recenter(MonitorAnalysisPanelID.WAVEFORM)
            placementRevision.intValue += 1
        }
        val density = context.resources.displayMetrics.density
        composeRule
            .onNodeWithContentDescription("WAVE analysis panel, movable")
            .performTouchInput {
                down(center)
                advanceEventTime(700)
                moveBy(Offset(40f * density, 20f * density))
                advanceEventTime(50)
                up()
            }
        composeRule.runOnIdle {
            assertEquals(
                ZoneFrame(100f, 60f, 100f, 60f),
                store.resolve(MonitorAnalysisPanelID.WAVEFORM, default, layout),
            )
        }

        val recenterAction =
            composeRule
                .onNodeWithContentDescription("WAVE analysis panel, movable")
                .fetchSemanticsNode()
                .config[SemanticsActions.CustomActions]
                .single { it.label == "Recenter WAVE panel" }
        composeRule.runOnIdle {
            recenterAction.action()
        }
        composeRule.runOnIdle {
            assertNull(store.storedCenter(MonitorAnalysisPanelID.WAVEFORM))
            assertEquals(
                default,
                store.resolve(MonitorAnalysisPanelID.WAVEFORM, default, layout),
            )
        }
        clearPlacementStores(context)
    }

    @Test
    fun falseColorReferenceDirectDragUsesTheSameSafeNormalizedStore() {
        val context = ApplicationProvider.getApplicationContext<Context>()
        clearPlacementStores(context)
        val store = MonitorAnalysisPanelPlacementStore(context)
        val placementRevision = mutableIntStateOf(0)
        val effectsState = LiveFeedEffectsPresentationState()
        effectsState.present(
            FeedFalseColorScale.LIMITS,
            FeedFalseColorReference(
                curveOrdinal = 0,
                segments =
                    listOf(
                        FeedFalseColorReferenceSegment(
                            lowerFraction = 0f,
                            upperFraction = 1f,
                            color = floatArrayOf(1f, 0f, 0f),
                        ),
                    ),
                stopMarkerFractions = floatArrayOf(),
            ),
        )
        val viewport = ZoneFrame(0f, 0f, 360f, 240f)
        val layout =
            MonitorAnalysisPanelLayout(
                viewport = viewport,
                safeBounds = ZoneFrame(40f, 20f, 300f, 190f),
            )
        composeRule.setContent {
            OpenZCineTheme {
                Box(Modifier.requiredSize(360.dp, 240.dp)) {
                    FalseColorReferenceOverlay(
                        effectsState = effectsState,
                        feed = viewport,
                        viewport = viewport,
                        panelLayout = layout,
                        placementStore = store,
                        placementRevision = placementRevision.intValue,
                        hapticsEnabled = false,
                    )
                }
            }
        }

        composeRule
            .onNodeWithContentDescription("False color reference, movable panel")
            .performTouchInput {
                down(center)
                advanceEventTime(700)
                moveBy(Offset(-1_000f, -1_000f))
                advanceEventTime(50)
                up()
            }

        composeRule.runOnIdle {
            val default =
                controlSafeFalseColorReferenceDefaultFrame(
                    feed = viewport,
                    layout = layout,
                )
            assertEquals(
                ZoneFrame(40f, 20f, default.width, default.height),
                store.resolve(
                    MonitorAnalysisPanelID.FALSE_COLOR_REFERENCE,
                    default,
                    layout,
                ),
            )
        }

        composeRule.runOnIdle {
            store.recenter(MonitorAnalysisPanelID.FALSE_COLOR_REFERENCE)
            placementRevision.intValue += 1
        }
        val density = context.resources.displayMetrics.density
        composeRule
            .onNodeWithContentDescription("False color reference, movable panel")
            .performTouchInput {
                down(center)
                advanceEventTime(700)
                moveBy(Offset(30f * density, 20f * density))
                advanceEventTime(50)
                up()
            }
        composeRule.runOnIdle {
            val default =
                controlSafeFalseColorReferenceDefaultFrame(
                    feed = viewport,
                    layout = layout,
                )
            assertEquals(
                ZoneFrame(72f, 128f, default.width, default.height),
                store.resolve(
                    MonitorAnalysisPanelID.FALSE_COLOR_REFERENCE,
                    default,
                    layout,
                ),
            )
        }
        clearPlacementStores(context)
    }

    private fun clearPlacementStores(context: Context) {
        listOf(
            MonitorAnalysisPanelPlacementStore.STORE_NAME,
            MonitorAnalysisPanelPlacementStore.LEGACY_SCOPE_STORE_NAME,
            MonitorAnalysisPanelPlacementStore.LEGACY_FALSE_COLOR_STORE_NAME,
        ).forEach { name ->
            context.getSharedPreferences(name, Context.MODE_PRIVATE).edit().clear().commit()
        }
    }
}
