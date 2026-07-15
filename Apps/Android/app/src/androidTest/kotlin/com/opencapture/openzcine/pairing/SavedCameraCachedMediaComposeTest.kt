package com.opencapture.openzcine.pairing

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.padding
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.test.assertCountEquals
import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.test.onAllNodesWithText
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.performClick
import androidx.compose.ui.unit.dp
import androidx.test.ext.junit.runners.AndroidJUnit4
import com.opencapture.openzcine.OpenZCineTheme
import org.junit.Assert.assertEquals
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith

/** Device contract for the disconnected media entry point on saved camera cards. */
@RunWith(AndroidJUnit4::class)
class SavedCameraCachedMediaComposeTest {
    @get:Rule
    val composeRule = createComposeRule()

    @Test
    fun eachCachedCameraOpensItsOwnLibraryBucket() {
        val opened = mutableListOf<String>()
        val first = camera("camera-a", "A Camera")
        val second = camera("camera-b", "B Camera")
        composeRule.setContent {
            OpenZCineTheme {
                Row(
                    Modifier.fillMaxSize().background(Color.Black).padding(16.dp),
                    horizontalArrangement = Arrangement.spacedBy(12.dp),
                ) {
                    Column(Modifier.weight(1f)) {
                        SavedCameraRow(
                            record = first,
                            isDiscovered = false,
                            hasCachedMedia = true,
                            enabled = true,
                            onConnect = {},
                            onOpenCachedMedia = { opened += first.id },
                            onRename = {},
                            onRemove = {},
                        )
                    }
                    Column(Modifier.weight(1f)) {
                        SavedCameraRow(
                            record = second,
                            isDiscovered = false,
                            hasCachedMedia = true,
                            enabled = true,
                            onConnect = {},
                            onOpenCachedMedia = { opened += second.id },
                            onRename = {},
                            onRemove = {},
                        )
                    }
                }
            }
        }

        composeRule.onAllNodesWithText("Browse cached media").assertCountEquals(2)
        composeRule.onAllNodesWithText("Browse cached media")[0].assertIsDisplayed().performClick()
        composeRule.onAllNodesWithText("Browse cached media")[1].assertIsDisplayed().performClick()

        composeRule.runOnIdle { assertEquals(listOf("camera-a", "camera-b"), opened) }
    }

    @Test
    fun cameraWithoutACompleteCacheHasNoOfflineEntryPoint() {
        composeRule.setContent {
            OpenZCineTheme {
                SavedCameraRow(
                    record = camera("camera-a", "A Camera"),
                    isDiscovered = false,
                    hasCachedMedia = false,
                    enabled = true,
                    onConnect = {},
                    onOpenCachedMedia = { error("Unavailable cache action was invoked.") },
                    onRename = {},
                    onRemove = {},
                )
            }
        }

        composeRule.onAllNodesWithText("Browse cached media").assertCountEquals(0)
    }

    private fun camera(host: String, name: String): SavedCameraRecord =
        SavedCameraRecord(
            host = host,
            cameraName = name,
            transport = SavedCameraTransport.USB_C,
            lastSeenAtEpochMillis = 1L,
            wifiSsid = null,
        )

}
