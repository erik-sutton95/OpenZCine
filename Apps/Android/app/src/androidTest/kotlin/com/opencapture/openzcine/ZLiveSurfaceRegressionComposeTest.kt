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
import androidx.compose.ui.test.performClick
import androidx.compose.ui.test.performTouchInput
import androidx.compose.ui.test.swipeDown
import androidx.compose.ui.test.swipeUp
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import com.opencapture.opencine.appkit.MonitorControlModel
import com.opencapture.opencine.nikon.CameraIdentity
import com.opencapture.opencine.nikon.CameraPropertySnapshot
import com.opencapture.opencine.nikon.CameraSession
import com.opencapture.opencine.nikon.FakeCameraSession
import com.opencapture.opencine.nikon.LiveFrame
import com.opencapture.opencine.nikon.LiveFrameSource
import com.opencapture.opencine.nikon.MFDriveOutcome
import com.opencapture.opencine.nikon.NikonOpenCineSession
import com.opencapture.openzcine.settings.OperatorSettings
import java.io.ByteArrayOutputStream
import java.util.concurrent.atomic.AtomicInteger
import kotlin.math.roundToInt
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.flow
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith

/** The F05 P1 regressions, each against the production Z monitor composition with an in-memory camera. */
@OptIn(ExperimentalTestApi::class)
@RunWith(AndroidJUnit4::class)
class ZLiveSurfaceRegressionComposeTest {
    @get:Rule val composeRule = createComposeRule()

    /** A3-01: a multicam member lent to Live View returns to the stage from the lock slot; Media stays with the stage. */
    @Test fun lentMemberReturnsToMultiviewAndLeavesMediaWithTheStage() {
        val returned = AtomicInteger()
        show(connected("a3-01"), "a3-01", returnToStage = { returned.incrementAndGet() })
        composeRule.waitUntilAtLeastOneExists(hasContentDescription(RETURN_TO_MULTIVIEW), TIMEOUT_MILLIS)
        composeRule.onNodeWithTag("monitor.system.media").assertDoesNotExist()
        composeRule.onNodeWithContentDescription(RETURN_TO_MULTIVIEW).performClick()
        composeRule.runOnIdle { assertEquals(1, returned.get()) }
    }

    /** A3-02: while a watcher holds control the MF strip stays inert: no drive reaches the lens. */
    @Test fun surrenderedControlNeverDrivesTheLens() {
        val session = DriveCountingSession(connected("a3-02"))
        show(session, "a3-02", surrendered = true) { it.mfDriveScrubEnabled.value = true }
        composeRule.waitUntilAtLeastOneExists(hasContentDescription(MF_STRIP, substring = true), TIMEOUT_MILLIS)
        composeRule.onNodeWithContentDescription(MF_STRIP, substring = true).performTouchInput { swipeUp(); swipeDown() }
        // A drive is launched from the drag; give an unguarded strip time to reach the session.
        runCatching { composeRule.waitUntil(3_000) { session.drives.get() > 0 } }
        assertEquals("The lens moved without control authority", 0, session.drives.get())
    }

    /** A3-04: the picture is what the camera sent. A flat grey frame stays flat across the picture: no vignette. */
    @Test fun aFlatGreyFrameRendersUniformlyAcrossThePicture() {
        show(connected("a3-04"), "a3-04", frames = FlatPictureSource(Color.rgb(128, 128, 128)), liveView = true)
        // Wait for the first decoded picture: the centre of the feed reads the source grey.
        composeRule.waitUntil(10_000) { runCatching { feedSample().centre in 108..148 }.getOrDefault(false) }
        val sample = feedSample()
        println("A3-04 centre=${sample.centre} darkened=${sample.darkenedPercent}% of ${sample.count} samples")
        assertTrue("${sample.darkenedPercent}% of the picture's middle band reads darker than the frame the camera " +
            "sent (centre ${sample.centre})", sample.darkenedPercent < 10)
    }

    /** A5-01: the body's five-step battery reads as its bars in the live status, never a percent. */
    @Test fun theCameraBatteryReadsAsTheBodysBars() {
        show(BatterySession(connected("a5-01"), rawLevel = 58), "a5-01")
        composeRule.waitUntilAtLeastOneExists(hasContentDescription("Camera battery", substring = true), TIMEOUT_MILLIS)
        composeRule.onNodeWithContentDescription("Camera battery 3 of 5 bars", substring = true).assertExists()
    }

