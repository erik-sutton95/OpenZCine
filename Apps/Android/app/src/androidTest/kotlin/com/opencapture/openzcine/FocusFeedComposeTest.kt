package com.opencapture.openzcine

import android.content.ContentValues
import android.content.Context
import android.graphics.Bitmap
import android.graphics.Color
import android.os.Environment
import android.os.SystemClock
import android.provider.MediaStore
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.semantics.SemanticsActions
import androidx.compose.ui.semantics.SemanticsProperties
import androidx.compose.ui.test.SemanticsMatcher
import androidx.compose.ui.test.assert
import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.junit4.v2.createComposeRule
import androidx.compose.ui.test.onAllNodesWithTag
import androidx.compose.ui.test.onNodeWithContentDescription
import androidx.compose.ui.test.onNodeWithTag
import androidx.compose.ui.test.performClick
import androidx.compose.ui.test.performTouchInput
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import com.opencapture.openzcine.bridge.SwiftCore
import com.opencapture.openzcine.core.CameraFocusPoint
import com.opencapture.openzcine.core.CameraIdentity
import com.opencapture.openzcine.core.CameraRecordingState
import com.opencapture.openzcine.core.CameraSession
import com.opencapture.openzcine.core.CameraSessionState
import com.opencapture.openzcine.core.LiveFocusBox
import com.opencapture.openzcine.core.LiveFocusInfo
import com.opencapture.openzcine.core.LiveFocusResult
import com.opencapture.openzcine.core.LiveFrame
import com.opencapture.openzcine.core.LiveFrameSource
import com.opencapture.openzcine.settings.LocalDesqueezeOrientation
import com.opencapture.openzcine.settings.LocalDesqueezeRatio
import com.opencapture.openzcine.settings.LocalFramingAspectRatio
import com.opencapture.openzcine.settings.OperatorSettings
import com.opencapture.openzcine.settings.PortraitFeedAspect
import java.io.ByteArrayOutputStream
import java.util.Collections
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.flow
import org.junit.Assert.assertEquals
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith

/** Compose-level AF interaction and truthful semantics coverage over the production monitor. */
@RunWith(AndroidJUnit4::class)
class FocusFeedComposeTest {
    @get:Rule
    val composeRule = createComposeRule()

    @Test
    fun tapLockUnlockAndResetStayOnTheTypedSessionSeam() {
        setDeviceRotation(ROTATION_LANDSCAPE_LEFT)
        val session = FocusSession()
        val source = FocusFrameSource(testJpeg())
        setMonitor(session, source, "focus-feed-compose-test")

        composeRule.waitUntil(5_000) {
            composeRule.onAllNodesWithTag("focus_reset_button").fetchSemanticsNodes().isNotEmpty()
        }
        composeRule
            .onNodeWithContentDescription(
                "Live view active. Tap to move focus point; hold to lock its position.",
            )
            .assertIsDisplayed()
        saveDeviceScreenshot("focus-reset-visible-pre-tap.png")
        composeRule.onNodeWithTag("monitor_live_feed").performTouchInput {
            down(center)
            advanceEventTime(50)
            up()
        }
        composeRule.waitUntil(5_000) { session.lastFocusPoint != null }
        assertEquals(CameraFocusPoint(500, 250), session.lastFocusPoint)

        composeRule.onNodeWithTag("monitor_live_feed").performTouchInput {
            down(center)
            advanceEventTime(350)
            up()
        }
        composeRule
            .onNodeWithContentDescription(
                "Live view active. Focus point position locked in app.",
            )
            .assertIsDisplayed()
        saveDeviceScreenshot("focus-locked-trailing-reset.png")

        composeRule.onNodeWithTag("monitor_live_feed").performTouchInput {
            down(center)
            advanceEventTime(350)
            up()
        }
        assertDisplayMode("Live")
        composeRule.onNodeWithTag("monitor_live_feed").performTouchInput {
            down(Offset(center.x, height * 0.2f))
            advanceEventTime(75)
            moveBy(Offset(0f, height * 0.6f))
            advanceEventTime(75)
            up()
        }
        assertDisplayMode("Clean")
        // The opposite swipe validates that the pointer coroutine uses the latest callback state
        // after a mode-changing recomposition, rather than its original Live capture.
        composeRule.onNodeWithTag("monitor_live_feed").performTouchInput {
            down(Offset(center.x, height * 0.8f))
            advanceEventTime(75)
            moveBy(Offset(0f, -height * 0.6f))
            advanceEventTime(75)
            up()
        }
        assertDisplayMode("Live")
        composeRule.onNodeWithTag("focus_reset_button").performClick()
        composeRule.waitUntil(5_000) { session.resetCount == 1 }
    }

