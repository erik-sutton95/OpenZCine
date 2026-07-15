package com.opencapture.openzcine.wear

import android.graphics.Bitmap
import android.os.Build
import android.view.HapticFeedbackConstants
import androidx.compose.animation.animateColorAsState
import androidx.compose.animation.core.animateDpAsState
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.aspectRatio
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.draw.clipToBounds
import androidx.compose.ui.geometry.CornerRadius
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.hapticfeedback.HapticFeedbackType
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.platform.LocalConfiguration
import androidx.compose.ui.platform.LocalHapticFeedback
import androidx.compose.ui.platform.LocalView
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.role
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.wear.compose.material3.MaterialTheme
import androidx.wear.compose.material3.Text
import com.opencapture.openzcine.wearrelay.WatchConnectionState
import com.opencapture.openzcine.wearrelay.WatchRelayState
import com.opencapture.openzcine.wearrelay.WatchTimecode

/** Immutable UI input, separated from Data Layer ownership for UI testing. */
internal data class WearMonitorPresentation(
    val phoneReachable: Boolean,
    val state: WatchRelayState?,
    val frame: Bitmap?,
    val frameTimecode: WatchTimecode?,
    val isSendingCommand: Boolean,
    val commandMessage: String?,
) {
    val isRecording: Boolean
        get() = state?.isRecording == true

    val canRecord: Boolean
        get() =
            phoneReachable &&
                state?.connection == WatchConnectionState.CONNECTED &&
                !isSendingCommand
}

/** Geometry decisions that keep the fixed-height monitor legible on round and square watches. */
internal data class WearScreenLayout(
    val timecodeHorizontalPaddingDp: Float,
    val bottomHorizontalPaddingDp: Float,
    val timecodeFontSizeSp: Float,
)

internal fun wearScreenLayout(isRound: Boolean, widthDp: Float): WearScreenLayout {
    val timecodePadding = if (isRound) 16f else 6f
    val bottomPadding = if (isRound) 18f else 10f
    val availableTimecodeWidth = (widthDp - timecodePadding * 2f).coerceAtLeast(1f)
    return WearScreenLayout(
        timecodeHorizontalPaddingDp = timecodePadding,
        bottomHorizontalPaddingDp = bottomPadding,
        timecodeFontSizeSp = (availableTimecodeWidth / 6.8f).coerceIn(14f, 24f),
    )
}

internal fun fittedSingleLineFontSize(
    text: String,
    availableWidthDp: Float,
    maximumSizeSp: Float = 11f,
): Float {
    if (text.isEmpty()) return maximumSizeSp
    val estimated = availableWidthDp / (text.length * 0.57f)
    return estimated.coerceIn(8f, maximumSizeSp)
}

/** The 16:9 wrist monitor, rendered only from the phone relay's truthful state. */
@Composable
internal fun WearMonitorScreen(controller: WearRelayController) {
    WearMonitorContent(
        presentation =
            WearMonitorPresentation(
                phoneReachable = controller.phoneReachable,
                state = controller.state,
                frame = controller.frame,
                frameTimecode = controller.frameTimecode,
                isSendingCommand = controller.isSendingCommand,
                commandMessage = controller.commandMessage,
            ),
        onToggleRecord = controller::sendToggleRecord,
    )
}

