package com.opencapture.openzcine

import androidx.compose.ui.test.assertHeightIsAtLeast
import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.performClick
import androidx.compose.ui.unit.dp
import androidx.test.ext.junit.runners.AndroidJUnit4
import com.opencapture.opencine.cameracontrols.MonitorOperatorRecoveryCard
import com.opencapture.opencine.vocabulary.SessionDropSuspect
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
}
