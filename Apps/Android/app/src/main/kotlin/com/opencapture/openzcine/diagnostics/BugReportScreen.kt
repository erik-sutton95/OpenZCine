package com.opencapture.openzcine.diagnostics

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.WindowInsets
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.imePadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.safeDrawing
import androidx.compose.foundation.layout.windowInsetsPadding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.Button
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import com.opencapture.openzcine.LiveDesign
import com.opencapture.openzcine.R
import com.opencapture.openzcine.chromeStyle
import com.opencapture.openzcine.settings.PanelCloseButton
import com.opencapture.openzcine.settings.SettingsGroupCard
import java.util.UUID
import kotlinx.coroutines.launch

/**
 * Full-screen anonymous-report form. Draft text is composition-local only: it
 * is never saved, queued, attached to diagnostics, or uploaded automatically.
 */
@Composable
internal fun BugReportScreen(
    submitter: BugReportSubmitter,
    onOpenSecurityAdvisory: () -> Boolean,
    onClose: () -> Unit,
) {
    var summary by remember { mutableStateOf("") }
    var whatHappened by remember { mutableStateOf("") }
    var stepsToReproduce by remember { mutableStateOf("") }
    var frequency by remember { mutableStateOf(BugReportFrequency.UNKNOWN) }
    var connection by remember { mutableStateOf(BugReportConnection.UNKNOWN) }
    var attemptedValidation by remember { mutableStateOf<BugReportValidation?>(null) }
    var submission by remember { mutableStateOf<BugReportSubmissionResult?>(null) }
    var isSending by remember { mutableStateOf(false) }
    var securityActionUnavailable by remember { mutableStateOf(false) }
    var idempotencyKey by remember { mutableStateOf(UUID.randomUUID().toString()) }
    val scope = rememberCoroutineScope()

    fun resetChangedDraftState() {
        attemptedValidation = null
        submission = null
        idempotencyKey = UUID.randomUUID().toString()
    }

    val validation = attemptedValidation
    val result = submission
    val openSecurityDescription =
        "${stringResource(R.string.action_open)} " +
            stringResource(R.string.bug_report_security_advisory)
    val sendDescription = stringResource(R.string.bug_report_send_description)
    val submissionFailedDescription = stringResource(R.string.bug_report_submission_failed)

    if (result is BugReportSubmissionResult.Submitted) {
        BugReportSuccessScreen(onClose)
        return
    }

    Box(
        Modifier.fillMaxSize()
            .background(LiveDesign.background)
            .windowInsetsPadding(WindowInsets.safeDrawing)
            .imePadding(),
    ) {
        Column(
            Modifier.fillMaxSize()
                .verticalScroll(rememberScrollState())
                .padding(start = 61.dp, top = 14.dp, end = 16.dp, bottom = 14.dp),
            verticalArrangement = Arrangement.spacedBy(12.dp),
        ) {
            Column(
                verticalArrangement = Arrangement.spacedBy(4.dp),
            ) {
                Text(
                    stringResource(R.string.bug_report_title),
                    style = chromeStyle(24f, FontWeight.SemiBold),
                    color = LiveDesign.text,
                )
                Text(
                    stringResource(R.string.bug_report_subtitle),
                    style = chromeStyle(12.5f, FontWeight.Normal),
                    color = LiveDesign.muted,
                )
            }

            SettingsGroupCard(
                title = stringResource(R.string.bug_report_details_title),
                caption = stringResource(R.string.bug_report_details_caption),
            ) {
                BugReportTextField(
                    value = summary,
                    onValueChange = {
                        if (summary != it) {
                            summary = it
                            resetChangedDraftState()
                        }
                    },
                    label = stringResource(R.string.bug_report_summary),
                    contentDescription = stringResource(R.string.bug_report_summary_description),
                    error = validation?.summary,
                    maximumLength = BugReportDraft.MAXIMUM_SUMMARY_LENGTH,
                    singleLine = true,
                    minLines = 1,
                    enabled = !isSending,
                )
                BugReportTextField(
                    value = whatHappened,
                    onValueChange = {
                        if (whatHappened != it) {
                            whatHappened = it
                            resetChangedDraftState()
                        }
                    },
                    label = stringResource(R.string.bug_report_happened),
                    contentDescription = stringResource(R.string.bug_report_happened_description),
                    error = validation?.whatHappened,
                    maximumLength = BugReportDraft.MAXIMUM_DESCRIPTION_LENGTH,
                    singleLine = false,
                    minLines = 5,
                    enabled = !isSending,
                )
                BugReportTextField(
                    value = stepsToReproduce,
                    onValueChange = {
                        if (stepsToReproduce != it) {
                            stepsToReproduce = it
                            resetChangedDraftState()
                        }
                    },
                    label = stringResource(R.string.bug_report_steps),
                    contentDescription = stringResource(R.string.bug_report_steps_description),
                    error = validation?.stepsToReproduce,
                    maximumLength = BugReportDraft.MAXIMUM_STEPS_LENGTH,
                    singleLine = false,
                    minLines = 3,
                    enabled = !isSending,
                )
            }

            SettingsGroupCard(
                title = stringResource(R.string.bug_report_context_title),
                caption = stringResource(R.string.bug_report_context_caption),
            ) {
                BugReportChoiceMenu(
                    label = stringResource(R.string.bug_report_frequency),
                    contentDescription = stringResource(R.string.bug_report_frequency_description),
                    value = frequency,
                    values = BugReportFrequency.entries.toList(),
                    labelForValue = ::frequencyLabel,
                    enabled = !isSending,
                    onValueChanged = {
                        if (frequency != it) {
                            frequency = it
                            resetChangedDraftState()
                        }
                    },
                )
                BugReportChoiceMenu(
                    label = stringResource(R.string.bug_report_connection),
                    contentDescription = stringResource(R.string.bug_report_connection_description),
                    value = connection,
                    values = BugReportConnection.entries.toList(),
                    labelForValue = ::connectionLabel,
                    enabled = !isSending,
                    onValueChanged = {
                        if (connection != it) {
                            connection = it
                            resetChangedDraftState()
                        }
                    },
                )
            }

            SettingsGroupCard(
                title = stringResource(R.string.bug_report_privacy_title),
                caption = stringResource(R.string.bug_report_privacy_caption),
            ) {
                Text(
                    stringResource(R.string.bug_report_privacy_disclosure),
                    style = chromeStyle(12f, FontWeight.Normal),
                    color = LiveDesign.text,
                )
                Text(
                    stringResource(R.string.bug_report_security_disclosure),
                    style = chromeStyle(12f, FontWeight.Normal),
                    color = LiveDesign.muted,
                )
                TextButton(
                    onClick = { securityActionUnavailable = !onOpenSecurityAdvisory() },
                    modifier = Modifier.semantics { contentDescription = openSecurityDescription },
                ) {
                    Text(stringResource(R.string.bug_report_security_advisory))
                }
                if (securityActionUnavailable) {
                    Text(
                        stringResource(R.string.system_action_unavailable),
                        style = chromeStyle(11.5f, FontWeight.Normal),
                        color = LiveDesign.accent,
                    )
                }
            }

            (result as? BugReportSubmissionResult.Failed)?.let { failure ->
                Text(
                    failureLabel(failure),
                    style = chromeStyle(12.5f, FontWeight.Medium),
                    color = LiveDesign.accent,
                    modifier = Modifier.fillMaxWidth().semantics {
                        contentDescription = submissionFailedDescription
                    },
                )
            }

            validation?.payload?.let { error ->
                Text(
                    when (error) {
                        BugReportPayloadError.TOO_LARGE ->
                            stringResource(R.string.bug_report_payload_too_large)
                    },
                    style = chromeStyle(12.5f, FontWeight.Medium),
                    color = LiveDesign.accent,
                    modifier = Modifier.fillMaxWidth(),
                )
            }

            Button(
                enabled = !isSending,
                onClick = {
                    val draft =
                        BugReportDraft(
                            summary = summary,
                            whatHappened = whatHappened,
                            stepsToReproduce = stepsToReproduce,
                            frequency = frequency,
                            connection = connection,
                        )
                    val nextValidation = draft.validation()
                    attemptedValidation = nextValidation
                    if (!nextValidation.isValid || isSending) return@Button
                    isSending = true
                    submission = null
                    val submissionToSend = BugReportSubmission(draft, idempotencyKey)
                    scope.launch {
                        when (val result = submitter.submit(submissionToSend)) {
                            is BugReportSubmissionResult.Invalid -> {
                                attemptedValidation = result.validation
                                submission = null
                            }
                            else -> submission = result
                        }
                        isSending = false
                    }
                },
                modifier =
                    Modifier.fillMaxWidth().semantics { contentDescription = sendDescription },
            ) {
                if (isSending) {
                    CircularProgressIndicator(
                        color = LiveDesign.background,
                        strokeWidth = 2.dp,
                        modifier = Modifier.padding(end = 8.dp),
                    )
                    Text(stringResource(R.string.bug_report_sending))
                } else {
                    Text(stringResource(R.string.bug_report_send))
                }
            }
            Spacer(Modifier.height(12.dp))
        }
        Box(Modifier.padding(start = 16.dp, top = 22.dp)) { PanelCloseButton(onClick = onClose) }
    }
}