/** Render-only Wear monitor surface used by both the Activity and Compose UI tests. */
@Composable
internal fun WearMonitorContent(
    presentation: WearMonitorPresentation,
    onToggleRecord: () -> Unit,
) {
    val view = LocalView.current
    var previousRecording by remember { mutableStateOf<Boolean?>(null) }
    var previousCommandMessage by remember { mutableStateOf(presentation.commandMessage) }
    LaunchedEffect(presentation.isRecording) {
        if (previousRecording != null && previousRecording != presentation.isRecording) {
            val feedback =
                if (Build.VERSION.SDK_INT >= 30) {
                    if (presentation.isRecording) {
                        HapticFeedbackConstants.CONFIRM
                    } else {
                        HapticFeedbackConstants.REJECT
                    }
                } else {
                    HapticFeedbackConstants.LONG_PRESS
                }
            view.performHapticFeedback(feedback)
        }
        previousRecording = presentation.isRecording
    }
    LaunchedEffect(presentation.commandMessage) {
        val message = presentation.commandMessage
        if (message != null && message != previousCommandMessage) {
            val feedback =
                if (Build.VERSION.SDK_INT >= 30) {
                    HapticFeedbackConstants.REJECT
                } else {
                    HapticFeedbackConstants.LONG_PRESS
                }
            view.performHapticFeedback(feedback)
        }
        previousCommandMessage = message
    }
    MaterialTheme {
        val monitorDescription = stringResource(R.string.wear_monitor_description)
        BoxWithConstraints(
            modifier =
                Modifier.fillMaxSize()
                    .background(Color.Black)
                    .semantics { contentDescription = monitorDescription },
        ) {
            val layout = wearScreenLayout(LocalConfiguration.current.isScreenRound, maxWidth.value)
            val sideSlotWidth =
                ((maxWidth.value - layout.bottomHorizontalPaddingDp * 2f - 50f) / 2f)
                    .coerceAtLeast(1f)
            val storage = storageLabel(presentation)
            val batteryPercent =
                presentation.state?.let { state ->
                    state.cameraBatteryPercent.takeIf {
                        state.connection == WatchConnectionState.CONNECTED && it in 0..100
                    }
                }
            Column(
                modifier =
                    Modifier.fillMaxSize(),
                verticalArrangement = Arrangement.spacedBy(2.dp),
            ) {
                Text(
                    text = timecodeLabel(presentation),
                    modifier =
                        Modifier.fillMaxWidth()
                            .padding(horizontal = layout.timecodeHorizontalPaddingDp.dp),
                    color = if (presentation.isRecording) Color(0xFFE24040) else Color.White,
                    fontFamily = FontFamily.Monospace,
                    fontWeight = FontWeight.SemiBold,
                    fontSize = layout.timecodeFontSizeSp.sp,
                    textAlign = TextAlign.Center,
                    maxLines = 1,
                )
                WearFeed(
                    presentation = presentation,
                    modifier = Modifier.fillMaxWidth().weight(1f, fill = false),
                )
                Row(
                    modifier =
                        Modifier.fillMaxWidth()
                            .padding(horizontal = layout.bottomHorizontalPaddingDp.dp)
                            .padding(bottom = 6.dp),
                    verticalAlignment = Alignment.CenterVertically,
                ) {
                    Text(
                        text = storage,
                        modifier = Modifier.weight(1f),
                        color = Color(0xFFC3C5C8),
                        fontSize = fittedSingleLineFontSize(storage, sideSlotWidth).sp,
                        maxLines = 1,
                        softWrap = false,
                    )
                    WearRecordButton(
                        isRecording = presentation.isRecording,
                        enabled = presentation.canRecord,
                        onClick = onToggleRecord,
                    )
                    Spacer(Modifier.width(6.dp))
                    WearBatteryReadout(
                        percent = batteryPercent,
                        modifier = Modifier.weight(1f),
                    )
                }
            }
        }
    }
}

@Composable
private fun WearFeed(presentation: WearMonitorPresentation, modifier: Modifier = Modifier) {
    val livePreviewDescription = stringResource(R.string.wear_live_preview_description)
    Box(
        modifier =
            modifier
                .aspectRatio(16f / 9f)
                .background(Color(0xFF101114))
                .clipToBounds()
                .then(
                    if (presentation.isRecording) {
                        Modifier.border(3.dp, Color(0xFFE24040))
                    } else {
                        Modifier
                    },
                ),
        contentAlignment = Alignment.Center,
    ) {
        presentation.frame?.let { preview ->
            Image(
                bitmap = preview.asImageBitmap(),
                contentDescription = livePreviewDescription,
                modifier = Modifier.fillMaxSize(),
                contentScale = ContentScale.Crop,
            )
        }
        val placeholder = placeholderLabel(presentation)
        if (placeholder != null) {
            Text(
                text = placeholder,
                color = Color.White,
                fontSize = 11.sp,
                textAlign = TextAlign.Center,
                modifier =
                    Modifier.padding(6.dp)
                        .background(Color.Black.copy(alpha = 0.55f), RoundedCornerShape(6.dp))
                        .padding(6.dp),
                maxLines = 2,
            )
        }
        presentation.commandMessage?.let { message ->
            Text(
                text = message,
                modifier =
                    Modifier.align(Alignment.BottomCenter)
                        .padding(horizontal = 8.dp, vertical = 3.dp)
                        .background(Color.Black.copy(alpha = 0.7f), RoundedCornerShape(4.dp))
                        .padding(horizontal = 4.dp, vertical = 2.dp),
                color = Color(0xFFE5B567),
                fontSize = 8.sp,
                textAlign = TextAlign.Center,
                maxLines = 2,
            )
        }
    }
}

