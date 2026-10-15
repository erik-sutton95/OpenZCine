package com.opencapture.openzcine

import androidx.activity.ComponentActivity
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.width
import androidx.compose.runtime.mutableStateOf
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.test.junit4.createAndroidComposeRule
import androidx.compose.ui.test.onNodeWithContentDescription
import androidx.compose.ui.unit.dp
import com.opencapture.monitorui.MonitorClock
import org.junit.Assert.assertEquals
import org.junit.Rule
import org.junit.Test

/** SIMULATED real shared clock layout, including the frame digits that change at camera rate. */
class NikonMonitorClockGeometryTest {
    @get:Rule val compose = createAndroidComposeRule<ComponentActivity>()

    @Test fun actualFrameDigitsKeepTheSameClockBounds() {
        val value = mutableStateOf("01:23:45:00")
        val variant = mutableStateOf(0)
        compose.setContent {
            OpenZCineTheme {
                Box(Modifier.width(350.dp), contentAlignment = Alignment.Center) {
                    MonitorClock(value.value, tablet = variant.value == 1, compact = variant.value == 2)
                }
            }
        }
        for (mode in 0..2) {
        compose.runOnIdle { variant.value = mode; value.value = "01:23:45:00" }
        val original = compose.onNodeWithContentDescription("Timecode ${value.value}")
            .fetchSemanticsNode().boundsInRoot
        for (frame in 0..59) {
            val text = "01:23:45:" + frame.toString().padStart(2, '0')
            compose.runOnIdle { value.value = text }
            val bounds = compose.onNodeWithContentDescription("Timecode $text")
                .fetchSemanticsNode().boundsInRoot
            assertEquals("Frame $frame width", original.width, bounds.width, 0.01f)
            assertEquals("Frame $frame left anchor", original.left, bounds.left, 0.01f)
            assertEquals("Frame $frame height", original.height, bounds.height, 0.01f)
        }
        }
    }
}
