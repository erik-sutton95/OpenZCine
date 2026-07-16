package com.opencapture.openzcine.diagnostics

import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.test.onNodeWithContentDescription
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.performClick
import androidx.compose.ui.test.performScrollTo
import androidx.compose.ui.test.performTextInput
import com.opencapture.openzcine.OpenZCineTheme
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotEquals
import org.junit.Rule
import org.junit.Test

class BugReportScreenComposeTest {
    @get:Rule val compose = createComposeRule()

    @Test
    fun failedUnchangedRetryReusesItsKeyAndFieldChangesCreateANewKey() {
        val submitter = RecordingSubmitter(BugReportSubmissionResult.Failed(BugReportSubmissionFailure.NETWORK))
        compose.setContent {
            OpenZCineTheme {
                BugReportScreen(
                    submitter = submitter,
                    onOpenSecurityAdvisory = { true },
                    onClose = {},
                )
            }
        }

        compose
            .onNodeWithContentDescription("Bug report summary")
            .performScrollTo()
            .performTextInput("Live view freezes")
        compose
            .onNodeWithContentDescription("What happened")
            .performScrollTo()
            .performTextInput("Preview stopped after reconnecting.")
        compose.waitForIdle()
        compose
            .onNodeWithContentDescription("Send anonymous bug report")
            .performScrollTo()
            .performClick()
        compose.waitUntil(timeoutMillis = 5_000) { submitter.submissions.size == 1 }
        compose.onNodeWithText("Couldn't send this report. Your text is still here; try again later.")
            .assertIsDisplayed()

        compose
            .onNodeWithContentDescription("Send anonymous bug report")
            .performScrollTo()
            .performClick()
        compose.waitUntil(timeoutMillis = 5_000) { submitter.submissions.size == 2 }
        compose.runOnIdle {
            assertEquals(
                submitter.submissions[0].idempotencyKey,
                submitter.submissions[1].idempotencyKey,
            )
        }

        compose
            .onNodeWithContentDescription("Bug report summary")
            .performScrollTo()
            .performTextInput(" again")
        compose.waitForIdle()
        compose
            .onNodeWithContentDescription("Send anonymous bug report")
            .performScrollTo()
            .performClick()
        compose.waitUntil(timeoutMillis = 5_000) { submitter.submissions.size == 3 }
        compose.runOnIdle {
            assertNotEquals(
                submitter.submissions[1].idempotencyKey,
                submitter.submissions[2].idempotencyKey,
            )
        }
    }

    @Test
    fun successfulNativeSubmissionShowsTheAnonymousConfirmation() {
        val submitter = RecordingSubmitter(BugReportSubmissionResult.Submitted)
        compose.setContent {
            OpenZCineTheme {
                BugReportScreen(
                    submitter = submitter,
                    onOpenSecurityAdvisory = { true },
                    onClose = {},
                )
            }
        }

        compose
            .onNodeWithContentDescription("Bug report summary")
            .performScrollTo()
            .performTextInput("Live view freezes")
        compose
            .onNodeWithContentDescription("What happened")
            .performScrollTo()
            .performTextInput("Preview stopped after reconnecting.")
        compose.waitForIdle()
        compose
            .onNodeWithContentDescription("Send anonymous bug report")
            .performScrollTo()
            .performClick()

        compose.waitUntil(timeoutMillis = 5_000) { submitter.submissions.size == 1 }
        compose.onNodeWithText("Report sent").assertIsDisplayed()
        compose
            .onNodeWithText(
                "Your anonymous report was sent for public triage. It has no contact details, so OpenZCine cannot reply privately.",
            ).assertIsDisplayed()
    }

    @Test
    fun relayPayloadValidationKeepsTheDraftAndExplainsHowToReduceIt() {
        val submitter =
            RecordingSubmitter(
                BugReportSubmissionResult.Invalid(
                    BugReportValidation(
                        summary = null,
                        whatHappened = null,
                        stepsToReproduce = null,
                        payload = BugReportPayloadError.TOO_LARGE,
                    ),
                ),
            )
        compose.setContent {
            OpenZCineTheme {
                BugReportScreen(
                    submitter = submitter,
                    onOpenSecurityAdvisory = { true },
                    onClose = {},
                )
            }
        }

        compose
            .onNodeWithContentDescription("Bug report summary")
            .performScrollTo()
            .performTextInput("Live view freezes")
        compose
            .onNodeWithContentDescription("What happened")
            .performScrollTo()
            .performTextInput("Preview stopped after reconnecting.")
        compose.waitForIdle()
        compose
            .onNodeWithContentDescription("Send anonymous bug report")
            .performScrollTo()
            .performClick()

        compose.waitUntil(timeoutMillis = 5_000) { submitter.submissions.size == 1 }
        compose
            .onNodeWithText(
                "This report is too large to send. Shorten what happened or the reproduction steps.",
            ).assertIsDisplayed()
        compose
            .onNodeWithContentDescription("Bug report summary")
            .performScrollTo()
            .assertIsDisplayed()
    }

    private class RecordingSubmitter(
        private val result: BugReportSubmissionResult,
    ) : BugReportSubmitter {
        val submissions = mutableListOf<BugReportSubmission>()

        override suspend fun submit(submission: BugReportSubmission): BugReportSubmissionResult {
            submissions += submission
            return result
        }
    }
}
