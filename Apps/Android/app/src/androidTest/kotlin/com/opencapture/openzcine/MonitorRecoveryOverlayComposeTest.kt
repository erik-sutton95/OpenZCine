package com.opencapture.openzcine

import androidx.compose.ui.test.assertHeightIsAtLeast
import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.performClick
import androidx.compose.ui.unit.dp
import androidx.test.ext.junit.runners.AndroidJUnit4
import com.opencapture.opencine.vocabulary.SessionRecoveryUi
import org.junit.Assert.assertEquals
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith

/** Nikon's recovery card is the shared card with this camera's copy and 48 dp actions. */
@RunWith(AndroidJUnit4::class)
class MonitorRecoveryOverlayComposeTest {
    @get:Rule val compose = createComposeRule()

    @Test
    fun pausedCardNamesAnotherScanningDeviceAndKeepsTouchTargets() {
        var retries = 0
        var menus = 0
        compose.setContent {
            MonitorRecoveryOverlay(
                state = SessionRecoveryUi.PausedAfterDrops(drops = 3),
                cameraName = "Z 6III",
                onRetry = { retries += 1 },
                onBackToOperatorMenu = { menus += 1 },
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
