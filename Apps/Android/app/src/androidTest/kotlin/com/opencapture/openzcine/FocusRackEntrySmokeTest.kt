package com.opencapture.openzcine

import android.content.Context
import android.content.Intent
import android.content.pm.ActivityInfo
import android.content.res.Configuration
import android.graphics.Rect
import android.os.Build
import android.os.SystemClock
import android.view.accessibility.AccessibilityWindowInfo
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import androidx.test.uiautomator.By
import androidx.test.uiautomator.Configurator
import androidx.test.uiautomator.UiDevice
import androidx.test.uiautomator.UiObject2
import androidx.test.uiautomator.Until
import com.opencapture.monitorui.MonitorAssistTool
import com.opencapture.monitorui.MonitorScopeStoredCenter
import com.opencapture.openzcine.settings.OperatorSettings
import com.opencapture.opencine.cameracontrols.PortraitFeedAspect
import java.io.File
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.After
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith

/** Real monitor composition over the synthetic demo feed; these tests never connect to a camera. */
@RunWith(AndroidJUnit4::class)
class FocusRackEntrySmokeTest {
    private val instrumentation = InstrumentationRegistry.getInstrumentation()
    private val context = instrumentation.targetContext
    private val device = UiDevice.getInstance(instrumentation)
    private var idleTimeout = 0L

    @Before fun useExplicitElementWaitsForContinuousDemoFrames() {
        idleTimeout = Configurator.getInstance().waitForIdleTimeout
        Configurator.getInstance().setWaitForIdleTimeout(0)
        refreshAccessibilityCache()
    }

    @After fun restoreIdleWait() { Configurator.getInstance().setWaitForIdleTimeout(idleTimeout) }

    @Test fun landscapeFocusModesExposeNativeTargetsAndReturnToTimedRackWithoutMovement() {
        withDemoRack(portrait = false) {
            val native = device.wait(Until.findObject(By.text("Native AF")), 5_000)
                ?: throw AssertionError("No Native AF mode selector")
            native.click()
            for (mark in listOf("A", "B")) {
                val target = device.wait(Until.findObject(By.text("$mark not set")), 5_000)
                    ?: throw AssertionError("Native AF target $mark did not appear")
                assertInsideDisplay(target.visibleBounds)
                assertTrue("Native AF must offer Set $mark", device.hasObject(By.text("Set $mark")))
                val go = device.findObject(By.text("Go to $mark"))
                    ?: throw AssertionError("Native AF must offer Go to $mark")
                assertFalse("An unset target must not enable movement", clickableControl(go).isEnabled)
            }
            device.waitForIdle(1_000)
            refreshAccessibilityCache()
            saveDisplay("focus-modes-native-af-monitor-landscape")
            assertTrue("Native AF must not show timed transport", device.wait(Until.gone(By.text("Set A and B")), 5_000))
            assertFalse("Native AF must not show a duration editor", device.hasObject(By.text("Duration")))
            saveDisplay("focus-modes-native-af-monitor-landscape")
            device.wait(Until.findObject(By.text("Timed Rack")), 5_000)?.click()
                ?: throw AssertionError("No Timed Rack mode selector")
            refreshAccessibilityCache()
            assertTrue("Native targets did not close", device.wait(Until.gone(By.text("A not set")), 5_000))
            assertTrue("Timed transport did not return", device.wait(Until.hasObject(By.text("Set A and B")), 5_000))
            SystemClock.sleep(200)
            saveDisplay("focus-modes-timed-rack-monitor-landscape")
        }
    }

    @Test fun landscapeEntryKeepsSavedWaveformCentreAndOpensSharedTimingEditor() {
        val preferences = context.getSharedPreferences("assist", Context.MODE_PRIVATE)
        val original = preferences.getString("monitorAssist.v1", null)
        try {
            val saved = MonitorScopeStoredCenter(0.9, 0.5)
            restoreNikonAssists(context).shared.storeCenter(MonitorAssistTool.WAVE, saved)
            withDemoRack(portrait = false, waveform = true) {
                assertEquals(saved, restoreNikonAssists(context).shared.centerFor(MonitorAssistTool.WAVE, false))
                // The full scene records actual waveform clearance beside the shared accessory corridor.
                saveDisplay("focus-rack-production-demo-waveform-landscape")
                verifyHeaderMovesPanel()
                assertEquals(saved, restoreNikonAssists(context).shared.centerFor(MonitorAssistTool.WAVE, false))
            }
        } finally {
            preferences.edit().apply {
                if (original == null) remove("monitorAssist.v1") else putString("monitorAssist.v1", original)
            }.commit()
        }
    }