    @Test
    fun preFrameDispSwipesWorkWhileFocusActionsRemainUnavailable() {
        setDeviceRotation(ROTATION_LANDSCAPE_LEFT)
        val session = FocusSession()
        setMonitor(session, WaitingFrameSource(), "focus-feed-pre-frame-test")

        composeRule.waitUntil(5_000) {
            composeRule.onAllNodesWithTag("monitor_live_feed").fetchSemanticsNodes().isNotEmpty()
        }
        val feed = composeRule.onNodeWithTag("monitor_live_feed")
        feed.assert(
            SemanticsMatcher.keyNotDefined(SemanticsActions.OnLongClick),
        )
        feed.performTouchInput {
            down(center)
            advanceEventTime(350)
            up()
        }
        composeRule.waitForIdle()
        assertEquals(null, session.lastFocusPoint)

        feed.performTouchInput {
            down(Offset(center.x, height * 0.2f))
            advanceEventTime(75)
            moveBy(Offset(0f, height * 0.6f))
            advanceEventTime(75)
            up()
        }
        assertDisplayMode("Clean")
        saveDeviceScreenshot("af-unavailable-disp-clean.png")
    }

    @Test
    fun rapidTapsReachTheSessionLatestWinsBoundary() {
        setDeviceRotation(ROTATION_LANDSCAPE_LEFT)
        val session = FocusSession(focusDelayMillis = 250)
        setMonitor(session, FocusFrameSource(testJpeg()), "focus-feed-rapid-tap-test")
        composeRule.waitUntil(5_000) {
            composeRule.onAllNodesWithTag("focus_reset_button").fetchSemanticsNodes().isNotEmpty()
        }
        val feed = composeRule.onNodeWithTag("monitor_live_feed")

        feed.performTouchInput {
            down(Offset(width * 0.25f, center.y))
            advanceEventTime(30)
            up()
        }
        feed.performTouchInput {
            down(Offset(width * 0.75f, center.y))
            advanceEventTime(30)
            up()
        }

        composeRule.waitUntil(5_000) { session.focusPoints.size == 2 }
    }

    @Test
    fun secondPointerCancelsDispSwipeAndHandsGestureToPortraitPinch() {
        setDeviceRotation(ROTATION_PORTRAIT)
        val session = FocusSession()
        val settings =
            setMonitor(session, FocusFrameSource(testJpeg()), "focus-feed-pinch-test")
        settings.portraitFeedAspect = PortraitFeedAspect.FIT_16_9
        composeRule.waitUntil(5_000) {
            composeRule.onAllNodesWithTag("focus_reset_button").fetchSemanticsNodes().isNotEmpty()
        }

        composeRule.onNodeWithTag("monitor_live_feed").performTouchInput {
            val swipeStart = Offset(center.x, height * 0.2f)
            val swipeMidpoint = Offset(center.x, height * 0.45f)
            down(0, swipeStart)
            advanceEventTime(75)
            moveTo(0, swipeMidpoint)
            advanceEventTime(75)
            down(1, Offset(center.x + 36f, swipeMidpoint.y))
            moveTo(0, Offset(center.x - 100f, swipeMidpoint.y))
            moveTo(1, Offset(center.x + 136f, swipeMidpoint.y))
            advanceEventTime(75)
            up(1)
            up(0)
        }

        composeRule.waitUntil(5_000) {
            settings.portraitFeedAspect == PortraitFeedAspect.FILL
        }
        assertDisplayMode("Live")
        assertEquals(null, session.lastFocusPoint)
    }

