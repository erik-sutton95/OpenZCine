package com.opencapture.openzcine

import android.content.Context
import androidx.compose.foundation.layout.Column
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.ui.graphics.ImageBitmap
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.semantics.SemanticsActions
import androidx.compose.ui.test.ExperimentalTestApi
import androidx.compose.ui.test.hasClickAction
import androidx.compose.ui.test.hasContentDescription
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.test.onNodeWithContentDescription
import androidx.compose.ui.test.onNodeWithTag
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.performClick
import androidx.compose.ui.test.performSemanticsAction
import androidx.test.core.app.ApplicationProvider
import androidx.test.ext.junit.runners.AndroidJUnit4
import com.opencapture.opencine.appkit.MonitorControlModel
import com.opencapture.opencine.appkit.MonitorReviewDuration
import com.opencapture.opencine.appkit.MonitorReviewOptions
import com.opencapture.opencine.nikon.CameraIdentity
import com.opencapture.opencine.nikon.CameraPropertySnapshot
import com.opencapture.opencine.nikon.CameraSession
import com.opencapture.opencine.nikon.FakeCameraSession
import com.opencapture.opencine.nikon.LiveFocusBox
import com.opencapture.opencine.nikon.LiveFocusInfo
import com.opencapture.opencine.nikon.LiveFocusResult
import com.opencapture.opencine.nikon.NikonOpenCineSession
import com.opencapture.openzcine.settings.OperatorSettings
import kotlinx.coroutines.flow.MutableStateFlow
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith

/** A3-08: the instant review keeps the operator's duration, focus point and capture info choices. */
@OptIn(ExperimentalTestApi::class)
@RunWith(AndroidJUnit4::class)
class InstantReviewOptionsComposeTest {
    @get:Rule
    val composeRule = createComposeRule()

    private val review = InstantReviewPresentation(
        image = ImageBitmap(64, 48), isFullResolution = true, countdownArmed = true, handle = 1,
        infoLine = "ISO 800 · 1/250 · f/4 · Fine",
        focus = LiveFocusInfo(640, 480, LiveFocusResult.FOCUSED, subjectDetectionActive = false,
            trackingAFActive = false, selectedBoxIndex = 0, boxes = listOf(LiveFocusBox(320, 240, 60, 60))),
    )

    private fun show(options: MonitorReviewOptions): () -> Boolean {
        var dismissed = false
        composeRule.mainClock.autoAdvance = false
        composeRule.setContent {
            OpenZCineTheme { InstantReviewOverlay(review, onDismiss = { dismissed = true }, onToggleStar = {}, options = options) }
        }
        composeRule.mainClock.advanceTimeByFrame()
        return { dismissed }
    }

    @Test
    fun sevenSecondsKeepsTheReviewUpPastThreeSeconds() {
        val dismissed = show(MonitorReviewOptions(MonitorReviewDuration.SEVEN_SECONDS))
        composeRule.mainClock.advanceTimeBy(3_500)
        assertFalse("the old fixed 3 s must not close a 7 s review", dismissed())
        composeRule.mainClock.advanceTimeBy(4_000)
        assertTrue(dismissed())
    }

    @Test
    fun untilDismissedWaitsForATap() {
        val dismissed = show(MonitorReviewOptions(MonitorReviewDuration.UNTIL_DISMISSED))
        composeRule.mainClock.advanceTimeBy(60_000)
        assertFalse(dismissed())
        composeRule.onNodeWithContentDescription("Instant playback").performClick()
        composeRule.mainClock.advanceTimeByFrame()
        assertTrue(dismissed())
    }

