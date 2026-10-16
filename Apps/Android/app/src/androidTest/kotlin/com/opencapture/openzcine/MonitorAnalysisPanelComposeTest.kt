package com.opencapture.openzcine

import android.content.Context
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.requiredSize
import androidx.compose.runtime.mutableStateOf
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.test.ExperimentalTestApi
import androidx.compose.ui.test.junit4.v2.createComposeRule
import androidx.compose.ui.test.onNodeWithTag
import androidx.compose.ui.test.performTouchInput
import androidx.compose.ui.unit.dp
import androidx.test.core.app.ApplicationProvider
import androidx.test.ext.junit.runners.AndroidJUnit4
import com.opencapture.monitorui.MonitorAssistTool
import com.opencapture.opencine.cameracontrols.AssistHost
import com.opencapture.opencine.cameracontrols.AssistOverlayLayer
import com.opencapture.opencine.appkit.MonitorAssistState
import com.opencapture.monitorui.MonitorRect
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith

/**
 * Device gesture contract for the scope panels live view mounts: the shared assist layer's movable
 * panel (the one Pocket and Insta use) stores its centre per orientation, stays inside the placement
 * bounds and reports its frame so the focus-reset button can climb above it.
 */
@OptIn(ExperimentalTestApi::class)
@RunWith(AndroidJUnit4::class)
class MonitorAnalysisPanelComposeTest {
    @get:Rule
    val composeRule = createComposeRule()

    @Test
    fun scopeDragStoresTheSharedCentreReportsItsFrameAndKeepsTheFocusResetClear() {
        val assist = MonitorAssistState().apply { toggle(MonitorAssistTool.HISTO) }
        val visible = mutableStateOf(true)
        var reportedFrame: MonitorRect? = null
        composeRule.setContent {
            OpenZCineTheme {
                Box(Modifier.requiredSize(400.dp, 300.dp).testTag("panels")) {
                    if (visible.value) {
                        AssistOverlayLayer(
                            state = assist,
                            scopeBundle = null,
                            host = AssistHost(emptyList(), emptyList(), emptyList()),
                            placementFrame = MonitorRect(12f, 12f, 376f, 276f),
                            referenceValues = null,
                            onPanelFrameChanged = { tool, frame ->
                                if (tool == MonitorAssistTool.HISTO) reportedFrame = frame
                            },
                        )
                    }
                }
            }
        }
        val density = ApplicationProvider.getApplicationContext<Context>().resources.displayMetrics.density
        val start = composeRule.runOnIdle { requireNotNull(reportedFrame) }

        composeRule.onNodeWithTag("panels").performTouchInput {
            down(Offset((start.x + start.width / 2f) * density, (start.y + start.height / 2f) * density))
            advanceEventTime(16)
            moveBy(Offset(12f * density, 12f * density))
            advanceEventTime(16)
            moveBy(Offset(1_000f, 1_000f))
            advanceEventTime(16)
            up()
        }
        val moved = composeRule.runOnIdle { requireNotNull(reportedFrame) }
        composeRule.runOnIdle {
            assertNotNull(assist.centerFor(MonitorAssistTool.HISTO, portrait = false))
            assertNull(assist.centerFor(MonitorAssistTool.HISTO, portrait = true))
            assertTrue(moved.x > start.x && moved.y > start.y)
            assertTrue(moved.x + moved.width <= 380f + 0.5f && moved.y + moved.height <= 280f + 0.5f)
            visible.value = false
        }
        composeRule.runOnIdle { assertNull(reportedFrame) }
        composeRule.runOnIdle { visible.value = true }
        composeRule.runOnIdle { assertFrameEquals(moved, requireNotNull(reportedFrame)) }
    }

    private fun assertFrameEquals(expected: MonitorRect, actual: MonitorRect) {
        assertEquals(expected.x, actual.x, 0.5f)
        assertEquals(expected.y, actual.y, 0.5f)
        assertEquals(expected.width, actual.width, 0.5f)
        assertEquals(expected.height, actual.height, 0.5f)
    }
}
