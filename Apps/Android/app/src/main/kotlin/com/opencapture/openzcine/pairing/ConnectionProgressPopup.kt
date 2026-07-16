package com.opencapture.openzcine.pairing

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.remember
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.shadow
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.opencapture.openzcine.R

/**
 * The single shared connect-progress card — Android port of iOS
 * `ConnectionProgressSheet` (ios/Runner/ConnectionProgressSheet.swift). Every
 * connect flow (scanned-AP join, first pairing, saved reconnect, USB) renders
 * its phases through this centered light card over a dimmed startup screen;
 * the deliberate light-on-dark contrast matches the iOS design.
 */
public sealed interface ConnectionPopupPhase {
    /** Credentials staged; waiting for the operator to confirm the join. */
    public data class ReadyToJoin(val key: String?, val keyFromScan: Boolean) :
        ConnectionPopupPhase

    public data object JoiningWifi : ConnectionPopupPhase

    public data object Searching : ConnectionPopupPhase

    public data object Handshaking : ConnectionPopupPhase

    public data object Pairing : ConnectionPopupPhase

    public data class ConfirmOnCamera(val pin: String?) : ConnectionPopupPhase

    public data object Reconnecting : ConnectionPopupPhase

    public data class Failed(val message: String?) : ConnectionPopupPhase
}

/**
 * Operator-friendly device title: the raw SSID/camera name as iOS renders it,
 * falling back to the generic body-agnostic name when nothing is known.
 */
public fun connectionDisplayName(raw: String?): String =
    raw?.trim().orEmpty().ifEmpty { "Nikon camera" }

internal object PopupColors {
    val card = Color.White
    val title = Color(0xFF111111)
    val detail = Color(0xFF7A7A80)
    val field = Color(0xFFF2F2F7)
    val actionBlue = Color(0xFF0A7AFF)
    val cancelFill = Color(0xFFEDEDF0)
    val success = Color(0xFF34C759)
    val failure = Color(0xFFFF3B30)
    val scrim = Color.Black.copy(alpha = 0.45f)
}

@Composable
public fun ConnectionProgressPopup(
    deviceName: String,
    phase: ConnectionPopupPhase,
    onConnect: () -> Unit,
    onDismiss: () -> Unit,
) {
    val failed = phase is ConnectionPopupPhase.Failed
    Box(
        Modifier.fillMaxSize()
            .background(PopupColors.scrim)
            // Swallows taps; dismissal is button-only unless failed (iOS
            // interactiveDismissDisabled).
            .clickable(
                interactionSource = remember { MutableInteractionSource() },
                indication = null,
            ) {
                if (failed) onDismiss()
            },
        contentAlignment = Alignment.Center,
    ) {
        Column(
            Modifier.padding(24.dp)
                .widthIn(max = 360.dp)
                .shadow(24.dp, RoundedCornerShape(24.dp))
                .clip(RoundedCornerShape(24.dp))
                .background(PopupColors.card)
                .clickable(
                    interactionSource = remember { MutableInteractionSource() },
                    indication = null,
                ) {}
                .padding(horizontal = 24.dp, vertical = 22.dp),
            horizontalAlignment = Alignment.CenterHorizontally,
            verticalArrangement = Arrangement.spacedBy(12.dp),
        ) {
            Text(
                deviceName,
                color = PopupColors.title,
                fontSize = 20.sp,
                fontWeight = FontWeight.Bold,
                textAlign = TextAlign.Center,
                maxLines = 2,
            )
            Text(
                popupDetail(deviceName, phase),
                color = PopupColors.detail,
                fontSize = 15.sp,
                lineHeight = 20.sp,
                textAlign = TextAlign.Center,
            )
            when (phase) {
                is ConnectionPopupPhase.ReadyToJoin -> {
                    if (phase.key != null && phase.keyFromScan) {
                        Text(
                            phase.key,
                            color = PopupColors.title,
                            fontSize = 17.sp,
                            fontFamily = FontFamily.Monospace,
                            textAlign = TextAlign.Center,
                            modifier =
                                Modifier.fillMaxWidth()
                                    .clip(RoundedCornerShape(12.dp))
                                    .background(PopupColors.field)
                                    .padding(horizontal = 14.dp, vertical = 12.dp),
                        )
                        Text(
                            stringResource(R.string.conn_scanned_caption),
                            color = PopupColors.detail,
                            fontSize = 13.sp,
                            textAlign = TextAlign.Center,
                        )
                    }
                    PopupFilledButton(stringResource(R.string.action_connect), onConnect)
                    PopupCancelButton(stringResource(R.string.action_cancel), onDismiss)
                }
                is ConnectionPopupPhase.Failed -> {
                    PopupStatusRow(
                        label = stringResource(R.string.conn_failed_title),
                        badge = { PopupBadge(PopupColors.failure, "!") },
                    )
                    PopupCancelButton(stringResource(R.string.action_close), onDismiss)
                }
                else -> {
                    PopupStatusRow(
                        label = popupStatusTitle(phase),
                        badge = {
                            CircularProgressIndicator(
                                color = PopupColors.detail,
                                strokeWidth = 2.dp,
                                modifier = Modifier.size(18.dp),
                            )
                        },
                    )
                    PopupCancelButton(stringResource(R.string.action_cancel), onDismiss)
                }
            }
        }
    }
}

