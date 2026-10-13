package com.opencapture.openzcine.gyro

import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.junit4.v2.createComposeRule
import androidx.compose.ui.test.hasAnyAncestor
import androidx.compose.ui.test.hasTestTag
import androidx.compose.ui.test.hasText
import androidx.compose.ui.test.onNodeWithTag
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.performClick
import androidx.compose.ui.test.performScrollTo
import androidx.test.ext.junit.runners.AndroidJUnit4
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import java.io.File

@RunWith(AndroidJUnit4::class)
class GyroLogsComposeTest {
    @get:Rule val compose = createComposeRule()

    @Test fun savedLogActionsRouteTheSelectedArtifactAndShowPartialHealth() {
        val descriptor = JSONObject().put("id", "test-log").put("cameraLabel", "Nikon ZR")
            .put("startDate", 123_000).put("approximateStartOffset", 2.0)
        val summary = JSONObject().put("descriptor", descriptor).put("duration", 5.0)
            .put("measuredRate", 100.0).put("largestGap", 0.08).put("isPartial", true)
        val entry = GyroLogEntry(summary, File("test.gcsv"))
        var shared: GyroLogEntry? = null
        var deleted: GyroLogEntry? = null
        var closed = false
        compose.setContent {
            GyroLogsScreen(GyroCaptureState(logs = listOf(entry)),
                onShare = { shared = it }, onDelete = { deleted = it }, onClose = { closed = true })
        }
        compose.onNodeWithText("5.0 s · 100.0 Hz · Partial").performScrollTo().assertIsDisplayed()
        compose.onNodeWithTag("gyro-share-test-log").performScrollTo().performClick()
        compose.onNodeWithTag("gyro-delete-test-log").performScrollTo().performClick()
        compose.runOnIdle { assertEquals(null, deleted) }
        compose.onNode(hasText("Delete") and hasAnyAncestor(hasTestTag("gyro-delete-confirmation"))).performClick()
        compose.onNodeWithText("Close").performClick()
        compose.runOnIdle {
            assertEquals(entry, shared)
            assertEquals(entry, deleted)
            assertEquals(true, closed)
        }
    }
}
