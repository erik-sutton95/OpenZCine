package com.opencapture.openzcine.gyro

import android.content.Context
import android.content.Intent
import android.content.pm.ActivityInfo
import android.graphics.Bitmap
import android.hardware.display.DisplayManager
import android.view.Display
import androidx.compose.ui.test.assertCountEquals
import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.assertIsSelected
import androidx.compose.ui.test.hasAnyAncestor
import androidx.compose.ui.test.hasScrollAction
import androidx.compose.ui.test.hasTestTag
import androidx.compose.ui.test.hasText
import androidx.compose.ui.test.isSelected
import androidx.compose.ui.test.junit4.v2.createEmptyComposeRule
import androidx.compose.ui.test.onAllNodesWithText
import androidx.compose.ui.test.onAllNodesWithTag
import androidx.compose.ui.test.onNodeWithTag
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.performClick
import androidx.compose.ui.test.performScrollTo
import androidx.compose.ui.test.performScrollToNode
import androidx.test.core.app.ActivityScenario
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import androidx.test.uiautomator.By
import androidx.test.uiautomator.UiDevice
import androidx.test.uiautomator.Until
import com.opencapture.openzcine.MainActivity
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import java.io.File

/** Exercises the production settings route and restart persistence without a camera or fake motion. */
@RunWith(AndroidJUnit4::class)
class GyroMountMainActivityTest {
    @get:Rule val compose = createEmptyComposeRule()
    private val instrumentation = InstrumentationRegistry.getInstrumentation()
    private val context = instrumentation.targetContext

    @Test fun controlsConfigureMountAndRetainSelectionAfterActivityRecreation() {
        val preferences = context.getSharedPreferences("gyro-logging", Context.MODE_PRIVATE)
        val saved = preferences.getString("mountPreset", null)
        val savedCalibration = preferences.getString("mountCalibration", null)
        val enabled = preferences.getBoolean("enabled", false)
        preferences.edit().putString("mountPreset", "unconfigured").remove("mountCalibration")
            .putBoolean("enabled", false).commit()
        try {
            ActivityScenario.launch<MainActivity>(Intent(context, MainActivity::class.java)
                .putExtra("zc.demo.settings", "controls")).use { scenario ->
                scenario.onActivity { it.requestedOrientation = ActivityInfo.SCREEN_ORIENTATION_LANDSCAPE }
                waitForConfigure()
                val device = UiDevice.getInstance(instrumentation)
                device.wait(Until.findObject(By.text("Got it")), 2_000)?.let {
                    it.click()
                    check(device.wait(Until.gone(By.text("Got it")), 5_000))
                }
                saveScreenshot("controls")
                openMount()
                saveScreenshot("intro")
                val mode = context.getSystemService(DisplayManager::class.java)?.getDisplay(Display.DEFAULT_DISPLAY)?.mode
                if (mode == null || mode.physicalWidth >= mode.physicalHeight) {
                    assertUnconfiguredOnly()
                    closeMount()
                    scenario.recreate()
                    waitForConfigure()
                    compose.onNodeWithText("Unconfigured").assertIsDisplayed()
                    openMount()
                    assertUnconfiguredOnly()
                    closeMount()
                    return
                }
                selectMount("rearLeft")
                saveScreenshot("selected")
                closeMount()
                compose.onNodeWithText("USB-C left").assertIsDisplayed()
                scenario.recreate()
                waitForConfigure()
                compose.onNodeWithText("USB-C left").assertIsDisplayed()
                saveScreenshot("persisted")
                openMount()
                selectMount("frontUp")
                saveScreenshot("lens-presets")
                closeMount()
                compose.onNodeWithText("USB-C up").assertIsDisplayed()
                saveScreenshot("configured")
            }
        } finally {
            preferences.edit().putString("mountPreset", saved).putString("mountCalibration", savedCalibration)
                .putBoolean("enabled", enabled).commit()
        }
    }

    private fun waitForConfigure() {
        compose.waitUntil(10_000) {
            compose.onAllNodesWithText("CONFIGURE").fetchSemanticsNodes().isNotEmpty()
        }
        compose.onNodeWithText("CONFIGURE").performScrollTo().assertIsDisplayed()
    }

    private fun openMount() {
        compose.onNodeWithText("CONFIGURE").performClick()
        compose.onNodeWithTag("gyro-mount").assertIsDisplayed()
    }

    private fun selectMount(id: String) {
        compose.onNode(hasScrollAction() and hasAnyAncestor(hasTestTag("gyro-mount")))
            .performScrollToNode(hasTestTag("gyro-mount-$id"))
        compose.onNodeWithTag("gyro-mount-$id").performClick()
        compose.waitUntil(5_000) {
            compose.onAllNodes(hasTestTag("gyro-mount-$id") and isSelected()).fetchSemanticsNodes().isNotEmpty()
        }
        compose.onNodeWithTag("gyro-mount-$id").assertIsSelected()
    }

    private fun closeMount() {
        compose.onNode(hasText("CLOSE") and hasAnyAncestor(hasTestTag("gyro-mount"))).performClick()
    }

    private fun assertUnconfiguredOnly() {
        compose.onNodeWithTag("gyro-mount-unconfigured").assertIsSelected()
        compose.onAllNodesWithTag("gyro-mount-rearLeft").assertCountEquals(0)
        compose.onAllNodesWithTag("gyro-mount-frontUp").assertCountEquals(0)
        compose.onAllNodesWithText("Screen toward you").assertCountEquals(0)
        compose.onAllNodesWithText("Screen toward lens").assertCountEquals(0)
    }

    private fun saveScreenshot(name: String) {
        if (InstrumentationRegistry.getArguments().getString("gyroMountScreenshots") != "true") return
        compose.mainClock.advanceTimeBy(500)
        compose.waitForIdle()
        instrumentation.uiAutomation.waitForIdle(500, 5_000)
        val image = requireNotNull(instrumentation.uiAutomation.takeScreenshot())
        try {
            check(image.width > image.height) { "The mount flow must be verified in landscape." }
            File(requireNotNull(context.getExternalFilesDir(null)), "mount-flow-$name.png").outputStream().use {
                check(image.compress(Bitmap.CompressFormat.PNG, 100, it))
            }
        } finally { image.recycle() }
    }
}
