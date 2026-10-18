package com.opencapture.openzcine

import android.view.View
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.requiredSize
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.Rect
import androidx.compose.ui.layout.boundsInRoot
import androidx.compose.ui.layout.onGloballyPositioned
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.test.onNodeWithContentDescription
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.unit.dp
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import androidx.test.runner.lifecycle.ActivityLifecycleMonitorRegistry
import androidx.test.runner.lifecycle.Stage
import androidx.test.uiautomator.UiDevice
import com.opencapture.monitorui.MonitorBoundedReadoutText
import com.opencapture.monitorui.MonitorFieldLayout
import com.opencapture.monitorui.MonitorLayoutPolicy
import com.opencapture.monitorui.MonitorRect
import com.opencapture.monitorui.MonitorStatusChrome
import com.opencapture.monitorui.MonitorStatusPresentation
import com.opencapture.monitorui.MonitorTelemetry
import com.opencapture.monitorui.MonitorTelemetryPower
import com.opencapture.opencine.appkit.MonitorControlModel
import com.opencapture.opencine.appkit.MonitorScreen
import com.opencapture.opencine.appkit.MonitorScreenPresentation
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith

/** SIMULATED values, actual shared production slot placement and both rendered battery badges. */
@RunWith(AndroidJUnit4::class)
class MonitorScreenPowerClearanceTest {
    @get:Rule val composeRule = createComposeRule()
    private val device = UiDevice.getInstance(InstrumentationRegistry.getInstrumentation())

    // Actual retained host: 1080 x 2340 px at density 3.0 (360 x 780 dp), with a centred punch hole
    // x 511..569, y 0..91 px = 19.333 x 30.333 dp. The 320 case is an explicit SIMULATED narrow
    // canvas that keeps the same observed punch-hole size centred on its own width.
    @Test(timeout = 90_000) fun narrowPhoneClearsCutoutWithLongStorage() =
        portrait(320f, 59f, 20f, Rect(150.333f, 0f, 169.667f, 30.333f))

    @Test(timeout = 90_000) fun physicalPhoneInsetsClearBothBatteryBadges() =
        portrait(360f, 31f, 0f, Rect(170.333f, 0f, 189.667f, 30.333f))

    @Test(timeout = 90_000) fun noCutoutPhoneRetainsRoundedCornerClearance() = portrait(440f, 0f, 0f, null)

    @Test(timeout = 90_000) fun landscapeRetainsTheOriginalPowerSlot() {
        val field = MonitorLayoutPolicy.fieldMonitor(700f, 360f, safeTop = 0f, safeLeading = 31f)
        assertEquals(field.gauges, field.telemetry)
        render(field)
        assertSlot(field)
    }

    @Test(timeout = 90_000) fun legacyScalarConstructionDefaultsTelemetryToGauges() {
        val empty = MonitorRect(0f, 0f, 0f, 0f)
        val gauges = MonitorRect(170f, 80f, 122f, 22f)
        val field = MonitorFieldLayout(viewport = MonitorRect(0f, 0f, 320f, 700f),
            picture = empty, status = empty, values = empty, system = empty, lock = empty,
            gauges = gauges, settings = empty, media = empty, record = empty, display = empty,
            assists = empty, stick = empty, zoom = empty, gimbal = empty, headTrack = empty,
            aspectToggle = empty, focusReset = empty, portrait = true, tablet = false,
            fillsPicture = false, controlsFloor = 0f)
        assertEquals(gauges, field.telemetry)
        render(field, showsStatus = false)
        assertSlot(field)
    }

    private var canvas = Rect.Zero
    private var powerSlot = Rect.Zero
    private val fullStorage = "123456789 GB · 100%"