@Composable
private fun popupStatusTitle(phase: ConnectionPopupPhase): String =
    when (phase) {
        is ConnectionPopupPhase.ReadyToJoin,
        is ConnectionPopupPhase.Failed,
        -> ""
        ConnectionPopupPhase.JoiningWifi,
        ConnectionPopupPhase.Handshaking,
        ConnectionPopupPhase.Reconnecting,
        -> stringResource(R.string.conn_connecting_title)
        ConnectionPopupPhase.Searching -> stringResource(R.string.conn_searching_title)
        ConnectionPopupPhase.Pairing -> stringResource(R.string.conn_pairing_title)
        is ConnectionPopupPhase.ConfirmOnCamera -> stringResource(R.string.conn_confirm_title)
    }

@Composable
private fun popupDetail(deviceName: String, phase: ConnectionPopupPhase): String =
    when (phase) {
        is ConnectionPopupPhase.ReadyToJoin ->
            stringResource(R.string.conn_ready_detail, deviceName)
        ConnectionPopupPhase.JoiningWifi -> stringResource(R.string.conn_joining_detail)
        ConnectionPopupPhase.Searching ->
            stringResource(R.string.conn_searching_detail, deviceName)
        ConnectionPopupPhase.Handshaking ->
            stringResource(R.string.conn_handshaking_detail, deviceName)
        ConnectionPopupPhase.Pairing -> stringResource(R.string.conn_pairing_detail, deviceName)
        is ConnectionPopupPhase.ConfirmOnCamera ->
            if (phase.pin == null) {
                stringResource(R.string.conn_confirm_detail, deviceName)
            } else {
                stringResource(R.string.conn_confirm_detail_pin, phase.pin, deviceName)
            }
        ConnectionPopupPhase.Reconnecting ->
            stringResource(R.string.conn_reconnecting_detail, deviceName)
        is ConnectionPopupPhase.Failed ->
            phase.message ?: stringResource(R.string.conn_failed_detail)
    }

@Composable
private fun PopupStatusRow(label: String, badge: @Composable () -> Unit) {
    Row(
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(9.dp),
    ) {
        badge()
        Text(
            label,
            color = PopupColors.title,
            fontSize = 17.sp,
            fontWeight = FontWeight.Medium,
        )
    }
}

@Composable
private fun PopupBadge(color: Color, glyph: String) {
    Box(
        Modifier.size(22.dp).background(color, CircleShape),
        contentAlignment = Alignment.Center,
    ) {
        Text(glyph, color = Color.White, fontSize = 14.sp, fontWeight = FontWeight.Bold)
    }
}

@Composable
internal fun PopupFilledButton(text: String, onClick: () -> Unit) {
    Box(
        Modifier.fillMaxWidth()
            .height(50.dp)
            .clip(RoundedCornerShape(14.dp))
            .background(PopupColors.actionBlue)
            .clickable(onClick = onClick),
        contentAlignment = Alignment.Center,
    ) {
        Text(text, color = Color.White, fontSize = 17.sp, fontWeight = FontWeight.SemiBold)
    }
}

@Composable
internal fun PopupCancelButton(text: String, onClick: () -> Unit) {
    Box(
        Modifier.fillMaxWidth()
            .height(50.dp)
            .clip(RoundedCornerShape(14.dp))
            .background(PopupColors.cancelFill)
            .clickable(onClick = onClick),
        contentAlignment = Alignment.Center,
    ) {
        Text(text, color = PopupColors.actionBlue, fontSize = 17.sp, fontWeight = FontWeight.SemiBold)
    }
}
