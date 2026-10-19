package com.opencapture.openzcine

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.padding
import androidx.compose.runtime.mutableStateOf
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.toPixelMap
import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.captureToImage
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.test.onNodeWithContentDescription
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.unit.dp
import androidx.test.ext.junit.runners.AndroidJUnit4
import com.opencapture.monitorui.MonitorTelemetry
import com.opencapture.monitorui.MonitorTelemetryPower
import com.opencapture.opencine.cameracontrols.cameraPowerReading
import com.opencapture.opencine.core.BatteryReading
import kotlin.math.abs
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith

/** SIMULATED exact steps and reported exhaustion exercise shared native phone rendering. */
@RunWith(AndroidJUnit4::class)
class MonitorTelemetryBatteryRenderTest {
    @get:Rule val rule = createComposeRule()

    @Test fun elevenStepsUseVisibleExactText() = verifySteps(1, 11)
    @Test fun millionStepsUseVisibleExactText() = verifySteps(1, 1_000_000)
    @Test fun maximalIntegerStepsKeepEveryDigit() = verifySteps(Int.MAX_VALUE, Int.MAX_VALUE)

    private fun verifySteps(filled: Int, count: Int) {
        rule.setContent {
            OpenZCineTheme { Box(Modifier.background(Color.Black).padding(20.dp)) {
                MonitorTelemetry(null, null, listOf(MonitorTelemetryPower(true, null, bars = filled, barCount = count)),
                    horizontal = true, showsLink = false)
            } }
        }
        rule.onNodeWithContentDescription("Camera battery $filled of $count bars").assertIsDisplayed()
        val text = rule.onNodeWithText("$filled/$count")
        text.assertIsDisplayed()
        val textBounds = text.fetchSemanticsNode().boundsInRoot
        val badgeBounds = rule.onNodeWithContentDescription("Camera battery $filled of $count bars").fetchSemanticsNode().boundsInRoot
        assertTrue("Exact text must fit the bounded gauge", textBounds.width <= badgeBounds.width)
        assertTrue("The gauge remains bounded", badgeBounds.width <= 156 * rule.density.density + 1)
    }

    @Test fun exhaustionPulsesTheActualWarningBadge() = verifyExhaustion(true)
    @Test fun ordinaryWarningDoesNotPulse() = verifyExhaustion(false)
    @Test fun unknownExhaustionDoesNotPulse() = verifyExhaustion(null)

    @Test fun endingExhaustionRestoresSteadyOpacity() {
        val reported = mutableStateOf<Boolean?>(true)
        rule.mainClock.autoAdvance = false
        rule.setContent {
            val common = checkNotNull(cameraPowerReading(BatteryReading.Steps(1, 5), reported.value))
            OpenZCineTheme { Box(Modifier.background(Color.Black).padding(20.dp)) {
                MonitorTelemetry(null, null, listOf(MonitorTelemetryPower(true, null, bars = 1, barCount = 5,
                    warning = common.warning, exhausted = common.exhausted)), horizontal = true, showsLink = false)
            } }
        }
        rule.mainClock.advanceTimeBy(640)
        for (cleared in listOf(false, null)) {
            rule.runOnIdle { reported.value = cleared }
            rule.mainClock.advanceTimeBy(32)
            val badge = rule.onNodeWithContentDescription("Camera battery 1 of 5 bars")
            val first = badge.captureToImage().toPixelMap()
            rule.mainClock.advanceTimeBy(608)
            val second = badge.captureToImage().toPixelMap()
            for (y in 0 until first.height) for (x in 0 until first.width) {
                assertEquals(first[x, y], second[x, y])
            }
        }
    }

    private fun verifyExhaustion(exhausted: Boolean?) {
        val common = checkNotNull(cameraPowerReading(BatteryReading.Steps(1, 5), exhausted))
        assertTrue("Both raw1 and raw20 already have the same warning tint", common.warning)
        assertEquals(exhausted == true, common.exhausted)
        rule.mainClock.autoAdvance = false
        rule.setContent {
            OpenZCineTheme { Box(Modifier.background(Color.Black).padding(20.dp)) {
                MonitorTelemetry(null, null, listOf(MonitorTelemetryPower(common.camera, common.percent,
                    bars = common.bars, barCount = common.barCount, warning = common.warning,
                    exhausted = common.exhausted)), horizontal = true, showsLink = false)
            } }
        }
        rule.mainClock.advanceTimeBy(32)
        val badge = rule.onNodeWithContentDescription("Camera battery 1 of 5 bars")
        badge.assertIsDisplayed()
        val first = badge.captureToImage().toPixelMap()
        rule.mainClock.advanceTimeBy(608)
        val second = badge.captureToImage().toPixelMap()
        assertEquals(first.width, second.width)
        assertEquals(first.height, second.height)
        var difference = 0.0
        for (y in 0 until first.height) for (x in 0 until first.width) {
            val a = first[x, y]; val b = second[x, y]
            difference += abs(a.red - b.red) + abs(a.green - b.green) + abs(a.blue - b.blue)
        }
        difference /= first.width * first.height * 3.0
        println("SIMULATED exhaustion=$exhausted rendered pixel difference=$difference")
        if (exhausted == true) assertTrue("Reported exhaustion must visibly pulse; difference=$difference", difference > 0.02)
        else assertTrue("False/unknown exhaustion keeps the warning stable; difference=$difference", difference < 0.002)
    }
}
