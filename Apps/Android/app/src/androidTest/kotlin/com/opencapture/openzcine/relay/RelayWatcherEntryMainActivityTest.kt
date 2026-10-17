package com.opencapture.openzcine.relay

import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.captureToImage
import androidx.compose.ui.test.onRoot
import androidx.compose.ui.graphics.asAndroidBitmap
import android.content.pm.ActivityInfo
import android.content.res.Configuration
import androidx.compose.ui.test.junit4.createAndroidComposeRule
import androidx.compose.ui.test.onNodeWithContentDescription
import androidx.compose.ui.test.onAllNodesWithContentDescription
import androidx.compose.ui.test.onAllNodesWithTag
import androidx.compose.ui.test.onAllNodesWithText
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.performClick
import androidx.compose.ui.test.performScrollTo
import androidx.test.ext.junit.runners.AndroidJUnit4
import com.opencapture.openzcine.MainActivity
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith

/** SIMULATED private app host, through the actual Nikon first-pair root and shell actions. */
@RunWith(AndroidJUnit4::class)
class RelayWatcherEntryMainActivityTest {
    @get:Rule val compose = createAndroidComposeRule<MainActivity>()

    @Test
    fun actualFirstPairWatchActionMountsSharedBrowseAndCloseReturnsToPairing() {
        val expectedOrientation = watcherProofOrientation()
        compose.activityRule.scenario.onActivity {
            it.requestedOrientation = if (expectedOrientation == Configuration.ORIENTATION_PORTRAIT)
                ActivityInfo.SCREEN_ORIENTATION_PORTRAIT else ActivityInfo.SCREEN_ORIENTATION_LANDSCAPE
        }
        compose.waitUntil(10_000) {
            compose.activity.resources.configuration.orientation == expectedOrientation
        }
        compose.waitUntil(10_000) {
            compose.onAllNodesWithTag("monitor-launch-splash").fetchSemanticsNodes().isEmpty()
        }
        if (compose.onAllNodesWithText("Not now").fetchSemanticsNodes().isNotEmpty()) {
            compose.onNodeWithText("Not now").performClick()
        }
        compose.waitUntil(10_000) {
            compose.onAllNodesWithContentDescription("Pairing help and diagnostics")
                .fetchSemanticsNodes().isNotEmpty()
        }
        compose.onNodeWithContentDescription("Pairing help and diagnostics").performClick()
        compose.onNodeWithText("Watch a feed").performClick()
        compose.onNodeWithText("Find shared feeds").performScrollTo().assertIsDisplayed()
        saveWatcherProofImage(compose.onRoot().captureToImage().asAndroidBitmap(), "actual-entry", expectedOrientation)
        compose.onNodeWithText("Close").performScrollTo().performClick()
        compose.onNodeWithContentDescription("Pairing help and diagnostics").assertIsDisplayed()
    }
}