@Composable
private fun BugReportSuccessScreen(onClose: () -> Unit) {
    val doneDescription = stringResource(R.string.bug_report_done_description)
    Box(
        Modifier.fillMaxSize()
            .background(LiveDesign.background)
            .windowInsetsPadding(WindowInsets.safeDrawing),
    ) {
        Column(
            Modifier.fillMaxSize().padding(24.dp),
            verticalArrangement = Arrangement.spacedBy(12.dp),
        ) {
            Text(
                stringResource(R.string.bug_report_sent_title),
                style = chromeStyle(26f, FontWeight.SemiBold),
                color = LiveDesign.text,
            )
            Text(
                stringResource(R.string.bug_report_sent_message),
                style = chromeStyle(13f, FontWeight.Normal),
                color = LiveDesign.muted,
            )
            Button(
                onClick = onClose,
                modifier = Modifier.semantics { contentDescription = doneDescription },
            ) {
                Text(stringResource(R.string.action_done))
            }
        }
        Box(Modifier.padding(start = 16.dp, top = 22.dp)) { PanelCloseButton(onClick = onClose) }
    }
}

@Composable
private fun BugReportTextField(
    value: String,
    onValueChange: (String) -> Unit,
    label: String,
    contentDescription: String,
    error: BugReportFieldError?,
    maximumLength: Int,
    singleLine: Boolean,
    minLines: Int,
    enabled: Boolean,
) {
    OutlinedTextField(
        value = value,
        onValueChange = onValueChange,
        label = { Text(label) },
        singleLine = singleLine,
        minLines = minLines,
        enabled = enabled,
        isError = error != null,
        supportingText = {
            Text(
                when (error) {
                    BugReportFieldError.REQUIRED -> stringResource(R.string.bug_report_required)
                    BugReportFieldError.TOO_LONG ->
                        stringResource(R.string.bug_report_too_long, maximumLength)
                    null -> stringResource(R.string.bug_report_character_count, value.length, maximumLength)
                },
            )
        },
        modifier =
            Modifier.fillMaxWidth().semantics {
                this.contentDescription = contentDescription
            },
    )
}