    @Test
    fun portraitFillFramingRemainsPixelAlignedToTheCroppedFeed() {
        setDeviceRotation(ROTATION_PORTRAIT)
        try {
            val session = FocusSession()
            val settings =
                setMonitor(
                    session,
                    FocusFrameSource(testJpeg()),
                    "focus-feed-ope91-portrait-fill-test",
                )
            settings.portraitFeedAspect = PortraitFeedAspect.FILL
            LocalFramingAspectRatio.entries
                .filter { it != LocalFramingAspectRatio.RATIO_239 && it in settings.selectedGuideRatios }
                .forEach(settings::toggleGuideRatioConfiguration)
            if (LocalFramingAspectRatio.RATIO_239 !in settings.selectedGuideRatios) {
                settings.toggleGuideRatioConfiguration(LocalFramingAspectRatio.RATIO_239)
            }
            settings.guidesVisible.value = true
            settings.guideMaskEnabled.value = true
            settings.localGridVisible.value = true
            settings.ruleOfThirdsEnabled.value = true
            settings.centerCrosshairEnabled.value = true
            settings.desqueezeEnabled.value = true
            settings.desqueezeRatio = LocalDesqueezeRatio.X200
            settings.desqueezeOrientation = LocalDesqueezeOrientation.HORIZONTAL
            settings.levelAssistEnabled.value = false

            composeRule.waitUntil(5_000) {
                composeRule.onAllNodesWithTag("focus_reset_button").fetchSemanticsNodes().isNotEmpty()
            }
            composeRule
                .onNodeWithContentDescription(
                    "Local framing assists. 1 delivery guide on. " +
                        "Mask outside selected frames on. Composition grid on. " +
                        "Centre crosshair on. Horizontal desqueeze 2x. Camera level off. " +
                        "Camera Grid Display is unchanged.",
                )
                .assertIsDisplayed()
            saveDeviceScreenshot(
                "portrait-fill-guides-feed-aligned.png",
                album = "OpenZCine-OPE91",
            )
        } finally {
            setDeviceRotation(ROTATION_LANDSCAPE_LEFT)
        }
    }

    private fun setMonitor(
        session: CameraSession,
        source: LiveFrameSource,
        preferencesName: String,
    ): OperatorSettings {
        check(SwiftCore.isAvailable) { "The device UI pass requires the staged Swift core." }
        val context = InstrumentationRegistry.getInstrumentation().targetContext
        val settings =
            OperatorSettings(
                context.getSharedPreferences(preferencesName, Context.MODE_PRIVATE),
            ).also { it.hapticsEnabled.value = false }
        composeRule.setContent {
            OpenZCineTheme {
                MonitorScreen(
                    session = session,
                    frameSource = source,
                    assist = AssistState(FeedEffects.NONE, null),
                    operatorSettings = settings,
                    glassTierOverride = "blur",
                )
            }
        }
        return settings
    }

    private fun saveDeviceScreenshot(
        name: String,
        album: String = "OpenZCine-OPE71",
    ) {
        val instrumentation = InstrumentationRegistry.getInstrumentation()
        val arguments = InstrumentationRegistry.getArguments()
        if (arguments.getString(SCREENSHOT_ARGUMENT) != "true" &&
            arguments.getString(OPE91_SCREENSHOT_ARGUMENT) != "true"
        ) {
            return
        }
        val screenshot = requireNotNull(instrumentation.uiAutomation.takeScreenshot())
        val values =
            ContentValues().apply {
                put(MediaStore.Images.Media.DISPLAY_NAME, name)
                put(MediaStore.Images.Media.MIME_TYPE, "image/png")
                put(
                    MediaStore.Images.Media.RELATIVE_PATH,
                    "${Environment.DIRECTORY_PICTURES}/$album",
                )
            }
        val resolver = instrumentation.targetContext.contentResolver
        val output =
            checkNotNull(
                resolver.insert(MediaStore.Images.Media.EXTERNAL_CONTENT_URI, values),
            )
        resolver.openOutputStream(output).use { stream ->
            checkNotNull(stream)
            check(screenshot.compress(Bitmap.CompressFormat.PNG, 100, stream))
        }
        screenshot.recycle()
        println("OPE71_SCREENSHOT=$output")
    }