    @Test fun cleanCompactSetupOpensInOneTapWithoutResettingTheRack() {
        for (expanded in listOf(true, false)) {
            withDemoRack(portrait = false) {
                val originalPositions = rackPositions()
                if (!expanded) {
                    clickableControl(requireNotNull(device.findObject(By.desc("Collapse focus rack")))).click()
                }
                clickableControl(requireNotNull(device.findObject(By.text("DISP")))).click()
                assertTrue("Clean display must hide the focus readout",
                    device.wait(Until.gone(By.descStartsWith("FOCUS ")), 5_000))
                val open = device.wait(Until.findObject(By.desc("Open focus rack setup")), 5_000)
                    ?: throw AssertionError("Clean compact rack has no Open setup action")
                clickableControl(open).click()
                assertTrue("One tap must return to expanded setup",
                    device.wait(Until.hasObject(By.desc("Collapse focus rack")), 5_000))
                assertTrue("One tap must return to Live display",
                    device.wait(Until.hasObject(By.descStartsWith("FOCUS ")), 5_000))
                assertEquals(originalPositions, rackPositions())
                for (mark in listOf("A", "B")) assertTrue(device.hasObject(By.text("Set $mark")))
                for (mode in listOf("Native AF", "Timed Rack")) assertTrue(device.hasObject(By.text(mode)))
                scrollSetupToTop()
                rackText("Target duration")
                saveDisplay("focus-rack-clean-open-${if (expanded) "expanded" else "collapsed"}-landscape")
            }
        }
    }

    @Test fun portraitDefaultFitOpenExposesMarksAndMoveSetup() {
        val settings = OperatorSettings(context)
        val original = settings.portraitFeedAspect
        settings.portraitFeedAspect = PortraitFeedAspect.FIT_16X9
        try {
            withDemoRack(portrait = true) {
                device.findObject(By.desc("Collapse focus rack"))?.let { clickableControl(it).click() }
                val opening = device.wait(Until.findObject(By.desc("Open focus rack setup")), 5_000)
                    ?: throw AssertionError("No compact Open action in portrait fit")
                saveDisplay("focus-rack-production-demo-portrait-before-open")
                clickableControl(opening).click()
                device.waitForIdle(1_000)
                for (id in listOf("A", "B")) {
                    val mark = device.wait(Until.findObject(By.text("Set $id")), 5_000)
                        ?: throw AssertionError("No fixed Set $id card after expanding")
                    assertInsideDisplay(clickableControl(mark).visibleBounds)
                }
                saveDisplay("focus-rack-production-demo-portrait-after-open")
                assertFalse("Unified setup has no Marks tab", device.hasObject(By.text("Marks")))
                assertFalse("Unified setup has no Move tab", device.hasObject(By.text("Move")))
            }
        } finally { settings.portraitFeedAspect = original }
    }

