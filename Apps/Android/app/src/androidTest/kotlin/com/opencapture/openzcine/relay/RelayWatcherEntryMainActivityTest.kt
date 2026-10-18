package com.opencapture.openzcine.relay

import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.captureToImage
import androidx.compose.ui.test.onRoot
import androidx.compose.ui.graphics.asAndroidBitmap
import android.content.Context
import android.content.Intent
import android.content.pm.ActivityInfo
import android.content.res.Configuration
import androidx.compose.ui.test.junit4.v2.createEmptyComposeRule
import androidx.test.core.app.ActivityScenario
import androidx.test.platform.app.InstrumentationRegistry
import androidx.compose.ui.test.onNodeWithContentDescription
import androidx.compose.ui.test.onAllNodesWithContentDescription
import androidx.compose.ui.test.onAllNodesWithTag
import androidx.compose.ui.test.onAllNodesWithText
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.performClick
import androidx.compose.ui.test.performScrollTo
import androidx.test.ext.junit.runners.AndroidJUnit4
import com.opencapture.openzcine.MainActivity
import com.opencapture.openzcine.pairing.CAMERAS_DOCUMENT_PREFERENCES
import com.opencapture.openzcine.pairing.SharedPreferencesSavedCameraStore
import org.junit.Assert.assertEquals
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith

/** SIMULATED private app host, through the actual Nikon first-pair root and shell actions. */
@RunWith(AndroidJUnit4::class)
class RelayWatcherEntryMainActivityTest {
    @get:Rule val compose = createEmptyComposeRule()

    @Test
    fun actualFirstPairWatchActionMountsSharedBrowseAndCloseReturnsToPairing() {
        val context = InstrumentationRegistry.getInstrumentation().targetContext
        val records = context.getSharedPreferences(SharedPreferencesSavedCameraStore.PREFERENCES_NAME, Context.MODE_PRIVATE)
        val document = context.getSharedPreferences(CAMERAS_DOCUMENT_PREFERENCES, Context.MODE_PRIVATE)
        val savedRecords = records.getString(SharedPreferencesSavedCameraStore.RECORDS_KEY, null)
        val savedDocument = document.getString("document", null)
        // First pairing requires both the canonical records and their shared document to be empty.
        // Seed before launching; the activity-retained root reads them once when it is created.
        try {
            check(records.edit().remove(SharedPreferencesSavedCameraStore.RECORDS_KEY).commit())
            check(document.edit().remove("document").commit())
            ActivityScenario.launch<MainActivity>(Intent(context, MainActivity::class.java)
                .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TASK)).use { scenario ->
                val expectedOrientation = watcherProofOrientation()
                scenario.onActivity {
                    it.requestedOrientation = if (expectedOrientation == Configuration.ORIENTATION_PORTRAIT)
                        ActivityInfo.SCREEN_ORIENTATION_PORTRAIT else ActivityInfo.SCREEN_ORIENTATION_LANDSCAPE
                }
                compose.waitUntil(10_000) {
                    context.resources.configuration.orientation == expectedOrientation
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
        } finally {
            check(records.edit().putString(SharedPreferencesSavedCameraStore.RECORDS_KEY, savedRecords).commit())
            check(document.edit().putString("document", savedDocument).commit())
            assertEquals(savedRecords, records.getString(SharedPreferencesSavedCameraStore.RECORDS_KEY, null))
            assertEquals(savedDocument, document.getString("document", null))
        }
    }
}
