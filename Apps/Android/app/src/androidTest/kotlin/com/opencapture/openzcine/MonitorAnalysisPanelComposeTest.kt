package com.opencapture.openzcine

import android.content.Context
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.requiredSize
import androidx.compose.foundation.layout.size
import androidx.compose.runtime.mutableStateOf
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.test.ExperimentalTestApi
import androidx.compose.ui.test.getBoundsInRoot
import androidx.compose.ui.test.junit4.v2.createComposeRule
import androidx.compose.ui.test.onNodeWithTag
import androidx.compose.ui.test.performTouchInput
import androidx.compose.ui.unit.dp
import androidx.test.core.app.ApplicationProvider
import androidx.test.ext.junit.runners.AndroidJUnit4
import com.opencapture.monitorui.MonitorAssistTool
import com.opencapture.monitorui.MonitorRect
import com.opencapture.monitorui.MonitorScopePanelSize
import com.opencapture.monitorui.MonitorScopePoint
import com.opencapture.monitorui.MonitorScopeRect
import com.opencapture.opencine.appkit.MonitorAssistState
import com.opencapture.opencine.cameracontrols.MovableAssistPanel
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith

/**
 * Device gesture contract for the shared movable panel the Z monitor mounts for every scope and
 * the false colour key (the shared surface's `StackedScopePanel` and reference key).
 */
@OptIn(ExperimentalTestApi::class)
@RunWith(AndroidJUnit4::class)
class MonitorAnalysisPanelComposeTest {
    @get:Rule
    val composeRule = createComposeRule()

    @Test
    fun scopeDragStoresTheSharedCentreReportsItsFrameAndStaysInsideThePlacement() {
        val assist = MonitorAssistState()
        val visible = mutableStateOf(true)
        var reportedFrame: MonitorRect? = null
        var canvasPx = MonitorScopeRect(0f, 0f, 0f, 0f)
        composeRule.setContent {
            val density = LocalDensity.current.density
            val canvas = MonitorScopeRect(0f, 0f, 400f * density, 300f * density)
            canvasPx = canvas
            OpenZCineTheme {
                Box(Modifier.requiredSize(400.dp, 300.dp).testTag("panels")) {
                    if (visible.value) {
                        MovableAssistPanel(
                            MonitorAssistTool.HISTO, MonitorScopePanelSize.histogram, assist.histoScale,
                            assist.centerFor(MonitorAssistTool.HISTO, portrait = false), canvas,
                            MonitorScopeRect(20f * density, 20f * density, 360f * density, 260f * density),
                            MonitorScopePoint(canvas.midX, canvas.midY), enabled = true,
                            onStore = { assist.storeCenter(MonitorAssistTool.HISTO, it, portrait = false) },
                            onFrameChanged = { reportedFrame = it },
                        ) { size ->
                            Box(Modifier.size(size.width.dp, size.height.dp).background(Color.Black).testTag("histo"))
                        }
                    }
                }
            }
        }
        val panel = composeRule.onNodeWithTag("histo")

        fun nodeFrame(): MonitorRect {
            val root = composeRule.onNodeWithTag("panels").getBoundsInRoot()
            val bounds = panel.getBoundsInRoot()
            return MonitorRect(
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
            val stored = requireNotNull(assist.centerFor(MonitorAssistTool.HISTO, portrait = false))
            assertNull(assist.centerFor(MonitorAssistTool.HISTO, portrait = true))
            assertTrue(moved.x > start.x && moved.y > start.y)
            assertTrue(moved.x + moved.width <= 380f + 0.5f && moved.y + moved.height <= 280f + 0.5f)
            // The stored centre is a fraction of the canvas that lands on the panel's centre.
            val centre = stored.center(canvasPx)
            assertEquals(moved.x + moved.width / 2f, centre.x / density, 0.5f)
            assertEquals(moved.y + moved.height / 2f, centre.y / density, 0.5f)
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