    private fun connected(serial: String): FakeCameraSession =
        FakeCameraSession(CameraIdentity("SIMULATED", "NIKON ZR", serial)).also { runBlocking { it.connect() } }

    private fun show(
        session: CameraSession, name: String, frames: LiveFrameSource? = null, liveView: Boolean = false,
        surrendered: Boolean = false, returnToStage: (() -> Unit)? = null, configure: (OperatorSettings) -> Unit = {},
    ) {
        composeRule.setContent {
            val context = LocalContext.current
            val settings = remember {
                OperatorSettings(context.getSharedPreferences("f05-$name", Context.MODE_PRIVATE)
                    .also { it.edit().clear().commit() }).also(configure)
            }
            val scope = rememberCoroutineScope()
            val common = remember { NikonOpenCineSession(session, scope) }
            val control = remember { MonitorControlModel(scope).also { it.bind(common) } }
            DisposableEffect(Unit) { onDispose { control.unbind() } }
            val assists = remember { idleNikonAssists() }
            OpenZCineTheme {
                MonitorScreen(session, common, control, rememberTestOperatorSession(assists, settings), frames, assists,
                    settings, liveViewEnabled = liveView, sessionRecoveryEnabled = false,
                    controlsSurrendered = surrendered, borrowed = returnToStage != null, returnToStage = returnToStage)
            }
        }
    }

    private class Sample(val centre: Int, val darkenedPercent: Int, val count: Int)

    /**
     * The composited screen (native picture, every overlay and the chrome) inside the feed's middle band. A pixel
     * counts as darkened when it reads well below the feed's own centre.
     */
    private fun feedSample(): Sample {
        val bounds = composeRule.onNodeWithTag("monitor_live_feed").fetchSemanticsNode().boundsInWindow
        val shot = requireNotNull(InstrumentationRegistry.getInstrumentation().uiAutomation.takeScreenshot())
        try {
            fun luma(x: Float, y: Float): Int {
                val pixel = shot.getPixel(x.roundToInt().coerceIn(0, shot.width - 1), y.roundToInt().coerceIn(0, shot.height - 1))
                return (Color.red(pixel) * 299 + Color.green(pixel) * 587 + Color.blue(pixel) * 114) / 1000
            }
            val centre = luma(bounds.center.x, bounds.center.y)
            var count = 0
            var darkened = 0
            for (row in 0..8) for (column in 0..36) {
                val x = bounds.left + bounds.width * (0.05f + 0.9f * column / 36f)
                val y = bounds.top + bounds.height * (0.4f + 0.2f * row / 8f)
                count += 1
                if (luma(x, y) < centre - 6) darkened += 1
            }
            return Sample(centre, darkened * 100 / count, count)
        } finally {
            shot.recycle()
        }
    }

    /** The in-memory camera reporting a raw Nikon BatteryLevel. */
    private class BatterySession(camera: FakeCameraSession, rawLevel: Int) : CameraSession by camera {
        override val cameraProperties: StateFlow<CameraPropertySnapshot> =
            MutableStateFlow(camera.cameraProperties.value.copy(batteryPercent = rawLevel))
        override val reportedCameraProperties: StateFlow<CameraPropertySnapshot> get() = cameraProperties
    }

    /** Counts lens drives; every other call is the in-memory camera's. */
    private class DriveCountingSession(private val camera: FakeCameraSession) : CameraSession by camera {
        val drives = AtomicInteger()
        override suspend fun mfDrive(towardNear: Boolean, pulses: Int): MFDriveOutcome {
            drives.incrementAndGet()
            return MFDriveOutcome.Complete
        }
    }

    /** A steady flat picture through the production decoder and feed. */
    private class FlatPictureSource(color: Int) : LiveFrameSource {
        private val jpeg = ByteArrayOutputStream().use { output ->
            val bitmap = Bitmap.createBitmap(320, 180, Bitmap.Config.ARGB_8888)
            bitmap.eraseColor(color)
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

    private companion object {
        const val RETURN_TO_MULTIVIEW = "Return to Multiview"
        const val MF_STRIP = "Manual focus drive"
        const val TIMEOUT_MILLIS = 10_000L
    }
}
