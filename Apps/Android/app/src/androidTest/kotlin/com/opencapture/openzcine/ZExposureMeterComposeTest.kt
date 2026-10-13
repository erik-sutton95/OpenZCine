package com.opencapture.openzcine

import android.content.Context
import android.graphics.Bitmap
import android.graphics.Color
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.test.ExperimentalTestApi
import androidx.compose.ui.test.hasContentDescription
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.test.onNodeWithContentDescription
import androidx.compose.ui.test.onNodeWithTag
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import com.opencapture.monitorui.MonitorAssistTool
import com.opencapture.opencine.appkit.MonitorAssistState
import com.opencapture.opencine.appkit.MonitorControlModel
import com.opencapture.opencine.nikon.CameraIdentity
import com.opencapture.opencine.nikon.CameraPropertySnapshot
import com.opencapture.opencine.nikon.CameraSession
import com.opencapture.opencine.nikon.FakeCameraSession
import com.opencapture.opencine.nikon.LiveFrame
import com.opencapture.opencine.nikon.LiveFrameSource
import com.opencapture.opencine.nikon.NikonOpenCineSession
import com.opencapture.openzcine.settings.OperatorSettings
import java.io.ByteArrayOutputStream
import java.io.File
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.flow
import kotlinx.coroutines.runBlocking
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith

/** A3-15: the body's exposure indicator reads through the shared meter at the body's 1/6 EV precision. */
@OptIn(ExperimentalTestApi::class)
@RunWith(AndroidJUnit4::class)
class ZExposureMeterComposeTest {
    @get:Rule val composeRule = createComposeRule()

    @Test fun theBodysSixthsReadThroughTheSharedMeter() {
        show(MeterSession(connected(), sixths = 3, lit = true))
        evidenceShot("a3-15-ev-meter")
        composeRule.waitUntilAtLeastOneExists(hasContentDescription("Camera exposure meter", substring = true), 10_000)
        composeRule.onNodeWithContentDescription("Camera exposure meter, +0.5 EV").assertExists()
        composeRule.onNodeWithContentDescription("EV meter", substring = true).assertDoesNotExist()
    }

    @Test fun anUnlitIndicatorReadsAsUnavailable() {
        show(MeterSession(connected(), sixths = 3, lit = false))
        composeRule.waitUntilAtLeastOneExists(hasContentDescription("Camera exposure meter", substring = true), 10_000)
        composeRule.onNodeWithContentDescription("Camera exposure meter, unavailable").assertExists()
    }

    private fun connected(): FakeCameraSession =
        FakeCameraSession(CameraIdentity("SIMULATED", "NIKON Z", "a3-15")).also { runBlocking { it.connect() } }

    private fun show(session: CameraSession) {
        composeRule.setContent {
            val context = LocalContext.current
            val settings = remember {
                OperatorSettings(context.getSharedPreferences("f11-a3-15", Context.MODE_PRIVATE)
                    .also { it.edit().clear().commit() })
            }
            val scope = rememberCoroutineScope()
            val common = remember { NikonOpenCineSession(session, scope) }
            val control = remember { MonitorControlModel(scope).also { it.bind(common) } }
            DisposableEffect(Unit) { onDispose { control.unbind() } }
            val pictures = remember { GreyPicture() }
            val assists = remember {
                NikonAssists(MonitorAssistState().apply { syncVisible(setOf(MonitorAssistTool.EV)) },
                    FeedLutSelection.BuiltIn(FeedLut.LOG3G10_709)) {}
            }
            OpenZCineTheme {
                MonitorScreen(session, common, control, rememberTestOperatorSession(assists, settings), pictures, assists,
                    settings, liveViewEnabled = true, sessionRecoveryEnabled = false)
            }
        }
    }

    /**
     * Before/after evidence: with the instrumentation argument `f11.shots` set, the composed screen is saved
     * to the app's external files as `<name>-<orientation>.png` once the picture has arrived, before any
     * assertion, so the same test records the screen before and after the change.
     */
    private fun evidenceShot(name: String) {
        val instrumentation = InstrumentationRegistry.getInstrumentation()
        if (InstrumentationRegistry.getArguments().getString("f11.shots") == null) return
        composeRule.waitUntil(10_000) { runCatching {
            composeRule.onNodeWithTag("monitor_live_feed").fetchSemanticsNode() }.isSuccess }
        Thread.sleep(1_500)
        val shot = requireNotNull(instrumentation.uiAutomation.takeScreenshot())
        val orientation = if (shot.width > shot.height) "landscape" else "portrait"
        val directory = requireNotNull(instrumentation.targetContext.getExternalFilesDir(null))
        File(directory, "$name-$orientation.png").outputStream().use { shot.compress(Bitmap.CompressFormat.PNG, 100, it) }
        shot.recycle()
    }

    /** A steady grey picture through the production decoder and feed. */
    private class GreyPicture : LiveFrameSource {
        private val jpeg = ByteArrayOutputStream().use { output ->
            val bitmap = Bitmap.createBitmap(320, 213, Bitmap.Config.ARGB_8888)
            bitmap.eraseColor(Color.rgb(110, 110, 110))
            bitmap.compress(Bitmap.CompressFormat.JPEG, 95, output)
            bitmap.recycle()
            output.toByteArray()
        }
        override val frames = flow {
            while (true) {
                emit(LiveFrame(System.nanoTime(), jpeg))
                delay(100)
            }
        }
    }

    /** The in-memory camera in stills, reporting its exposure indicator in sixths. */
    private class MeterSession(camera: FakeCameraSession, sixths: Int, lit: Boolean) : CameraSession by camera {
        override val cameraProperties: StateFlow<CameraPropertySnapshot> = MutableStateFlow(
            camera.cameraProperties.value.copy(captureSelector = "photo", evIndicatorSixths = sixths, evIndicatorLit = lit))
    }
}
