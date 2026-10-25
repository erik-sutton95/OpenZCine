package com.opencapture.openzcine

import android.content.Context
import android.graphics.Bitmap
import android.os.SystemClock
import android.view.InputDevice
import android.view.MotionEvent
import androidx.activity.ComponentActivity
import androidx.compose.ui.semantics.SemanticsNode
import androidx.compose.ui.semantics.SemanticsProperties
import androidx.compose.ui.semantics.getOrNull
import androidx.compose.ui.test.ExperimentalTestApi
import androidx.compose.ui.test.hasContentDescription
import androidx.compose.ui.test.hasTestTag
import androidx.compose.ui.test.isRoot
import androidx.compose.ui.test.junit4.createAndroidComposeRule
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import com.opencapture.opencine.appkit.MonitorReviewDuration
import com.opencapture.opencine.appkit.MonitorReviewOptions
import com.opencapture.opencine.cameracontrols.MonitorInstantReviewIds
import com.opencapture.opencine.nikon.CameraIdentity
import com.opencapture.opencine.nikon.CameraPropertySnapshot
import com.opencapture.opencine.nikon.CameraSession
import com.opencapture.opencine.nikon.CameraSessionEvent
import com.opencapture.opencine.nikon.FakeCameraSession
import com.opencapture.openzcine.settings.OperatorSettings
import java.io.ByteArrayOutputStream
import kotlinx.coroutines.flow.MutableSharedFlow
import kotlinx.coroutines.flow.MutableStateFlow
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith

/**
 * Hardware finding (Z Android, 2026-10-25): the View Assist palette stayed on top of the instant
 * review. iOS covers the whole monitor with the review; the palette floats in its own popup
 * window on Android, which always draws above the activity. With a review up, the palette must
 * share the review's window (beneath it) and a real touch where it sits must reach the review.
 */
@OptIn(ExperimentalTestApi::class)
@RunWith(AndroidJUnit4::class)
class InstantReviewCoverComposeTest {
    @get:Rule
    val composeRule = createAndroidComposeRule<ComponentActivity>()

    @Test
    fun theReviewCoversTheAssistPaletteAndTakesItsTouches() {
        val session = PhotoCamera()
        // Until dismissed: only the touch may take the review away, never its timer.
        val assists = idleNikonAssists().apply {
            instantReview = true
            updateReviewOptions(MonitorReviewOptions(MonitorReviewDuration.UNTIL_DISMISSED))
        }
        composeRule.setContent {
            val settings = OperatorSettings(composeRule.activity.getSharedPreferences(
                "SIMULATED-review-cover", Context.MODE_PRIVATE).also { it.edit().clear().commit() })
            TestMonitorScreen(session, assists, settings)
        }
        val playKey = hasContentDescription("Instant Playback", substring = true)
        composeRule.waitUntilAtLeastOneExists(playKey, 5_000)

        // A body-fired capture completes; the review presents the shot.
        composeRule.runOnIdle {
            check(session.events.tryEmit(CameraSessionEvent.StillCaptureCompleted(0x400D, 1L, emptyList())))
        }
        composeRule.waitUntilAtLeastOneExists(hasTestTag(MonitorInstantReviewIds.REVIEW), 5_000)
        composeRule.waitForIdle()

        val reviewRoot = rootIndexContaining { it.config.getOrNull(SemanticsProperties.TestTag) == MonitorInstantReviewIds.REVIEW }
        val paletteRoot = rootIndexContaining { node ->
            node.config.getOrNull(SemanticsProperties.ContentDescription).orEmpty().any { "Instant Playback" in it }
        }
        assertEquals("The assist palette must sit in the review's window, beneath it, never in a window above it",
            reviewRoot, paletteRoot)

        // A real touch on the palette's PLAY key lands on the review: it dismisses, PLAY stays on.
        val key = composeRule.onNode(playKey, useUnmergedTree = true).fetchSemanticsNode().boundsInWindow
        val origin = IntArray(2)
        composeRule.runOnIdle { composeRule.activity.window.decorView.getLocationOnScreen(origin) }
        tap(origin[0] + key.center.x, origin[1] + key.center.y)
        composeRule.waitForIdle()
        composeRule.onNode(hasTestTag(MonitorInstantReviewIds.REVIEW)).assertDoesNotExist()
        assertTrue("The covered palette must not toggle PLAY", assists.instantReview)
    }

    private fun rootIndexContaining(predicate: (SemanticsNode) -> Boolean): Int {
        val roots = composeRule.onAllNodes(isRoot(), useUnmergedTree = true).fetchSemanticsNodes()
        fun SemanticsNode.has(): Boolean = predicate(this) || children.any { it.has() }
        val matches = roots.indices.filter { roots[it].has() }
        assertEquals("exactly one window holds the node", 1, matches.size)
        return matches.single()
    }

    private fun tap(x: Float, y: Float) {
        val automation = InstrumentationRegistry.getInstrumentation().uiAutomation
        val down = SystemClock.uptimeMillis()
        for (action in listOf(MotionEvent.ACTION_DOWN, MotionEvent.ACTION_UP)) {
            val event = MotionEvent.obtain(down, SystemClock.uptimeMillis(), action, x, y, 0)
                .apply { source = InputDevice.SOURCE_TOUCHSCREEN }
            automation.injectInputEvent(event, true)
            event.recycle()
        }
    }

    /** SIMULATED photo-mode body whose capture-complete lands one new still on the card. */
    private class PhotoCamera : CameraSession by FakeCameraSession(
        CameraIdentity("SIMULATED", "SIMULATED", "review-cover"), startConnected = true) {
        override val cameraProperties = MutableStateFlow(CameraPropertySnapshot(captureSelector = "photo", iso = 800,
            isoAuto = false, exposureMode = "M", shutterSpeed = "1/250"))
        override val reportedCameraProperties = cameraProperties
        override val reportedRecording = MutableStateFlow<Boolean?>(false)
        override val events = MutableSharedFlow<CameraSessionEvent>(extraBufferCapacity = 8)
        override suspend fun refreshProperties() = Unit
        override suspend fun seedInstantReviewBaseline() = Unit
        override suspend fun resolveNewestStillHandle(): Int = 7
        override suspend fun stillThumbnail(handle: Int): ByteArray = still
        override suspend fun stillFullImage(handle: Int): ByteArray = still

        private val still: ByteArray = ByteArrayOutputStream().also { out ->
            Bitmap.createBitmap(96, 64, Bitmap.Config.ARGB_8888).apply { eraseColor(0xFF406080.toInt()) }
                .compress(Bitmap.CompressFormat.JPEG, 90, out)
        }.toByteArray()
    }
}
