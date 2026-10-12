package com.opencapture.openzcine

import android.content.Context
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.requiredSize
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.ui.Modifier
import androidx.compose.ui.test.ExperimentalTestApi
import androidx.compose.ui.test.click
import androidx.compose.ui.test.hasTestTag
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.test.onNodeWithTag
import androidx.compose.ui.test.performTouchInput
import androidx.compose.ui.unit.dp
import androidx.test.core.app.ApplicationProvider
import androidx.test.ext.junit.runners.AndroidJUnit4
import com.opencapture.opencine.appkit.MonitorControlModel
import com.opencapture.opencine.appkit.MonitorDisplayMode
import com.opencapture.opencine.appkit.MonitorDisplaySection
import com.opencapture.opencine.nikon.CameraIdentity
import com.opencapture.opencine.nikon.CameraPropertySnapshot
import com.opencapture.opencine.nikon.CameraSession
import com.opencapture.opencine.nikon.FakeCameraSession
import com.opencapture.opencine.nikon.NikonOpenCineSession
import com.opencapture.openzcine.settings.OperatorSettings
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.runBlocking
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith

/**
 * The Edit view's eyes on a portrait phone, over the production monitor with an in-memory camera that
 * reports its battery (the demo feed reports none, so it draws no battery band). On a phone with no top
 * cutout the battery band used to sit on the status row, where the CODEC eye landed on the Batteries
 * eye; tapping each eye's centre must toggle its own section.
 */
@OptIn(ExperimentalTestApi::class)
@RunWith(AndroidJUnit4::class)
class ChromeEditPortraitEyesTest {
    @get:Rule val composeRule = createComposeRule()

    @Test
    fun batteriesAndCodecEyesEachToggleTheirOwnSection() {
        val context = ApplicationProvider.getApplicationContext<Context>()
        val settings = OperatorSettings(context.getSharedPreferences("f05-chrome-edit-eyes", Context.MODE_PRIVATE)
            .also { it.edit().clear().commit() })
        val camera = FakeCameraSession(CameraIdentity("SIMULATED", "NIKON ZR", "chrome-edit-eyes"))
            .also { runBlocking { it.connect() } }
        val session = object : CameraSession by camera {
            // A raw Nikon BatteryLevel, so the battery band and its eye are drawn.
            override val cameraProperties: StateFlow<CameraPropertySnapshot> =
                MutableStateFlow(camera.cameraProperties.value.copy(batteryPercent = 58))
        }
        composeRule.setContent {
            val scope = rememberCoroutineScope()
            val common = remember { NikonOpenCineSession(session, scope) }
            val control = remember { MonitorControlModel(scope).also { it.bind(common) } }
            DisposableEffect(Unit) { onDispose { control.unbind() } }
            val assists = remember { idleNikonAssists() }
            val operator = rememberTestOperatorSession(assists, settings)
            LaunchedEffect(operator) { operator.beginEditing(MonitorDisplayMode.LIVE) }
            OpenZCineTheme {
                Box(Modifier.requiredSize(400.dp, 840.dp)) {
                    MonitorScreen(session, common, control, operator, null, assists, settings,
                        liveViewEnabled = false, sessionRecoveryEnabled = false)
                }
            }
        }
        for (section in listOf(MonitorDisplaySection.BATTERIES, MonitorDisplaySection.CODEC)) {
            val eye = "monitor.chromeEdit.${section.key}"
            composeRule.waitUntilAtLeastOneExists(hasTestTag(eye), TIMEOUT_MILLIS)
            val before = visible(settings, section)
            composeRule.onNodeWithTag(eye).performTouchInput { click(center) }
            composeRule.waitUntil(TIMEOUT_MILLIS) { visible(settings, section) != before }
            composeRule.onNodeWithTag(eye).performTouchInput { click(center) }
            composeRule.waitUntil(TIMEOUT_MILLIS) { visible(settings, section) == before }
        }
    }

    private fun visible(settings: OperatorSettings, section: MonitorDisplaySection): Boolean =
        settings.displayPreferences.live.isVisible(section)

    private companion object {
        const val TIMEOUT_MILLIS = 10_000L
    }
}
