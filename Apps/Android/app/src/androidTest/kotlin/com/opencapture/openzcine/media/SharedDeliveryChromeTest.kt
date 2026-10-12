package com.opencapture.openzcine.media

import android.graphics.Bitmap
import android.os.SystemClock
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.test.core.app.ActivityScenario
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import androidx.test.uiautomator.By
import androidx.test.uiautomator.UiDevice
import androidx.test.uiautomator.Until
import com.opencapture.opencine.appkit.MonitorDeliveryBatchOutcome
import com.opencapture.opencine.appkit.MonitorDeliveryBatchProgress
import com.opencapture.opencine.appkit.MonitorDeliveryCoordinator
import com.opencapture.opencine.appkit.MonitorDeliveryDestination
import com.opencapture.opencine.cameracontrols.MonitorOperatorDeliveryChrome
import java.io.File
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.MainScope
import kotlinx.coroutines.cancel
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith

/**
 * The shared root delivery chrome as Z mounts it (A4-10): compact progress, the expanded panel
 * and the outcome toast of a SIMULATED run (no camera), in phone portrait and landscape.
 * Screenshots land in the app's external files under shared-delivery-chrome/.
 */
@RunWith(AndroidJUnit4::class)
class SharedDeliveryChromeTest {
    private val instrumentation = InstrumentationRegistry.getInstrumentation()
    private val device = UiDevice.getInstance(instrumentation)

    @Test fun theChromeShowsProgressDetailAndOutcomeInPortrait() = chrome(landscape = false) { device.setOrientationNatural() }

    @Test fun theChromeShowsProgressDetailAndOutcomeInLandscape() = chrome(landscape = true) { device.setOrientationLeft() }

    private fun chrome(landscape: Boolean, orient: () -> Unit) {
        val orientation = if (landscape) "landscape" else "portrait"
        val scope = MainScope()
        val coordinator = MonitorDeliveryCoordinator(scope)
        val release = CompletableDeferred<Unit>()
        try {
            ActivityScenario.launch(ComponentActivity::class.java).use { scenario ->
                // A launch can replace the orientation the test host had, so rotate after it.
                orient()
                awaitOrientation(landscape)
                device.waitForIdle()
                scenario.onActivity { activity ->
                    activity.setContent {
                        Box(Modifier.fillMaxSize().background(Color.Black)) {
                            MonitorOperatorDeliveryChrome(coordinator, ZMediaShare, { "video/quicktime" })
                        }
                    }
                }
                instrumentation.runOnMainSync {
                    coordinator.begin { _, report ->
                        report(MonitorDeliveryBatchProgress(MonitorDeliveryDestination.NATIVE_SHARE, totalClips = 3,
                            clipIndex = 2, clipFraction = 0.4, isCaching = true, filename = "SIMULATED_0002.MOV",
                            stage = MonitorDeliveryBatchProgress.Stage.CACHING))
                        release.await()
                        MonitorDeliveryBatchOutcome.Failed("SIMULATED: the camera left before the last clip was cached.")
                    }
                }
                assertNotNull(device.wait(Until.findObject(By.textStartsWith("Caching from camera")), TIMEOUT))
                save("$orientation-compact", landscape)
                instrumentation.runOnMainSync { coordinator.lifetime.setExpanded(true) }
                assertNotNull(device.wait(Until.findObject(By.text("Collapse")), TIMEOUT))
                save("$orientation-expanded", landscape)
                release.complete(Unit)
                assertNotNull(device.wait(Until.findObject(By.textStartsWith("SIMULATED: the camera left")), TIMEOUT))
                save("$orientation-outcome", landscape)
            }
        } finally {
            release.complete(Unit)
            instrumentation.runOnMainSync { coordinator.close() }
            scope.cancel()
            device.setOrientationNatural()
        }
    }

    private fun awaitOrientation(landscape: Boolean) {
        val deadline = SystemClock.uptimeMillis() + TIMEOUT
        while ((device.displayWidth > device.displayHeight) != landscape && SystemClock.uptimeMillis() < deadline) {
            SystemClock.sleep(100)
        }
        assertEquals("The phone is in the requested orientation", landscape, device.displayWidth > device.displayHeight)
    }

    private fun save(name: String, landscape: Boolean) {
        device.waitForIdle()
        val folder = File(instrumentation.targetContext.getExternalFilesDir(null), "shared-delivery-chrome")
        assertTrue(folder.mkdirs() || folder.isDirectory)
        // A rotation can still be presenting when the content is found; accept only a frame in
        // the requested orientation.
        val deadline = SystemClock.uptimeMillis() + TIMEOUT
        var bitmap = checkNotNull(instrumentation.uiAutomation.takeScreenshot())
        while ((bitmap.width > bitmap.height) != landscape && SystemClock.uptimeMillis() < deadline) {
            bitmap.recycle(); SystemClock.sleep(200)
            bitmap = checkNotNull(instrumentation.uiAutomation.takeScreenshot())
        }
        try {
            assertEquals("The capture matches the orientation (display rotation ${device.displayRotation}, " +
                "${device.displayWidth}x${device.displayHeight})", landscape, bitmap.width > bitmap.height)
            File(folder, "SIMULATED-$name.png").outputStream().use {
                assertTrue(bitmap.compress(Bitmap.CompressFormat.PNG, 100, it))
            }
        } finally { bitmap.recycle() }
    }

    private companion object { const val TIMEOUT = 10_000L }
}
