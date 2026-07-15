package com.opencapture.openzcine.wear

import androidx.compose.ui.test.assertIsEnabled
import androidx.compose.ui.test.assertIsNotEnabled
import androidx.compose.ui.test.assertTextEquals
import androidx.compose.ui.test.junit4.v2.createComposeRule
import androidx.compose.ui.test.onNodeWithContentDescription
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.performClick
import androidx.test.ext.junit.runners.AndroidJUnit4
import com.opencapture.openzcine.wearrelay.WatchConnectionState
import com.opencapture.openzcine.wearrelay.WatchRecordState
import com.opencapture.openzcine.wearrelay.WatchRelayState
import com.opencapture.openzcine.wearrelay.WatchTimecode
import org.junit.Assert.assertEquals
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class WearMonitorScreenTest {
    @get:Rule
    val composeRule = createComposeRule()

    @Test
    fun commandModeKeepsRecordEnabledAndShowsZeroBattery() {
        var toggles = 0
        composeRule.setContent {
            WearMonitorContent(
                presentation = connectedPresentation(feedLive = false, batteryPercent = 0),
                onToggleRecord = { toggles += 1 },
            )
        }

        composeRule.onNodeWithText("01:02:03:04").assertTextEquals("01:02:03:04")
        composeRule.onNodeWithText("Feed paused (Command mode)").assertExists()
        composeRule.onNodeWithText("0%").assertExists()
        composeRule
            .onNodeWithContentDescription("Start camera recording")
            .assertIsEnabled()
            .performClick()
        composeRule.runOnIdle { assertEquals(1, toggles) }
    }

    @Test
    fun pendingCommandDisablesDuplicateRecordToggle() {
        composeRule.setContent {
            WearMonitorContent(
                presentation = connectedPresentation(feedLive = true, sending = true),
                onToggleRecord = {},
            )
        }

        composeRule
            .onNodeWithContentDescription("Start camera recording")
            .assertIsNotEnabled()
    }

    private fun connectedPresentation(
        feedLive: Boolean,
        batteryPercent: Int = 80,
        sending: Boolean = false,
    ): WearMonitorPresentation =
        WearMonitorPresentation(
            phoneReachable = true,
            state =
                WatchRelayState(
                    recordState = WatchRecordState.STANDBY,
                    timecode = WatchTimecode(true, 1, 2, 3, 4),
                    mediaStatus = null,
                    media = "521 GB · 47%",
                    cameraBatteryPercent = batteryPercent,
                    cameraName = "Nikon ZR",
                    isRecording = false,
                    connection = WatchConnectionState.CONNECTED,
                    feedLive = feedLive,
                    liveFPS = "25",
                ),
            frame = null,
            frameTimecode = null,
            isSendingCommand = sending,
            commandMessage = null,
        )
}
