package com.opencapture.openzcine.gyro

import android.graphics.Bitmap
import android.graphics.Rect
import android.os.SystemClock
import android.os.Build
import android.view.accessibility.AccessibilityNodeInfo
import android.view.WindowManager
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.compose.runtime.mutableStateOf
import androidx.test.core.app.ActivityScenario
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import androidx.test.uiautomator.By
import androidx.test.uiautomator.UiDevice
import com.opencapture.openzcine.OpenZCineTheme
import com.opencapture.openzcine.bridge.SwiftCore
import java.io.File
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith

/** Checks the production screen through Android accessibility without legacy input injection. */
@RunWith(AndroidJUnit4::class)
class GyroMountLayoutTest {
    private val instrumentation = InstrumentationRegistry.getInstrumentation()
    private val device = UiDevice.getInstance(instrumentation)
    private val footer = "Changes apply to the next take. Existing logs keep their recorded mount."

    @Test fun landscapeCalibrationAndManualPresetsRemainReachable() = checkLayout(landscape = true)

    @Test fun portraitCalibrationAndManualPresetsRemainReachable() = checkLayout(landscape = false)

    private fun checkLayout(landscape: Boolean) {
        if (landscape) device.setOrientationLeft() else device.setOrientationNatural()
        try {
            device.waitForIdle()
            assertTrue(SwiftCore.isAvailable)
            val options = decodeGyroMountPresets(SwiftCore.gyroMountPresets(true))
            val state = mutableStateOf(GyroCaptureState(mountOptions = options))
            var attempts = 0
            var closed = false
            ActivityScenario.launch(ComponentActivity::class.java).use { scenario ->
                scenario.onActivity { activity ->
                    activity.window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
                    activity.setContent {
                        OpenZCineTheme {
                            GyroMountScreen(state.value,
                                onSelect = { state.value = state.value.copy(mountPreset = it, mountCalibration = null) },
                                onClose = { closed = true },
                                onCalibrate = { state.value = state.value.copy(calibration = GyroCalibrationState(active = true)) },
                                onCapture = {
                                    val pose = state.value.calibration.poseCount
                                    state.value = when {
                                        pose < 2 -> state.value.copy(calibration = GyroCalibrationState(active = true, poseCount = pose + 1))
                                        ++attempts == 1 -> state.value.copy(calibration = GyroCalibrationState(active = true, poseCount = 2,
                                            error = "The final pose did not match. Reset calibration and try again."))
                                        else -> state.value.copy(calibration = GyroCalibrationState(), mountCalibration = "verified")
                                    }
                                },
                                onCancelCalibration = { state.value = state.value.copy(calibration = GyroCalibrationState()) },
                                onResetCalibration = { state.value = state.value.copy(mountCalibration = null) })
                        }
                    }
                }
                visible("Automatic calibration")
                assertEquals(landscape, device.displayWidth > device.displayHeight)
                screenshot("initial", landscape)
                click("CALIBRATE")
                for (step in 1..3) {
                    visible("Step $step of 3")
                    visible("RESTART")
                    visible("CANCEL")
                    screenshot("step-$step", landscape)
                    click(if (step == 3) "VERIFY" else "CAPTURE")
                }
                visible("The final pose did not match. Reset calibration and try again.")
                visible("RESTART")
                visible("CANCEL")
                screenshot("retry", landscape)
                click("VERIFY")
                visible("Calibrated phone mount")
                visible("RESET")
                screenshot("verified", landscape)
                click("RESET")
                visible("Automatic calibration")
                click("CALIBRATE")
                click("CANCEL")
                visible("Automatic calibration")
                for (attempt in 0 until 12) {
                    if (device.findObject(By.text(footer))?.visibleBounds?.bottom?.let { it < device.displayHeight - 80 } == true) break
                    device.swipe(device.displayWidth / 2, device.displayHeight * 3 / 4,
                        device.displayWidth / 2, device.displayHeight / 3, 20)
                    device.waitForIdle()
                }
                visible(footer)
                visible(options.last().detail)
                screenshot("manual-end", landscape)
                click(options.last().detail)
                scenario.onActivity { assertEquals(options.last().id, state.value.mountPreset) }
                click("CLOSE")
                scenario.onActivity { assertTrue(closed) }
            }
        } finally {
            device.unfreezeRotation()
        }
    }

    private fun visible(text: String): AccessibilityNodeInfo {
        val deadline = SystemClock.uptimeMillis() + 5_000
        while (SystemClock.uptimeMillis() < deadline) {
            instrumentation.waitForIdleSync()
            if (Build.VERSION.SDK_INT >= 34) instrumentation.uiAutomation.clearCache()
            val node = instrumentation.uiAutomation.rootInActiveWindow?.let { findText(it, text) }
            if (node != null) {
                val bounds = Rect().also(node::getBoundsInScreen)
                assertFalse("Empty bounds: $text", bounds.isEmpty)
                assertTrue("Horizontal overflow: $text", bounds.left >= 0 && bounds.right <= device.displayWidth)
                assertTrue("Vertical overflow: $text", bounds.top >= 0 && bounds.bottom <= device.displayHeight)
                return node
            }
            SystemClock.sleep(50)
        }
        error("Missing: $text")
    }

    private fun findText(node: AccessibilityNodeInfo, text: String): AccessibilityNodeInfo? {
        if (node.text?.toString() == text) return node
        for (index in 0 until node.childCount) {
            node.getChild(index)?.let { findText(it, text) }?.let { return it }
        }
        return null
    }

    private fun click(text: String) {
        var node = visible(text)
        while (!node.isClickable) node = requireNotNull(node.parent) { "No action for $text" }
        assertTrue("Action failed: $text", node.performAction(AccessibilityNodeInfo.ACTION_CLICK))
        instrumentation.waitForIdleSync()
    }

    private fun screenshot(name: String, landscape: Boolean) {
        if (InstrumentationRegistry.getArguments().getString("gyroMountScreenshots") != "true") return
        device.waitForIdle()
        val image = requireNotNull(instrumentation.uiAutomation.takeScreenshot())
        try {
            val directory = requireNotNull(instrumentation.targetContext.getExternalFilesDir(null))
            File(directory, "gyro-mount-${if (landscape) "landscape" else "portrait"}-$name.png").outputStream().use {
                check(image.compress(Bitmap.CompressFormat.PNG, 100, it))
            }
        } finally { image.recycle() }
    }
}
