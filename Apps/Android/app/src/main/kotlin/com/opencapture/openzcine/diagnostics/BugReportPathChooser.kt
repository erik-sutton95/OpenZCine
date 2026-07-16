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
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.safeDrawing
import androidx.compose.foundation.layout.windowInsetsPadding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.Button
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import com.opencapture.openzcine.LiveDesign
import com.opencapture.openzcine.R
import com.opencapture.openzcine.chromeStyle
import com.opencapture.openzcine.settings.PanelCloseButton
import com.opencapture.openzcine.settings.SettingsGroupCard

/**
 * Lets a person choose between the minimal account-free form and GitHub's
 * signed-in issue form. Both paths intentionally create public GitHub issues.
 */
@Composable
internal fun BugReportPathChooser(
    onChooseAnonymous: () -> Unit,
    onContinueWithGitHub: () -> Boolean,
    onClose: () -> Unit,
) {
    var githubActionUnavailable by remember { mutableStateOf(false) }
    val anonymousDescription = stringResource(R.string.bug_report_path_anonymous_description)
    val githubDescription = stringResource(R.string.bug_report_path_github_description)

    Box(
        Modifier.fillMaxSize()
            .background(LiveDesign.background)
            .windowInsetsPadding(WindowInsets.safeDrawing),
    ) {
        Column(
            Modifier.fillMaxSize()
                .verticalScroll(rememberScrollState())
                // The close button occupies the first 37dp plus an 8dp gap.
                .padding(start = 61.dp, top = 14.dp, end = 16.dp, bottom = 14.dp),
            verticalArrangement = Arrangement.spacedBy(12.dp),
        ) {
            Column(verticalArrangement = Arrangement.spacedBy(4.dp)) {
                Text(
                    stringResource(R.string.bug_report_title),
                    style = chromeStyle(24f, FontWeight.SemiBold),
                    color = LiveDesign.text,
                )
                Text(
                    stringResource(R.string.bug_report_path_subtitle),
                    style = chromeStyle(12.5f, FontWeight.Normal),
                    color = LiveDesign.muted,
                )
            }

            Text(
                stringResource(R.string.bug_report_path_public_notice),
                style = chromeStyle(12f, FontWeight.Normal),
                color = LiveDesign.text,
            )

            SettingsGroupCard(
                title = stringResource(R.string.bug_report_path_anonymous_title),
                caption = stringResource(R.string.bug_report_path_anonymous_caption),
                captionMaxLines = Int.MAX_VALUE,
            ) {
                Button(
                    onClick = onChooseAnonymous,
                    modifier =
                        Modifier.fillMaxWidth().heightIn(min = 48.dp).semantics {
                            contentDescription = anonymousDescription
                        },
                ) {
                    Text(stringResource(R.string.bug_report_path_anonymous_action))
                }
            }

            SettingsGroupCard(
                title = stringResource(R.string.bug_report_path_github_title),
                caption = stringResource(R.string.bug_report_path_github_caption),
                captionMaxLines = Int.MAX_VALUE,
            ) {
                Button(
                    onClick = {
                        githubActionUnavailable = !onContinueWithGitHub()
                        if (!githubActionUnavailable) onClose()
                    },
                    modifier =
                        Modifier.fillMaxWidth().heightIn(min = 48.dp).semantics {
                            contentDescription = githubDescription
                        },
                ) {
                    Text(stringResource(R.string.bug_report_path_github_action))
                }
                if (githubActionUnavailable) {
                    Text(
                        stringResource(R.string.system_action_unavailable),
                        style = chromeStyle(11.5f, FontWeight.Normal),
                        color = LiveDesign.accent,
                    )
                }
            }

            Spacer(Modifier.height(12.dp))
        }
        Box(Modifier.padding(start = 16.dp, top = 22.dp)) { PanelCloseButton(onClick = onClose) }
    }
}
