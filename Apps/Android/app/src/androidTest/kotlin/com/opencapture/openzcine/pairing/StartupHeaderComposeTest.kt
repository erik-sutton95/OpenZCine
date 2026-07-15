package com.opencapture.openzcine.pairing

import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.junit4.v2.createComposeRule
import androidx.compose.ui.test.onNodeWithContentDescription
import androidx.compose.ui.test.performClick
import com.opencapture.openzcine.OpenZCineTheme
import org.junit.Assert.assertEquals
import org.junit.Rule
import org.junit.Test

class StartupHeaderComposeTest {
    @get:Rule val compose = createComposeRule()

    @Test
    fun legalLinksRemainVisibleAndInvokeTheirOwnActions() {
        var privacyClicks = 0
        var termsClicks = 0
        compose.setContent {
            OpenZCineTheme {
                StartupHeader(
                    title = "Connection setup",
                    statusTitle = "Ready",
                    isBusy = false,
                    onOpenPrivacy = { privacyClicks += 1 },
                    onOpenTerms = { termsClicks += 1 },
                )
            }
        }

        compose.onNodeWithContentDescription("Open the OpenZCine Privacy page")
            .assertIsDisplayed()
            .performClick()
        compose.onNodeWithContentDescription("Open the OpenZCine Terms page")
            .assertIsDisplayed()
            .performClick()

        compose.runOnIdle {
            assertEquals(1, privacyClicks)
            assertEquals(1, termsClicks)
        }
    }
}