    private fun portrait(width: Float, safeTop: Float, safeSide: Float, cutout: Rect?) {
        // Only the portrait cases own this host change; the landscape and legacy cases keep theirs.
        device.setOrientationNatural()
        composeRule.waitUntil(5_000) { device.displayHeight > device.displayWidth }
        try {
            val canvasHeight = minOf(700f, hostContentHeightDp())
            val field = MonitorLayoutPolicy.fieldMonitor(width, canvasHeight, safeTop = safeTop,
                safeLeading = safeSide, safeTrailing = safeSide)
            render(field)
            assertSlot(field)
            val density = canvas.width / width
            val cutoutRoot = cutout?.let {
                Rect(canvas.left + it.left * density, canvas.top + it.top * density,
                    canvas.left + it.right * density, canvas.top + it.bottom * density)
            }
            val phone = bounds("Phone battery 100 percent")
            val camera = bounds("Camera battery 5 of 5 bars")
            val storage = composeRule.onNodeWithText(fullStorage).fetchSemanticsNode().boundsInRoot
            val performance = bounds("Live link 4 of 4 delivery bars, feed 25 frames per second")
            for ((name, rect) in listOf("phone" to phone, "camera" to camera,
                "storage" to storage, "performance" to performance)) {
                // Keep the original independent 8 dp canvas-top margin for rounded-corner safety.
                assertTrue("$name enters the canvas-top margin: $rect",
                    rect.top >= canvas.top + 8f * density - 1f)
                if (cutoutRoot != null) {
                    assertFalse("$name enters the actual cutout: $rect $cutoutRoot",
                        rect.overlaps(cutoutRoot))
                }
                assertTrue("$name enters rounded side clearance: $rect", rect.left >= canvas.left + maxOf(16f, safeSide + 8f) * density - 1f)
                assertTrue("$name enters rounded trailing clearance: $rect", rect.right <= canvas.right - maxOf(16f, safeSide + 8f) * density + 1f)
            }
            assertTrue("Storage pushes performance: $storage $performance", storage.right + 8f * density <= performance.left + 1f)
            assertTrue("Performance enters power: $performance $phone", performance.right + 8f * density <= phone.left + 1f)
            assertTrue("Battery badges overlap: $phone $camera", phone.right <= camera.left)
        } finally {
            device.unfreezeRotation()
        }
    }

    // A 700 dp fixture must not be measured in a shorter host: that made every root bound negative.
    private fun hostContentHeightDp(): Float {
        val instrumentation = InstrumentationRegistry.getInstrumentation()
        var heightPx = 0
        instrumentation.runOnMainSync {
            val activity = ActivityLifecycleMonitorRegistry.getInstance()
                .getActivitiesInStage(Stage.RESUMED).firstOrNull()
            heightPx = activity?.findViewById<View>(android.R.id.content)?.height ?: 0
        }
        check(heightPx > 0) {
            "Actual host content height was not measured; cannot size the portrait fixture safely"
        }
        return heightPx / instrumentation.targetContext.resources.displayMetrics.density
    }

    private fun render(field: MonitorFieldLayout, showsStatus: Boolean = true) {
        composeRule.setContent {
            val scope = rememberCoroutineScope()
            val control = remember { MonitorControlModel(scope) }
            Box(Modifier.requiredSize(field.viewport.width.dp, field.viewport.height.dp)
                .onGloballyPositioned { canvas = it.boundsInRoot() }) {
                MonitorScreen(control, field, MonitorScreenPresentation(statusMounted = showsStatus,
                    captureMounted = false), picture = {},
                    status = {
                        MonitorStatusChrome(field, MonitorStatusPresentation(false, timecode = "01:23:45:59"),
                            storage = { MonitorBoundedReadoutText(fullStorage) }, format = {},
                            link = { MonitorTelemetry(4, "25", emptyList(), true, showsPower = false) })
                    }, power = {
                        Box(Modifier.onGloballyPositioned { powerSlot = it.boundsInRoot() }) {
                            MonitorTelemetry(null, null, listOf(MonitorTelemetryPower(false, 100),
                                MonitorTelemetryPower(true, null, bars = 5)),
                                horizontal = field.portrait && !field.tablet, showsLink = false)
                        }
                    })
            }
        }
        composeRule.waitForIdle()
    }

    private fun assertSlot(field: MonitorFieldLayout) {
        val density = canvas.width / field.viewport.width
        assertEquals("Production power slot must use telemetry", canvas.top + field.telemetry.y * density, powerSlot.top, 1f)
        val phone = bounds("Phone battery 100 percent")
        val camera = bounds("Camera battery 5 of 5 bars")
        for (badge in listOf(phone, camera)) {
            assertTrue("Full rendered badge leaves power slot: $badge $powerSlot", badge.left >= powerSlot.left - 1f && badge.right <= powerSlot.right + 1f && badge.top >= powerSlot.top - 1f && badge.bottom <= powerSlot.bottom + 1f)
        }
    }

    private fun bounds(label: String): Rect = composeRule.onNodeWithContentDescription(label).fetchSemanticsNode().boundsInRoot
}
