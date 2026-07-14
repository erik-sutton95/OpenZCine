package com.opencapture.openzcine

import android.content.Context
import androidx.compose.ui.test.ExperimentalTestApi
import androidx.compose.ui.test.assertIsEnabled
import androidx.compose.ui.test.hasContentDescription
import androidx.compose.ui.test.hasText
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.test.onNodeWithContentDescription
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.performClick
import androidx.compose.runtime.remember
import androidx.compose.ui.platform.LocalContext
import androidx.test.ext.junit.runners.AndroidJUnit4
import com.opencapture.openzcine.core.CameraIdentity
import com.opencapture.openzcine.core.CameraRecordingState
import com.opencapture.openzcine.core.FakeCameraSession
import com.opencapture.openzcine.settings.OperatorSettings
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith

/**
 * Record start/stop coverage through the production monitor's Compose
 * semantics. It keeps the real RecordButton → MonitorScreen → CameraSession
 * state-flow path while supplying an in-memory session with no camera or
 * network I/O.
 */
@OptIn(ExperimentalTestApi::class)
@RunWith(AndroidJUnit4::class)
class RecordCameraFlowComposeTest {
    @get:Rule
    val composeRule = createComposeRule()

    @Test
    fun fakeCameraRecordControlStartsThenStopsRecording() {
        val session =
            FakeCameraSession(
                CameraIdentity(name = "Test ZR", model = "NIKON ZR", serialNumber = "TEST-001"),
            )
        // The monitor deliberately has continuously scheduled frame/timecode work.
        // Keeping the test clock fixed lets semantics actions observe each state transition.
        composeRule.mainClock.autoAdvance = false
        composeRule.setContent {
            val context = LocalContext.current
            val operatorSettings =
                remember(context) {
                    // This flow must not depend on, or alter, the operator's
                    // real confirmation preference.
                    OperatorSettings(
                        context.getSharedPreferences("record-flow-test", Context.MODE_PRIVATE),
                    ).also { it.recordConfirmationEnabled.value = true }
                }
            OpenZCineTheme {
                MonitorScreen(
                    session = session,
                    frameSource = null,
                    assist = AssistState(FeedEffects.NONE, null),
                    operatorSettings = operatorSettings,
                    liveViewEnabled = false,
                    glassTierOverride = GLASS_TIER_FLAT,
                )
            }
        }
        composeRule.mainClock.advanceTimeByFrame()

        composeRule.waitUntilAtLeastOneExists(
            hasContentDescription(START_RECORDING),
            UI_TIMEOUT_MILLIS,
        )
        composeRule
            .onNodeWithContentDescription(START_RECORDING)
            .assertIsEnabled()
            .performClick()
        composeRule.mainClock.advanceTimeByFrame()
        composeRule.onNodeWithText(CONFIRM_START).assertIsEnabled().performClick()
        composeRule.waitUntil(UI_TIMEOUT_MILLIS) {
            session.recordingState.value == CameraRecordingState.RECORDING
        }
        composeRule.mainClock.advanceTimeByFrame()
        composeRule.waitUntilAtLeastOneExists(
            hasContentDescription(STOP_RECORDING),
            UI_TIMEOUT_MILLIS,
        )
        composeRule.waitUntilAtLeastOneExists(hasText(RECORDING), UI_TIMEOUT_MILLIS)

        composeRule
            .onNodeWithContentDescription(STOP_RECORDING)
            .assertIsEnabled()
            .performClick()
        composeRule.mainClock.advanceTimeByFrame()
        composeRule.onNodeWithText(CONFIRM_STOP).assertIsEnabled().performClick()
        composeRule.waitUntil(UI_TIMEOUT_MILLIS) {
            session.recordingState.value == CameraRecordingState.STANDBY
        }
        composeRule.mainClock.advanceTimeByFrame()
        composeRule.waitUntilAtLeastOneExists(
            hasContentDescription(START_RECORDING),
            UI_TIMEOUT_MILLIS,
        )
        composeRule.waitUntilAtLeastOneExists(hasText(STANDBY), UI_TIMEOUT_MILLIS)
    }

    private companion object {
        const val GLASS_TIER_FLAT = "flat"
        const val START_RECORDING = "Start recording"
        const val STOP_RECORDING = "Stop recording"
        const val CONFIRM_START = "Start"
        const val CONFIRM_STOP = "Stop"
        const val RECORDING = "REC"
        const val STANDBY = "STBY"
        const val UI_TIMEOUT_MILLIS = 5_000L
    }
}
