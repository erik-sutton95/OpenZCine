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
import com.opencapture.openzcine.wearrelay.WatchRelayEnvelope
import com.opencapture.openzcine.wearrelay.WatchRelayState
import com.opencapture.openzcine.wearrelay.WatchTimecode
import org.json.JSONObject
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

    /** SIMULATED declared precision is retained without allocating a cell for every dense step. */
    @Test
    fun denseGaugeUsesItsExactFilledOfText() {
        composeRule.setContent {
            WearMonitorContent(
                presentation = connectedPresentation(feedLive = false,
                    reading = JSONObject().put("kind", "steps").put("filled", 1).put("of", 11)),
                onToggleRecord = {},
            )
        }
        composeRule.onNodeWithText("1/11").assertExists()
        composeRule.onNodeWithContentDescription("Camera battery 1 of 11 bars").assertExists()
    }

    /** SIMULATED large but valid wire counts finish rendering and retain their actual count. */
    @Test
    fun largeGaugeFinishesRenderingAndKeepsItsExactCount() {
        composeRule.setContent {
            WearMonitorContent(
                presentation = connectedPresentation(feedLive = false,
                    reading = JSONObject().put("kind", "steps").put("filled", 1).put("of", 1_000_000)),
                onToggleRecord = {},
            )
        }
        composeRule.onNodeWithText("1/1000000").assertExists()
        composeRule.onNodeWithContentDescription("Camera battery 1 of 1000000 bars").assertExists()
    }

    /** SIMULATED typed null never falls back to a retained legacy scalar. */
    @Test
    fun explicitUnknownBatteryIsAbsent() {
        composeRule.setContent {
            WearMonitorContent(
                presentation = connectedPresentation(feedLive = false, batteryPercent = 80, reading = null),
                onToggleRecord = {},
            )
        }
        composeRule.onNodeWithText("80%").assertDoesNotExist()
        composeRule.onNodeWithContentDescription("Camera battery", substring = true).assertDoesNotExist()
    }

    private fun connectedPresentation(
        feedLive: Boolean,
        batteryPercent: Int = 80,
        sending: Boolean = false,
        reading: JSONObject? = JSONObject().put("kind", "fraction").put("value", batteryPercent / 100.0),
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
                    cameraName = "SIMULATED",
                    isRecording = false,
                    connection = WatchConnectionState.CONNECTED,
                    feedLive = feedLive,
                    liveFPS = "25",
                ).let { legacy ->
                    val envelope = WatchRelayEnvelope.encode(legacy)
                    val json = JSONObject(String(envelope, 1, envelope.size - 1, Charsets.UTF_8))
                        .put("batteryReading", reading ?: JSONObject.NULL)
                        .put("batteryExhausted", JSONObject.NULL)
                    WatchRelayEnvelope.decode(byteArrayOf(envelope[0]) +
                        json.toString().toByteArray(Charsets.UTF_8)) as WatchRelayState
                },
            frame = null,
            frameTimecode = null,
            isSendingCommand = sending,
            commandMessage = null,
        )
}
