package com.opencapture.openzcine.pairing

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.padding
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.test.assertCountEquals
import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.test.onAllNodesWithText
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.unit.dp
import androidx.test.ext.junit.runners.AndroidJUnit4
import com.opencapture.openzcine.OpenZCineTheme
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith

/**
 * iOS parity: camera list rows have Connect / ⋯ only. Offline media is opened
 * from the intro card's Media Library, never a per-row button under the camera.
 */
@RunWith(AndroidJUnit4::class)
class SavedCameraCachedMediaComposeTest {
    @get:Rule
    val composeRule = createComposeRule()

    @Test
    fun cameraRowHasNoPerCameraMediaLibraryButton() {
        composeRule.setContent {
            OpenZCineTheme {
                Box(Modifier.fillMaxSize().background(Color.Black).padding(16.dp)) {
                    SavedCameraRow(
                        record = camera("camera-a", "A Camera"),
                        isDiscovered = false,
                        enabled = true,
                        onConnect = {},
                        onRename = {},
                        onRemove = {},
                    )
                }
            }
        }

        composeRule.onNodeWithText("A Camera").assertIsDisplayed()
        composeRule.onAllNodesWithText("Media Library").assertCountEquals(0)
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