@Composable
private fun placeholderLabel(presentation: WearMonitorPresentation): String? =
    when {
        !presentation.phoneReachable -> stringResource(R.string.wear_open_on_phone)
        presentation.state == null -> stringResource(R.string.wear_waiting_for_phone)
        presentation.state.connection == WatchConnectionState.DISCONNECTED ->
            stringResource(R.string.wear_phone_unavailable)
        presentation.state.connection == WatchConnectionState.NO_CAMERA ->
            stringResource(R.string.wear_no_camera)
        !presentation.state.feedLive -> stringResource(R.string.wear_feed_paused)
        presentation.frame == null -> stringResource(R.string.wear_waiting_for_preview)
        else -> null
    }

@Composable
private fun timecodeLabel(presentation: WearMonitorPresentation): String {
    val timecode = presentation.frameTimecode ?: presentation.state?.timecode
    return if (timecode?.on == true) {
        timecode.label()
    } else {
        stringResource(R.string.wear_timecode_unavailable)
    }
}

@Composable
private fun storageLabel(presentation: WearMonitorPresentation): String =
    presentation.state?.mediaStatus?.let { status ->
        stringResource(
            R.string.wear_storage_capacity,
            status.gigabytesFree,
            status.percentFree,
        )
    }
        ?: presentation.state?.media?.takeIf { it.isNotBlank() }
        ?: stringResource(R.string.wear_unavailable)

/** iOS-parity record glyph: circle + rounded red start/stop tally, not a text control. */
@Composable
private fun WearRecordButton(
    isRecording: Boolean,
    enabled: Boolean,
    onClick: () -> Unit,
) {
    val hapticFeedback = LocalHapticFeedback.current
    val recordDescription =
        stringResource(
            if (isRecording) {
                R.string.wear_stop_recording_description
            } else {
                R.string.wear_start_recording_description
            },
        )
    val controlColor by
        animateColorAsState(
            if (isRecording) Color(0xFFE24040) else Color.White.copy(alpha = 0.6f),
            label = "record ring",
        )
    val innerSize by
        animateDpAsState(if (isRecording) 14.dp else 22.dp, label = "record glyph size")
    val innerCorner by
        animateDpAsState(if (isRecording) 3.dp else 11.dp, label = "record glyph corner")
    Box(
        modifier =
            Modifier.size(44.dp)
                .alpha(if (enabled) 1f else 0.4f)
                .semantics {
                    contentDescription = recordDescription
                    role = Role.Button
                }
                .clickable(enabled = enabled) {
                    hapticFeedback.performHapticFeedback(HapticFeedbackType.LongPress)
                    onClick()
                },
        contentAlignment = Alignment.Center,
    ) {
        Box(
            modifier =
                Modifier.size(34.dp)
                    .border(3.dp, controlColor, CircleShape),
        )
        Box(
            modifier =
                Modifier.size(innerSize)
                    .background(Color(0xFFE24040), RoundedCornerShape(innerCorner)),
        )
    }
}

/** Compact battery glyph and honest camera charge readout. */
@Composable
private fun WearBatteryReadout(percent: Int?, modifier: Modifier = Modifier) {
    val batteryLabel =
        percent?.let { stringResource(R.string.wear_battery_percent, it) }
            ?: stringResource(R.string.wear_unavailable)
    Row(
        modifier = modifier,
        horizontalArrangement = Arrangement.End,
        verticalAlignment = Alignment.CenterVertically,
    ) {
        if (percent != null) {
            WearBatteryGlyph(percent)
            Spacer(Modifier.width(3.dp))
        }
        Text(
            text = batteryLabel,
            color = Color(0xFFC3C5C8),
            fontSize = 11.sp,
            maxLines = 1,
            textAlign = TextAlign.End,
        )
    }
}

@Composable
private fun WearBatteryGlyph(percent: Int) {
    Canvas(Modifier.size(width = 16.dp, height = 10.dp)) {
        val stroke = 1.dp.toPx()
        val bodyWidth = size.width - 3.dp.toPx()
        val bodyHeight = size.height
        val color = Color(0xFFC3C5C8)
        drawRoundRect(
            color = color,
            size = Size(bodyWidth, bodyHeight),
            cornerRadius = CornerRadius(2.dp.toPx()),
            style = Stroke(stroke),
        )
        drawRect(
            color = color,
            topLeft = Offset(bodyWidth, bodyHeight * 0.3f),
            size = Size(3.dp.toPx(), bodyHeight * 0.4f),
        )
        val fillWidth = (bodyWidth - stroke * 2).coerceAtLeast(0f) * (percent / 100f)
        drawRoundRect(
            color = color,
            topLeft = Offset(stroke, stroke),
            size = Size(fillWidth, (bodyHeight - stroke * 2).coerceAtLeast(0f)),
            cornerRadius = CornerRadius(1.dp.toPx()),
        )
    }
}