@Composable
private fun <T> BugReportChoiceMenu(
    label: String,
    contentDescription: String,
    value: T,
    values: List<T>,
    labelForValue: @Composable (T) -> String,
    enabled: Boolean,
    onValueChanged: (T) -> Unit,
) {
    var expanded by remember { mutableStateOf(false) }
    Column {
        Text(
            label,
            style = chromeStyle(12.5f, FontWeight.SemiBold),
            color = LiveDesign.text,
        )
        Box {
            TextButton(
                onClick = { expanded = true },
                enabled = enabled,
                modifier = Modifier.semantics { this.contentDescription = contentDescription },
            ) {
                Text(labelForValue(value))
            }
            DropdownMenu(expanded = expanded, onDismissRequest = { expanded = false }) {
                values.forEach { option ->
                    DropdownMenuItem(
                        text = { Text(labelForValue(option)) },
                        onClick = {
                            onValueChanged(option)
                            expanded = false
                        },
                    )
                }
            }
        }
    }
}

@Composable
private fun frequencyLabel(value: BugReportFrequency): String =
    stringResource(
        when (value) {
            BugReportFrequency.ALWAYS -> R.string.bug_report_frequency_always
            BugReportFrequency.SOMETIMES -> R.string.bug_report_frequency_sometimes
            BugReportFrequency.ONCE -> R.string.bug_report_frequency_once
            BugReportFrequency.UNKNOWN -> R.string.bug_report_frequency_unknown
        },
    )

@Composable
private fun connectionLabel(value: BugReportConnection): String =
    stringResource(
        when (value) {
            BugReportConnection.WIFI -> R.string.bug_report_connection_wifi
            BugReportConnection.USB -> R.string.bug_report_connection_usb
            BugReportConnection.UNKNOWN -> R.string.bug_report_connection_unknown
        },
    )

@Composable
private fun failureLabel(failure: BugReportSubmissionResult.Failed): String =
    when (failure.reason) {
        BugReportSubmissionFailure.RATE_LIMITED -> {
            val retryAfterSeconds = failure.retryAfterSeconds
            if (retryAfterSeconds == null) {
                stringResource(R.string.bug_report_rate_limited)
            } else {
                stringResource(
                    R.string.bug_report_rate_limited_with_retry,
                    (retryAfterSeconds + 59) / 60,
                )
            }
        }
        BugReportSubmissionFailure.CONFIGURATION -> stringResource(R.string.bug_report_unavailable)
        BugReportSubmissionFailure.NETWORK,
        BugReportSubmissionFailure.SERVICE,
        -> stringResource(R.string.bug_report_submission_failed)
    }