    private fun withDemoRack(portrait: Boolean, waveform: Boolean = false, verify: (UiObject2) -> Unit) {
        val intent = Intent(context, MainActivity::class.java).putExtra("zc.demo.feed", true)
            .putExtra("zc.demo.freezeFeed", true)
        if (waveform) intent.putExtra("zc.scopes", "wave")
        // Launch the full monitor without ActivityScenario's global-idle wait.
        val monitor = instrumentation.addMonitor(MainActivity::class.java.name, null, false)
        val activity = try {
            context.startActivity(intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TASK))
            monitor.waitForActivityWithTimeout(10_000)
                ?: throw AssertionError("Demo monitor activity did not start")
        } finally { instrumentation.removeMonitor(monitor) }
        try {
            instrumentation.runOnMainSync { activity.requestedOrientation = if (portrait)
                ActivityInfo.SCREEN_ORIENTATION_PORTRAIT else ActivityInfo.SCREEN_ORIENTATION_LANDSCAPE }
            val expected = if (portrait) Configuration.ORIENTATION_PORTRAIT else Configuration.ORIENTATION_LANDSCAPE
            val deadline = SystemClock.uptimeMillis() + 5_000
            var oriented = false
            while (!oriented && SystemClock.uptimeMillis() < deadline) {
                instrumentation.runOnMainSync { oriented = activity.resources.configuration.orientation == expected }
                if (!oriented) SystemClock.sleep(50)
            }
            assertTrue("Demo monitor did not reach its requested orientation", oriented)
            assertTrue("No demo live view", device.wait(Until.hasObject(By.descContains("Live view active")), 10_000))
            device.waitForIdle(1_000)
            refreshAccessibilityCache()
            val focus = device.wait(Until.findObject(By.descStartsWith("FOCUS ")), 5_000)
                ?: throw AssertionError("No FOCUS entry on demo monitor")
            focus.click()
            device.wait(Until.findObject(By.text("Focus Rack")), 5_000)
                ?: throw AssertionError("FOCUS popup does not expose Focus Rack")
            device.waitForIdle(1_000)
            refreshAccessibilityCache()
            val entry = device.wait(Until.findObject(By.text("Focus Rack")), 5_000)
                ?: throw AssertionError("FOCUS popup entry disappeared before tapping")
            saveDisplay("focus-rack-production-demo-entry-${if (portrait) "portrait" else "landscape"}")
            clickableControl(entry).click()
            val close = device.wait(Until.findObject(By.desc("Close Focus Rack")), 5_000)
                ?: run {
                    saveDisplay("focus-rack-entry-missing-${if (portrait) "portrait" else "landscape"}")
                    device.dumpWindowHierarchy(File(context.cacheDir, "diagnostics/ready/focus-rack-entry-missing.xml"))
                    throw AssertionError("Focus Rack did not open")
                }
            assertFalse("Idle rack must not show Stop", device.hasObject(By.text("Stop")))
            val primary = device.wait(Until.findObjects(By.text("Set A and B")), 5_000)
                ?.maxByOrNull { it.visibleBounds.bottom }
                ?: throw AssertionError("No idle rack primary action")
            assertFalse("Demo feed must not enable rack movement", requireNotNull(primary.parent).isEnabled)
            assertInsideDisplay(close.visibleBounds)
            verify(close)
            verifySharedMoveEditor(portrait)
            if (!portrait) verifyFocusSettingsRoute()
        } catch (error: Throwable) {
            saveDisplay("auto-af-route-failure")
            device.dumpWindowHierarchy(File(context.cacheDir, "diagnostics/ready/auto-af-route-failure.xml"))
            throw error
        } finally { instrumentation.runOnMainSync { activity.finish() } }
    }

    private fun verifyHeaderMovesPanel() {
        val selector = By.desc("Move Focus Rack panel")
        val handle = device.wait(Until.findObject(selector), 5_000)
            ?: throw AssertionError("No rack header drag handle")
        val before = handle.visibleBounds
        device.swipe(before.centerX(), before.centerY(), before.centerX() - device.displayWidth / 4,
            before.centerY(), 30)
        val deadline = SystemClock.uptimeMillis() + 5_000
        var moved = false
        while (!moved && SystemClock.uptimeMillis() < deadline) {
            refreshAccessibilityCache()
            moved = device.findObject(selector)?.visibleBounds?.left?.let { it < before.left - 50 } == true
            if (!moved) SystemClock.sleep(50)
        }
        assertTrue("Dragging the header must move the real monitor panel", moved)
        assertInsideDisplay(requireNotNull(device.findObject(selector)).visibleBounds)
        saveDisplay("focus-rack-production-demo-moved-landscape")
    }

    private fun rackText(prefix: String): UiObject2 {
        val minimumTouch = (48 * context.resources.displayMetrics.density).toInt()
        val minimumPan = (20 * context.resources.displayMetrics.density).toInt()
        repeat(20) {
            refreshAccessibilityCache()
            val viewport = device.wait(Until.findObject(By.desc("Focus rack setup")), 5_000)?.visibleBounds
                ?: throw AssertionError("No focus rack setup scroller")
            val label = device.findObject(By.textStartsWith(prefix))
            val bounds = label?.let { clickableControl(it).visibleBounds }
            if (label != null && bounds != null && bounds.height() >= minimumTouch - 1 &&
                viewport.contains(bounds)) {
                SystemClock.sleep(200)
                refreshAccessibilityCache()
                val settled = device.findObject(By.textStartsWith(prefix))
                if (settled != null && clickableControl(settled).visibleBounds == bounds) return settled
                return@repeat
            }
            val upward = bounds == null || bounds.bottom >= viewport.bottom
            val travel = if (bounds == null) viewport.height() * 3 / 4 else minimumPan
            val start = if (upward) viewport.bottom - viewport.height() / 8 else
                viewport.top + viewport.height() / 8
            device.swipe(viewport.centerX(), start, viewport.centerX(),
                start + if (upward) -travel else travel, if (bounds == null) 40 else 100)
        }
        saveDisplay("focus-rack-missing-control")
        val scene = File(context.cacheDir, "diagnostics/ready/focus-rack-missing-control.xml")
        device.dumpWindowHierarchy(scene)
        throw AssertionError("Rack control is missing: $prefix")
    }

    private fun scrollSetupToTop() {
        val viewport = device.findObject(By.desc("Focus rack setup"))?.visibleBounds
            ?: throw AssertionError("No focus rack setup scroller")
        repeat(3) {
            device.swipe(viewport.centerX(), viewport.top + viewport.height() / 8,
                viewport.centerX(), viewport.bottom - viewport.height() / 8, 40)
        }
        refreshAccessibilityCache()
    }

    private fun rackPositions(): String {
        repeat(12) {
            refreshAccessibilityCache()
            device.findObject(By.descStartsWith("Relative focus steps:"))?.contentDescription?.let { return it }
            val viewport = device.findObject(By.desc("Focus rack setup"))?.visibleBounds
                ?: throw AssertionError("No focus rack setup scroller")
            device.swipe(viewport.centerX(), viewport.bottom - viewport.height() / 8,
                viewport.centerX(), viewport.top + viewport.height() / 8, 40)
        }
        throw AssertionError("Relative position is missing from mark editing")
    }

    private fun verifySharedMoveEditor(portrait: Boolean) {
        val durationLabel = rackText("Target duration")
        val duration = clickableControl(durationLabel)
        saveDisplay("focus-rack-production-demo-move-${if (portrait) "portrait" else "landscape"}")
        assertTrue("Offline shared controller must enable timing edits", duration.isEnabled)
        duration.click()
        val apply = device.wait(Until.findObject(By.text("Apply")), 5_000)
            ?: throw AssertionError("Shared timing editor did not open")
        assertInsideDisplay(apply.visibleBounds)
        saveDisplay("focus-rack-production-demo-editor-${if (portrait) "portrait" else "landscape"}")
        val cancel = device.findObject(By.text("Cancel"))
            ?: throw AssertionError("Timing editor has no Cancel action")
        clickableControl(cancel).click()
        assertTrue("Timing editor must dismiss before returning to setup", device.wait(Until.gone(By.text("Apply")), 5_000))
    }

    private fun verifyFocusSettingsRoute() {
        val deadline = SystemClock.uptimeMillis() + 5_000
        fun keyboardVisible(): Boolean = instrumentation.uiAutomation.windows.any {
            it.type == AccessibilityWindowInfo.TYPE_INPUT_METHOD
        }
        while (keyboardVisible() && SystemClock.uptimeMillis() < deadline) SystemClock.sleep(50)
        assertFalse("Keyboard must dismiss before opening Options", keyboardVisible())
        clickableControl(rackText("Options")).click()
        var settings: UiObject2? = rackText("Focus settings")
        saveDisplay("focus-rack-production-demo-marks-scrolled-landscape")
        val scene = File(context.cacheDir, "diagnostics/ready/focus-rack-production-demo-marks-scrolled-landscape.xml")
        refreshAccessibilityCache()
        device.dumpWindowHierarchy(scene)
        refreshAccessibilityCache()
        settings = device.wait(Until.findObject(By.textContains("Focus settings")), 2_000)
        clickableControl(settings ?: throw AssertionError("Visible Focus settings is missing from accessibility")).click()
        val close = device.wait(Until.findObject(By.desc("Close camera control")), 5_000)
            ?: throw AssertionError("Focus settings popup did not open")
        device.waitForIdle(1_000)
        saveDisplay("focus-rack-production-demo-focus-settings-landscape")
        assertInsideDisplay(close.visibleBounds)
        clickableControl(close).click()
        assertTrue("Camera focus popup Close must stay reachable beside the rack",
            device.wait(Until.gone(By.desc("Close camera control")), 5_000))
    }

    private fun refreshAccessibilityCache() {
        if (Build.VERSION.SDK_INT >= 34) instrumentation.uiAutomation.clearCache()
    }

    private fun clickableControl(node: UiObject2): UiObject2 {
        var current = node
        while (!current.isClickable) {
            current = current.parent ?: throw AssertionError("Control has no clickable ancestor")
        }
        return current
    }

    private fun assertInsideDisplay(bounds: Rect) {
        assertTrue("Every control edge must fit inside the display", bounds.width() > 0 && bounds.height() > 0 &&
            bounds.left >= 0 && bounds.top >= 0 && bounds.right <= device.displayWidth && bounds.bottom <= device.displayHeight)
    }

    private fun saveDisplay(name: String) {
        val directory = File(context.cacheDir, "diagnostics/ready")
        check(directory.mkdirs() || directory.isDirectory)
        assertTrue(device.takeScreenshot(File(directory, "$name.png")))
    }
}
