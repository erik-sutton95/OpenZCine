package com.opencapture.openzcine

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.defaultMinSize
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.res.pluralStringResource
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp

/**
 * Recovery affordance over a **held** live-view frame after an established
 * session dropped — the Compose twin of iOS `MonitorRecoveryOverlay`.
 *
 * A knocked cable or a camera power cycle must not throw a shoot back to the
 * connect screen, so the operator stays in the monitor. The frame behind this
 * is the last one received, not live, so it is dimmed and the copy says so.
 * Two ways out: retry here, or leave for the operator menu.
 */
@Composable
internal fun MonitorRecoveryOverlay(
    state: MonitorRecoveryState,
    cameraName: String,
    onRetry: () -> Unit,
    onBackToOperatorMenu: () -> Unit,
    modifier: Modifier = Modifier,
) {
    if (state is MonitorRecoveryState.Idle) return
    val camera = cameraName.trim().ifBlank { stringResource(R.string.recovery_generic_camera) }
    val title =
        when (state) {
            is MonitorRecoveryState.Retrying -> stringResource(R.string.recovery_retrying_title)
            else -> stringResource(R.string.recovery_lost_title)
        }
    val detail =
        when (state) {
            is MonitorRecoveryState.Retrying ->
                stringResource(
                    R.string.recovery_retrying_detail,
                    camera,
                    state.attempt,
                    state.maxAttempts,
                )
            is MonitorRecoveryState.WaitingForOperator ->
                stringResource(
                    R.string.recovery_lost_detail,
                    camera,
                    pluralStringResource(
                        R.plurals.recovery_lost_tries,
                        state.attemptsMade,
                        state.attemptsMade,
                    ),
                )
            MonitorRecoveryState.Idle -> ""
        }

    Box(
        modifier = modifier.fillMaxSize().background(Color.Black.copy(alpha = 0.34f)),
        contentAlignment = Alignment.Center,
    ) {
        Column(
            modifier =
                Modifier.widthIn(max = 460.dp)
                    .padding(horizontal = 24.dp)
                    .background(
                        LiveDesign.glassOpaque,
                        RoundedCornerShape(LiveDesign.CORNER_RADIUS_DP.dp),
                    )
                    .border(
                        1.dp,
                        LiveDesign.hairlineStrong,
                        RoundedCornerShape(LiveDesign.CORNER_RADIUS_DP.dp),
                    )
                    .padding(horizontal = 18.dp, vertical = 16.dp),
            verticalArrangement = Arrangement.spacedBy(12.dp),
        ) {
            Row(
                horizontalArrangement = Arrangement.spacedBy(12.dp),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                if (state is MonitorRecoveryState.Retrying) {
                    CircularProgressIndicator(
                        color = LiveDesign.accent,
                        strokeWidth = 2.dp,
                        modifier = Modifier.size(20.dp),
                    )
                }
                Column(verticalArrangement = Arrangement.spacedBy(3.dp)) {
                    Text(
                        text = title,
                        style = chromeStyle(16f, FontWeight.SemiBold),
                        color = LiveDesign.text,
                    )
                    Text(
                        text = detail,
                        style = chromeStyle(12f, FontWeight.Medium),
                        color = LiveDesign.muted,
                    )
                }
            }
            Row(
                modifier = Modifier.fillMaxWidth(),
                horizontalArrangement = Arrangement.spacedBy(10.dp),
            ) {
                RecoveryAction(
                    label = stringResource(R.string.recovery_retry),
                    container = LiveDesign.accent,
                    content = Color.Black,
                    onClick = onRetry,
                    modifier = Modifier.weight(1f),
                )
                RecoveryAction(
                    label = stringResource(R.string.recovery_operator_menu),
                    container = LiveDesign.glassBright,
                    content = LiveDesign.text,
                    onClick = onBackToOperatorMenu,
                    modifier = Modifier.weight(1f),
                )
            }
        }
    }
}

/** Pill action sized to the platform 48dp minimum touch target. */
@Composable
private fun RecoveryAction(
    label: String,
    container: Color,
    content: Color,
    onClick: () -> Unit,
    modifier: Modifier = Modifier,
) {
    Button(
        onClick = onClick,
        colors = ButtonDefaults.buttonColors(containerColor = container, contentColor = content),
        modifier = modifier.defaultMinSize(minHeight = 48.dp),
    ) {
        Text(
            text = label,
            style = chromeStyle(13f, FontWeight.SemiBold),
            color = content,
            maxLines = 1,
            textAlign = TextAlign.Center,
        )
    }
}
