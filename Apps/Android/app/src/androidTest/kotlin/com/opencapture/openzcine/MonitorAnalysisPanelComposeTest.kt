package com.opencapture.openzcine

import android.content.Context
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.requiredSize
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.test.ExperimentalTestApi
import androidx.compose.ui.test.getBoundsInRoot
import androidx.compose.ui.test.junit4.v2.createComposeRule
import androidx.compose.ui.test.onNodeWithContentDescription
import androidx.compose.ui.test.onNodeWithTag
import androidx.compose.ui.test.performTouchInput
import androidx.compose.ui.unit.dp
import androidx.test.core.app.ApplicationProvider
import androidx.test.ext.junit.runners.AndroidJUnit4
import com.opencapture.monitorui.MonitorAssistTool
import com.opencapture.opencine.appkit.MonitorAssistState
import com.opencapture.openzcine.bridge.ZoneFrame
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith

/** Device gesture contract for the shared scope panels and the false-colour key placement. */
@OptIn(ExperimentalTestApi::class)
@RunWith(AndroidJUnit4::class)
class MonitorAnalysisPanelComposeTest {
    @get:Rule
    val composeRule = createComposeRule()

    @Test
    fun scopeDragStoresTheSharedCentreReportsItsFrameAndKeepsTheFocusResetClear() {
        val assist = MonitorAssistState()
        val visible = mutableStateOf(true)
        var reportedFrame: ZoneFrame? = null
        val layout =
            MonitorAnalysisPanelLayout(
                viewport = ZoneFrame(0f, 0f, 400f, 300f),
                safeBounds = ZoneFrame(20f, 20f, 360f, 260f),
            )
        composeRule.setContent {
            OpenZCineTheme {
                Box(Modifier.requiredSize(400.dp, 300.dp).testTag("panels")) {
                    if (visible.value) {
                        FloatingScopePanels(
                            displayed = listOf(ScopeKind.HISTOGRAM),
                            panelLayout = layout,
                            assist = assist,
                            hapticsEnabled = false,
                            onPanelFrameChanged = { id, frame ->
                                if (id == MonitorAnalysisPanelID.HISTOGRAM) reportedFrame = frame
                            },
                        ) { _, modifier ->
                            Box(modifier.background(Color.Black))
                        }
                    }
                }
            }
        }
        val panel = composeRule.onNodeWithContentDescription("HISTO analysis panel, movable")

        fun nodeFrame(): ZoneFrame {
            val root = composeRule.onNodeWithTag("panels").getBoundsInRoot()
            val bounds = panel.getBoundsInRoot()
            return ZoneFrame(
                (bounds.left - root.left).value,
                (bounds.top - root.top).value,
                (bounds.right - bounds.left).value,
                (bounds.bottom - bounds.top).value,
            )
        }
        val start = composeRule.runOnIdle { requireNotNull(reportedFrame) }
        assertFrameEquals(nodeFrame(), start)

        val density = ApplicationProvider.getApplicationContext<Context>().resources.displayMetrics.density
        panel.performTouchInput {
            down(center)
            advanceEventTime(16)
            moveBy(Offset(12f * density, 12f * density))
            advanceEventTime(16)
            moveBy(Offset(1_000f, 1_000f))
            advanceEventTime(16)
            up()
        }
        val moved = composeRule.runOnIdle { requireNotNull(reportedFrame) }
        assertFrameEquals(nodeFrame(), moved)
        composeRule.runOnIdle {
            assertNotNull(assist.centerFor(MonitorAssistTool.HISTO, portrait = false))
            assertNull(assist.centerFor(MonitorAssistTool.HISTO, portrait = true))
            assertTrue(moved.x > start.x && moved.y > start.y)
            assertTrue(moved.x + moved.width <= 380f + 0.5f && moved.y + moved.height <= 280f + 0.5f)
            val base = ZoneFrame(moved.x, moved.y + moved.height - 44f, 44f, 44f)
            val reset = focusResetButtonClearFrame(base, listOf(moved), layout.viewport)
            assertTrue(reset.y + reset.height + FOCUS_RESET_PANEL_GAP_DP <= moved.y + 0.5f)
            visible.value = false
        }
        composeRule.runOnIdle { assertNull(reportedFrame) }
        composeRule.runOnIdle { visible.value = true }
        composeRule.runOnIdle { assertFrameEquals(moved, requireNotNull(reportedFrame)) }
    }

    private fun assertFrameEquals(expected: ZoneFrame, actual: ZoneFrame) {
        assertEquals(expected.x, actual.x, 0.5f)
        assertEquals(expected.y, actual.y, 0.5f)
        assertEquals(expected.width, actual.width, 0.5f)
        assertEquals(expected.height, actual.height, 0.5f)
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
