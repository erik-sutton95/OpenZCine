package com.opencapture.openzcine

import android.content.Intent
import androidx.test.core.app.ActivityScenario
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import androidx.test.uiautomator.By
import androidx.test.uiautomator.UiDevice
import androidx.test.uiautomator.UiObject2
import androidx.test.uiautomator.Until
import org.junit.After
import org.junit.Test
import org.junit.runner.RunWith

/**
 * End-to-end UI coverage for the flows that must remain camera-safe:
 * connection, record start/stop, and live-view activation.
 *
 * These launch the production [MainActivity] with its debug-only fake seams:
 * `zc.demo.pairing=connecting` hands the UI a scripted in-memory session and
 * `zc.demo.feed=true` supplies an in-memory session plus synthetic frames.
 * They never contact a camera, a socket, NSD, or Wi-Fi. UiAutomator observes
 * the accessibility tree directly so the monitor's intentional live frame
 * and timecode loops do not make the test runner wait forever for Compose
 * idleness. Record-control coverage lives in [RecordCameraFlowComposeTest],
 * which invokes the same control through Compose semantics rather than a
 * coordinate gesture. Run them on an arm64-v8a device or emulator with
 * `just android-ui-test`; CI compiles the test APK through `just android-check`
 * but intentionally has no hardware runner.
 */
@RunWith(AndroidJUnit4::class)
class CriticalCameraFlowsTest {
    private val instrumentation = InstrumentationRegistry.getInstrumentation()
    private val device: UiDevice = UiDevice.getInstance(instrumentation)
    private var scenario: ActivityScenario<MainActivity>? = null

    @After
    fun closeActivity() {
        scenario?.close()
        scenario = null
    }

    @Test
    fun scriptedPairingShowsConnectingThenConnectedCamera() {
        relaunch(launchMainActivity().putExtra(EXTRA_PAIRING_STEP, PAIRING_CONNECTING))

        device.waitForText("Connecting to your camera…", CONNECTING_TIMEOUT_MILLIS)
        device.waitForContentDescription(CAMERA_CONNECTED, CONNECTION_TIMEOUT_MILLIS)
    }

    @Test
    fun fakeCameraActivatesLiveView() {
        relaunch(launchMainActivity().putExtra(EXTRA_DEMO_FEED, true))

        device.waitForContentDescription(LIVE_VIEW, LIVE_VIEW_TIMEOUT_MILLIS)
    }

    private fun launchMainActivity(): Intent =
        Intent(instrumentation.targetContext, MainActivity::class.java)

    private fun relaunch(intent: Intent) {
        scenario?.close()
        scenario = ActivityScenario.launch(intent)
    }

    private fun UiDevice.waitForText(text: String, timeoutMillis: Long): UiObject2 =
        wait(Until.findObject(By.text(text)), timeoutMillis)
            ?: throw AssertionError("Timed out waiting for text: $text")

    private fun UiDevice.waitForContentDescription(
        description: String,
        timeoutMillis: Long,
    ): UiObject2 =
        wait(Until.findObject(By.desc(description)), timeoutMillis)
            ?: throw AssertionError("Timed out waiting for description: $description")

    private companion object {
        const val EXTRA_DEMO_FEED = "zc.demo.feed"
        const val EXTRA_PAIRING_STEP = "zc.demo.pairing"
        const val PAIRING_CONNECTING = "connecting"
        const val LIVE_VIEW = "Live view active"
        const val CAMERA_CONNECTED = "Camera connected"
        const val LIVE_VIEW_TIMEOUT_MILLIS = 10_000L
        const val CONNECTING_TIMEOUT_MILLIS = 5_000L
        const val CONNECTION_TIMEOUT_MILLIS = 15_000L
    }
}