    @Test
    fun focusPointAndCaptureInfoFollowTheirToggles() {
        val options = mutableStateOf(MonitorReviewOptions(MonitorReviewDuration.UNTIL_DISMISSED))
        composeRule.setContent {
            OpenZCineTheme { InstantReviewOverlay(review, onDismiss = {}, onToggleStar = {}, options = options.value) }
        }
        // The overlay is one tap target, so its layers sit in the unmerged tree.
        composeRule.onNodeWithTag(INSTANT_REVIEW_FOCUS_TAG, useUnmergedTree = true).assertExists()
        composeRule.onNodeWithText(review.infoLine!!, useUnmergedTree = true).assertExists()
        composeRule.runOnIdle { options.value = options.value.copy(showsFocusPoint = false, showsCaptureInfo = false) }
        composeRule.onNodeWithTag(INSTANT_REVIEW_FOCUS_TAG, useUnmergedTree = true).assertDoesNotExist()
        composeRule.onNodeWithText(review.infoLine!!, useUnmergedTree = true).assertDoesNotExist()
    }

    @Test
    fun theInspectorRowsPersistAcrossARestore() {
        val context = ApplicationProvider.getApplicationContext<Context>()
        clearAssistPreferences(context)
        val assists = restoreNikonAssists(context)
        assertEquals(MonitorReviewOptions(), assists.reviewOptions)
        composeRule.setContent { OpenZCineTheme { Column { NikonReviewOptions(assists) } } }
        composeRule.onNodeWithText("7s").performClick()
        composeRule.onNode(hasContentDescription("Focus Point") and hasClickAction()).performClick()
        composeRule.onNode(hasContentDescription("Capture Info") and hasClickAction()).performClick()
        composeRule.waitForIdle()
        val chosen = MonitorReviewOptions(MonitorReviewDuration.SEVEN_SECONDS, showsFocusPoint = false, showsCaptureInfo = false)
        assertEquals(chosen, assists.reviewOptions)
        assertEquals(chosen, restoreNikonAssists(context).reviewOptions)
        clearAssistPreferences(context)
    }

    /** The PLAY palette item opens the review options as a tab of the shared inspector. */
    @Test
    fun playOpensItsReviewOptionsInTheSharedInspector() {
        val session = PhotoCamera()
        composeRule.setContent {
            val context = LocalContext.current
            val settings = remember { OperatorSettings(context.getSharedPreferences(
                "SIMULATED-review-options", Context.MODE_PRIVATE).also { it.edit().clear().commit() }) }
            val scope = rememberCoroutineScope()
            val common = remember { NikonOpenCineSession(session, scope) }
            val control = remember { MonitorControlModel(scope).also { it.bind(common) } }
            DisposableEffect(Unit) { onDispose { control.unbind() } }
            OpenZCineTheme {
                val assists = remember { idleNikonAssists() }
                MonitorScreen(session, common, control, rememberTestOperatorSession(assists, settings), frameSource = null,
                    assists = assists, operatorSettings = settings, liveViewEnabled = false, sessionRecoveryEnabled = false,
                    glassTierOverride = "flat")
            }
        }
        composeRule.waitUntilAtLeastOneExists(hasContentDescription("Instant Playback", substring = true), 5_000)
        composeRule.onNode(hasContentDescription("Instant Playback", substring = true))
            .performSemanticsAction(SemanticsActions.OnLongClick)
        composeRule.waitUntilAtLeastOneExists(hasContentDescription("Focus Point") and hasClickAction(), 5_000)
        composeRule.onNodeWithText("Review Duration").assertExists()
    }

    private fun clearAssistPreferences(context: Context) {
        // The monitor's assist preferences file (`restoreNikonAssists`).
        context.getSharedPreferences("assist", Context.MODE_PRIVATE).edit().clear().commit()
    }

    private class PhotoCamera : CameraSession by FakeCameraSession(
        CameraIdentity("SIMULATED", "SIMULATED", "review-options"), startConnected = true) {
        override val cameraProperties = MutableStateFlow(CameraPropertySnapshot(captureSelector = "photo", iso = 800,
            isoAuto = false, exposureMode = "M", shutterSpeed = "1/250"))
        override val reportedCameraProperties = cameraProperties
        override val reportedRecording = MutableStateFlow<Boolean?>(false)
        override suspend fun refreshProperties() = Unit
    }
}
