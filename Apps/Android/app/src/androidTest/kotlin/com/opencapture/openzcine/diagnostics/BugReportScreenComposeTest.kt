package com.opencapture.openzcine.diagnostics

import androidx.compose.ui.semantics.SemanticsActions
import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.test.onAllNodesWithText
import androidx.compose.ui.test.onNodeWithContentDescription
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.performClick
import androidx.compose.ui.test.performScrollTo
import androidx.compose.ui.test.performSemanticsAction
import androidx.compose.ui.text.AnnotatedString
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

        enterText("Bug report summary", "Live view freezes")
        enterText("What happened", "Preview stopped after reconnecting.")
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

        enterText("Bug report summary", " again")
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
    fun activityLogSelectionKeepsRetryKeyUntilTheSelectedAttachmentChanges() {
        val submitter = RecordingSubmitter(BugReportSubmissionResult.Failed(BugReportSubmissionFailure.NETWORK))
        compose.setContent {
            OpenZCineTheme {
                BugReportScreen(
                    submitter = submitter,
                    activityLogProvider = { listOf("app.launched") },
                    onOpenSecurityAdvisory = { true },
                    onClose = {},
                )
            }
        }

        enterText("Bug report summary", "Live view freezes")
        enterText("What happened", "Preview stopped after reconnecting.")
        compose
            .onNodeWithContentDescription("Include privacy-filtered app activity log")
            .performScrollTo()
            .performClick()
        compose.waitUntil(timeoutMillis = 5_000) {
            compose
                .onAllNodesWithText("1 app events ready. Timestamps and device information are excluded.")
                .fetchSemanticsNodes().isNotEmpty()
        }
        compose
            .onNodeWithContentDescription("Send anonymous bug report")
            .performScrollTo()
            .performClick()
        compose.waitUntil(timeoutMillis = 5_000) { submitter.submissions.size == 1 }
        compose
            .onNodeWithContentDescription("Send anonymous bug report")
            .performScrollTo()
            .performClick()
        compose.waitUntil(timeoutMillis = 5_000) { submitter.submissions.size == 2 }

        compose
            .onNodeWithContentDescription("Include privacy-filtered app activity log")
            .performScrollTo()
            .performClick()
        compose
            .onNodeWithContentDescription("Send anonymous bug report")
            .performScrollTo()
            .performClick()
        compose.waitUntil(timeoutMillis = 5_000) { submitter.submissions.size == 3 }
        compose.runOnIdle {
            assertEquals(listOf("app.launched"), submitter.submissions[0].activityLog)
            assertEquals(
                submitter.submissions[0].idempotencyKey,
                submitter.submissions[1].idempotencyKey,
            )
            assertNotEquals(
                submitter.submissions[1].idempotencyKey,
                submitter.submissions[2].idempotencyKey,
            )
            assertEquals(false, submitter.submissions[2].includeActivityLog)
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

        enterText("Bug report summary", "Live view freezes")
        enterText("What happened", "Preview stopped after reconnecting.")
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

        enterText("Bug report summary", "Live view freezes")
        enterText("What happened", "Preview stopped after reconnecting.")
        compose.waitForIdle()
        compose
            .onNodeWithContentDescription("Send anonymous bug report")
            .performScrollTo()
            .performClick()

        compose.waitUntil(timeoutMillis = 5_000) { submitter.submissions.size == 1 }
        compose
            .onNodeWithText(
                "This report or its attachments are too large to send. Shorten the text or remove an attachment.",
            ).assertIsDisplayed()
        compose
            .onNodeWithContentDescription("Bug report summary")
            .performScrollTo()
            .assertIsDisplayed()
    }

    // Text goes in through the field's own semantics action without focusing it, so no soft
    // keyboard opens. The screen's imePadding moves Send while a keyboard animates, and Compose
    // idling does not wait for that, so a tap right after typing could miss the button.
    private fun enterText(field: String, text: String) {
        compose
            .onNodeWithContentDescription(field)
            .performScrollTo()
            .performSemanticsAction(SemanticsActions.InsertTextAtCursor) { it(AnnotatedString(text)) }
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
