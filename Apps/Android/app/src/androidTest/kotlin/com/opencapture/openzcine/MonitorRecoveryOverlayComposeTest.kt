package com.opencapture.openzcine

import androidx.compose.runtime.mutableStateOf
import androidx.compose.ui.test.assertHeightIsAtLeast
import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.performClick
import androidx.compose.ui.unit.dp
import androidx.test.ext.junit.runners.AndroidJUnit4
import com.opencapture.opencine.cameracontrols.MonitorOperatorRecoveryCard
import com.opencapture.opencine.vocabulary.SessionDropSuspect
import com.opencapture.opencine.vocabulary.SessionRecoveryDrive
import com.opencapture.opencine.vocabulary.SessionRecoveryUi
import org.junit.Assert.assertEquals
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith

/** Nikon's recovery card is the shared card with this camera's copy and its 48 dp actions. */
@RunWith(AndroidJUnit4::class)
class MonitorRecoveryOverlayComposeTest {
    @get:Rule val compose = createComposeRule()

    @Test
    fun pausedCardNamesAnotherScanningDeviceAndKeepsTouchTargets() {
        var retries = 0
        var menus = 0
        compose.setContent {
            MonitorOperatorRecoveryCard(
                state = SessionRecoveryUi.PausedAfterDrops(drops = 3),
                cameraName = "Z 6III",
                onRetry = { retries += 1 },
                onOperatorMenu = { menus += 1 },
                dropSuspect = SessionDropSuspect.OTHER_DEVICE_SCANNING,
            )
        }
        compose.onNodeWithText("Connection keeps dropping").assertIsDisplayed()
        compose.onNodeWithText("another device may be scanning for cameras", substring = true).assertIsDisplayed()
        compose.onNodeWithText("Retry connection").assertHeightIsAtLeast(48.dp).performClick()
        compose.onNodeWithText("Operator menu").assertHeightIsAtLeast(48.dp).performClick()
        assertEquals(1, retries)
        assertEquals(1, menus)
    }

    /** A3-24: the shared card stays quiet while the first retry is inside its grace; later attempts show at once. */
    @Test
    fun theFirstRetryWaitsOutItsGraceAndLaterAttemptsShowAtOnce() {
        compose.mainClock.autoAdvance = false
        val state = mutableStateOf<SessionRecoveryUi>(SessionRecoveryUi.Retrying(attempt = 1, maxAttempts = 3))
        compose.setContent { OpenZCineTheme { MonitorOperatorRecoveryCard(state.value, "NIKON ZR", {}, {}) } }
        compose.mainClock.advanceTimeBy(SessionRecoveryDrive.CARD_GRACE_MS - 200)
        compose.onNodeWithText("Reconnecting…").assertDoesNotExist()
        compose.mainClock.advanceTimeBy(400)
        compose.onNodeWithText("Reconnecting…").assertExists()
        compose.runOnIdle { state.value = SessionRecoveryUi.Idle }
        compose.mainClock.advanceTimeBy(100)
        compose.runOnIdle { state.value = SessionRecoveryUi.Retrying(attempt = 2, maxAttempts = 3) }
        compose.mainClock.advanceTimeBy(100)
        compose.onNodeWithText("Reconnecting…").assertExists()
    }
}
