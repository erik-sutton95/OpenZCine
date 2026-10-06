package com.opencapture.openzcine.media

import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.performClick
import androidx.test.ext.junit.runners.AndroidJUnit4
import org.junit.Assert.assertEquals
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith

/** The camera-card delete confirmation is the shared confirm card: Nikon's wording, Cancel and Delete. */
@RunWith(AndroidJUnit4::class)
class MediaDeleteConfirmComposeTest {
    @get:Rule val compose = createComposeRule()

    @Test
    fun confirmCarriesTheCompanionWordingAndRoutesBothButtons() {
        val message = "Delete this photo from the camera card? Both the RAW and JPEG files are removed."
        var deletes = 0
        var dismissals = 0
        compose.setContent { MediaDeleteConfirmDialog(message, onDelete = { deletes += 1 }, onDismiss = { dismissals += 1 }) }

        compose.onNodeWithText(message).assertIsDisplayed()
        compose.onNodeWithText("Cancel").performClick()
        compose.onNodeWithText("Delete").performClick()
        compose.waitForIdle()
        assertEquals(1, dismissals)
        assertEquals(1, deletes)
    }
}
