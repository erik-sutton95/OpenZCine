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
import androidx.compose.ui.test.onRoot
import androidx.compose.ui.test.printToString
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
import org.json.JSONObject
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit

/** Exercises the production settings route and restart persistence without a camera or fake motion. */
@RunWith(AndroidJUnit4::class)
class GyroMountMainActivityTest {
    @get:Rule val compose = createEmptyComposeRule()
    private val instrumentation = InstrumentationRegistry.getInstrumentation()
    private val context = instrumentation.targetContext
    private var activeScenario: ActivityScenario<MainActivity>? = null

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
                activeScenario = scenario
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
            activeScenario = null
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
        awaitNativeFrame()
    }

    private fun selectMount(id: String) {
        compose.onNode(hasScrollAction() and hasAnyAncestor(hasTestTag("gyro-mount")))
            .performScrollToNode(hasTestTag("gyro-mount-$id"))
        awaitNativeFrame()
        recordMountInput(id, "before-click")
        try {
            compose.onNodeWithTag("gyro-mount-$id").performClick()
            compose.waitUntil(5_000) {
                compose.onAllNodes(hasTestTag("gyro-mount-$id") and isSelected()).fetchSemanticsNodes().isNotEmpty()
            }
            compose.onNodeWithTag("gyro-mount-$id").assertIsSelected()
        } catch (failure: Throwable) {
            recordMountInput(id, "failure")
            recordPlatformInputAdmission(id)
            throw failure
        }
    }

    // Diagnostic only: after the original oracle already failed, tap the same current row through
    // the platform input path and retain whether that path invokes setMountPreset. The original
    // failure is rethrown unchanged, so this can neither pass nor weaken the test.
    private fun recordPlatformInputAdmission(id: String) {
        runCatching {
            val node = compose.onNodeWithTag("gyro-mount-$id").fetchSemanticsNode()
            val preferences = context.getSharedPreferences("gyro-logging", Context.MODE_PRIVATE)
            val before = preferences.getString("mountPreset", null) ?: JSONObject.NULL
            UiDevice.getInstance(instrumentation).click(
                ((node.boundsInWindow.left + node.boundsInWindow.right) / 2f).toInt(),
                ((node.boundsInWindow.top + node.boundsInWindow.bottom) / 2f).toInt(),
            )
            instrumentation.waitForIdleSync()
            val after = preferences.getString("mountPreset", null) ?: JSONObject.NULL
            val selected = compose.onAllNodes(hasTestTag("gyro-mount-$id") and isSelected())
                .fetchSemanticsNodes().isNotEmpty()
            val directory = File(context.cacheDir, "SIMULATED-gyro-mount").apply { mkdirs() }
            File(directory, "platform-$id-failure.json").writeText(JSONObject()
                .put("id", id).put("beforePreset", before).put("afterPreset", after)
                .put("selectedAfterPlatformClick", selected)
                .put("boundsInWindow", node.boundsInWindow.toString()).toString(2))
        }.onFailure { android.util.Log.w("GyroMountInput", "Could not retain platform admission for $id", it) }
    }

    // Preserve actual failed input state before ActivityScenario closes the native window.
    private fun recordMountInput(id: String, stage: String) {
        runCatching {
            val directory = File(context.cacheDir, "SIMULATED-gyro-mount").apply { mkdirs() }
            val file = File(directory, "$id-$stage")
            val node = compose.onNodeWithTag("gyro-mount-$id").fetchSemanticsNode()
            val preferences = context.getSharedPreferences("gyro-logging", Context.MODE_PRIVATE)
            val diagnostic = JSONObject().put("id", id).put("stage", stage)
                .put("uptimeMs", android.os.SystemClock.uptimeMillis())
                .put("boundsInRoot", node.boundsInRoot.toString())
                .put("boundsInWindow", node.boundsInWindow.toString())
                .put("mountPreset", preferences.getString("mountPreset", null) ?: JSONObject.NULL)
                .put("mountCalibration", preferences.getString("mountCalibration", null) ?: JSONObject.NULL)
                .put("semantics", compose.onRoot(useUnmergedTree = true).printToString())
            instrumentation.runOnMainSync {
                requireNotNull(activeScenario).onActivity { activity ->
                    val decor = activity.window.decorView
                    val location = IntArray(2).also(decor::getLocationOnScreen)
                    diagnostic.put("decorX", location[0]).put("decorY", location[1])
                        .put("decorWidth", decor.width).put("decorHeight", decor.height)
                        .put("windowFocus", decor.hasWindowFocus()).put("displayRotation", decor.display.rotation)
                }
            }
            File(file.path + ".json").writeText(diagnostic.toString(2))
            instrumentation.uiAutomation.takeScreenshot()?.let { image ->
                try { File(file.path + ".png").outputStream().use {
                    check(image.compress(Bitmap.CompressFormat.PNG, 100, it))
                } } finally { image.recycle() }
            }
        }.onFailure { android.util.Log.w("GyroMountInput", "Could not retain $id $stage diagnostic", it) }
    }

    // Semantics can advance before MainActivity's native decor draws the new page or scroll.
    // Commit that exact window before input, independently of the selected preset oracle.
    private fun awaitNativeFrame() {
        compose.waitForIdle()
        val scenario = requireNotNull(activeScenario)
        val committed = CountDownLatch(1)
        val callback = Runnable { committed.countDown() }
        var removeCallback: (() -> Unit)? = null
        var verifyOwner: ((MainActivity) -> Unit)? = null
        try {
            instrumentation.runOnMainSync {
                scenario.onActivity { activity ->
                    val window = activity.window
                    val decor = window.decorView
                    val token = decor.windowToken
                    val observer = decor.viewTreeObserver
                    val width = decor.width
                    val height = decor.height
                    check(!activity.isDestroyed && !activity.isFinishing && token != null &&
                        decor.isAttachedToWindow && decor.isShown && decor.hasWindowFocus() &&
                        decor.isHardwareAccelerated && observer.isAlive) { "The current mount window must accept native input" }
                    verifyOwner = { current ->
                        check(current === activity && current.window === window && window.peekDecorView() === decor &&
                            decor.windowToken === token && decor.width == width && decor.height == height &&
                            decor.isAttachedToWindow && decor.hasWindowFocus() &&
                            !current.isDestroyed && !current.isFinishing) { "The mount window retired before native input" }
                    }
                    removeCallback = { if (observer.isAlive) observer.unregisterFrameCommitCallback(callback) }
                    observer.registerFrameCommitCallback(callback)
                    decor.invalidate()
                }
            }
            check(committed.await(5_000, TimeUnit.MILLISECONDS)) { "The current mount window must commit its native frame" }
            scenario.onActivity { requireNotNull(verifyOwner)(it) }
        } finally {
            instrumentation.runOnMainSync { removeCallback?.invoke() }
        }
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