    private fun setDeviceRotation(rotation: Int) {
        val instrumentation = InstrumentationRegistry.getInstrumentation()
        instrumentation.uiAutomation.executeShellCommand("wm user-rotation lock $rotation").close()
        val deadline = SystemClock.uptimeMillis() + 5_000L
        while (SystemClock.uptimeMillis() < deadline) {
            val screenshot = requireNotNull(instrumentation.uiAutomation.takeScreenshot())
            val portrait = screenshot.height > screenshot.width
            screenshot.recycle()
            if (portrait == (rotation == ROTATION_PORTRAIT)) return
            SystemClock.sleep(100L)
        }
        error("The hardware display did not reach rotation $rotation.")
    }

    private fun assertDisplayMode(label: String) {
        composeRule.waitUntil(5_000) {
            composeRule
                .onAllNodesWithTag("monitor_live_feed")
                .fetchSemanticsNodes()
                .any {
                    it.config[SemanticsProperties.StateDescription] ==
                        "Display mode $label"
                }
        }
        composeRule
            .onNodeWithTag("monitor_live_feed")
            .assert(
                SemanticsMatcher.expectValue(
                    SemanticsProperties.StateDescription,
                    "Display mode $label",
                ),
            )
    }

    private fun testJpeg(): ByteArray {
        val bitmap = Bitmap.createBitmap(160, 90, Bitmap.Config.ARGB_8888)
        bitmap.eraseColor(Color.DKGRAY)
        val output = ByteArrayOutputStream()
        check(bitmap.compress(Bitmap.CompressFormat.JPEG, 90, output))
        bitmap.recycle()
        return output.toByteArray()
    }

    private class FocusSession(
        private val focusDelayMillis: Long = 0,
    ) : CameraSession {
        private val mutableState = MutableStateFlow<CameraSessionState>(CameraSessionState.Disconnected)
        override val state: StateFlow<CameraSessionState> = mutableState
        override val recordingState: StateFlow<CameraRecordingState> =
            MutableStateFlow(CameraRecordingState.STANDBY)

        @Volatile var lastFocusPoint: CameraFocusPoint? = null
        @Volatile var resetCount: Int = 0
        val focusPoints: MutableList<CameraFocusPoint> =
            Collections.synchronizedList(mutableListOf())

        override suspend fun connect() {
            mutableState.value =
                CameraSessionState.Connected(
                    CameraIdentity("Test ZR", "NIKON ZR", "FOCUS-TEST"),
                )
        }

        override suspend fun setRecording(recording: Boolean) = Unit

        override suspend fun changeAfArea(point: CameraFocusPoint): Boolean {
            if (focusDelayMillis > 0) delay(focusDelayMillis)
            focusPoints += point
            lastFocusPoint = point
            return true
        }

        override suspend fun resetFocusPoint() {
            resetCount += 1
        }

        override suspend fun disconnect() {
            mutableState.value = CameraSessionState.Disconnected
        }
    }

    private class FocusFrameSource(private val jpeg: ByteArray) : LiveFrameSource {
        override val frames: Flow<LiveFrame> =
            flow {
                while (true) {
                    emit(
                        LiveFrame(
                            timestampNanos = System.nanoTime(),
                            jpegData = jpeg,
                            focus =
                                LiveFocusInfo(
                                    coordinateWidth = 1_000,
                                    coordinateHeight = 500,
                                    result = LiveFocusResult.FOCUSED,
                                    subjectDetectionActive = false,
                                    trackingAFActive = false,
                                    selectedBoxIndex = null,
                                    boxes =
                                        listOf(
                                            LiveFocusBox(
                                                centerX = 930,
                                                centerY = 250,
                                                width = 120,
                                                height = 80,
                                            ),
                                        ),
                                ),
                        ),
                    )
                    delay(100)
                }
            }
    }

    private class WaitingFrameSource : LiveFrameSource {
        override val frames: Flow<LiveFrame> =
            flow {
                delay(60_000)
            }
    }

    private companion object {
        const val ROTATION_PORTRAIT = 0
        const val ROTATION_LANDSCAPE_LEFT = 1
        const val SCREENSHOT_ARGUMENT = "ope71Screenshots"
        const val OPE91_SCREENSHOT_ARGUMENT = "ope91Screenshots"
    }
}
