package com.opencapture.openzcine.diagnostics

import androidx.compose.ui.test.assertHeightIsAtLeast
import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.junit4.v2.createComposeRule
import androidx.compose.ui.test.onNodeWithContentDescription
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.performClick
import androidx.compose.ui.test.performScrollTo
import androidx.compose.ui.unit.dp
import com.opencapture.openzcine.OpenZCineTheme
import org.junit.Assert.assertEquals
import org.junit.Rule
import org.junit.Test

class BugReportPathChooserComposeTest {
    @get:Rule val compose = createComposeRule()

    @Test
    fun anonymousChoiceUsesTheNativeFlowWithoutOpeningGitHub() {
        var anonymousSelections = 0
        var githubOpens = 0
        compose.setContent {
            OpenZCineTheme {
                BugReportPathChooser(
                    onChooseAnonymous = { anonymousSelections += 1 },
                    onContinueWithGitHub = {
                        githubOpens += 1
                        true
                    },
                    onClose = {},
                )
            }
        }

        compose
            .onNodeWithContentDescription(
                "Report anonymously. No GitHub account needed. This creates a public GitHub issue.",
            )
            .performScrollTo()
            .assertHeightIsAtLeast(48.dp)
            .performClick()

        compose.runOnIdle {
            assertEquals(1, anonymousSelections)
            assertEquals(0, githubOpens)
        }
    }

    @Test
    fun githubChoiceOpensTheCanonicalFormAndClosesTheChooser() {
        var githubOpens = 0
        var closes = 0
        compose.setContent {
            OpenZCineTheme {
                BugReportPathChooser(
                    onChooseAnonymous = {},
                    onContinueWithGitHub = {
                        githubOpens += 1
                        true
                    },
                    onClose = { closes += 1 },
                )
            }
        }

        compose
            .onNodeWithContentDescription(
                "Continue with GitHub. Opens the public GitHub issue form in your browser and requires sign-in.",
            )
            .performScrollTo()
            .assertHeightIsAtLeast(48.dp)
            .performClick()

        compose.runOnIdle {
            assertEquals(1, githubOpens)
            assertEquals(1, closes)
        }
    }

    @Test
    fun unavailableGithubActionKeepsTheChooserOpenAndExplainsWhy() {
        var closes = 0
        compose.setContent {
            OpenZCineTheme {
                BugReportPathChooser(
                    onChooseAnonymous = {},
                    onContinueWithGitHub = { false },
                    onClose = { closes += 1 },
                )
            }
        }

        compose
            .onNodeWithContentDescription(
                "Continue with GitHub. Opens the public GitHub issue form in your browser and requires sign-in.",
            )
            .performScrollTo()
            .performClick()

        compose.onNodeWithText("No app is available for that action.").assertIsDisplayed()
        compose.runOnIdle { assertEquals(0, closes) }
    }
}
