package com.opencapture.openzcine

import android.content.Intent
import android.content.pm.ActivityInfo
import android.content.res.Configuration
import android.os.SystemClock
import androidx.test.core.app.ActivityScenario
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import androidx.test.uiautomator.By
import androidx.test.uiautomator.UiDevice
import androidx.test.uiautomator.Until
import com.opencapture.openzcine.settings.CaptureLayoutMode
import com.opencapture.openzcine.settings.ChromeSection
import com.opencapture.openzcine.settings.MonitorDisplayMode
import com.opencapture.openzcine.settings.OperatorSettings
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith

/**
 * The Edit view's eyes on a portrait phone, on the debug demo feed like [CriticalCameraFlowsTest].
 * On a phone with no top cutout the battery band used to sit on the status row, where the CODEC eye
 * landed on the Batteries eye; tapping each eye's centre must toggle its own section.
 */
@RunWith(AndroidJUnit4::class)
class ChromeEditPortraitEyesTest {
    private val instrumentation = InstrumentationRegistry.getInstrumentation()
    private val device = UiDevice.getInstance(instrumentation)
    private val context = instrumentation.targetContext

    @Test
    fun batteriesAndCodecEyesEachToggleTheirOwnSection() {
        val intent =
            Intent(context, MainActivity::class.java)
                .putExtra("zc.demo.feed", true)
                .putExtra("zc.demo.chromeEdit", "live")
        ActivityScenario.launch<MainActivity>(intent).use { scenario ->
            scenario.onActivity { it.requestedOrientation = ActivityInfo.SCREEN_ORIENTATION_PORTRAIT }
            assertTrue("Not portrait", waitFor {
                var portrait = false
                scenario.onActivity { portrait = it.resources.configuration.orientation == Configuration.ORIENTATION_PORTRAIT }
                portrait
            })
            for (section in listOf(ChromeSection.BATTERY_INDICATORS, ChromeSection.CODEC_READOUT)) {
                val eye = device.wait(Until.findObject(By.desc(section.title)), TIMEOUT_MILLIS)
                    ?: throw AssertionError("No ${section.title} eye")
                val centre = eye.visibleCenter
                val before = visible(section)
                device.click(centre.x, centre.y)
                assertTrue("The ${section.title} eye did not toggle ${section.title}", waitFor { visible(section) != before })
                device.click(centre.x, centre.y)
                assertTrue("The ${section.title} eye did not toggle back", waitFor { visible(section) == before })
            }
        }
    }

    private fun visible(section: ChromeSection): Boolean =
        OperatorSettings(context).chrome(MonitorDisplayMode.LIVE, CaptureLayoutMode.VIDEO)[section].value

    private fun waitFor(condition: () -> Boolean): Boolean {
        val deadline = SystemClock.uptimeMillis() + TIMEOUT_MILLIS
        while (SystemClock.uptimeMillis() < deadline) {
            if (condition()) return true
            SystemClock.sleep(100)
        }
        return condition()
    }

    private companion object {
        const val TIMEOUT_MILLIS = 10_000L
    }
}
