package com.opencapture.openzcine.wear

import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
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
import androidx.compose.ui.layout.ContentScale
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

/** The 16:9 wrist monitor, rendered only from the phone relay's truthful state. */
@Composable
internal fun WearMonitorScreen(controller: WearRelayController) {
    val state = controller.state
    val isRecording = state?.isRecording == true
    val canRecord =
        controller.phoneReachable &&
            state != null &&
            state.connection == WatchConnectionState.CONNECTED &&
            state.feedLive &&
            !controller.isSendingCommand
    MaterialTheme {
        Column(
            modifier =
                Modifier.fillMaxSize()
                    .background(Color.Black),
            verticalArrangement = Arrangement.spacedBy(2.dp),
        ) {
            Text(
                text = timecodeLabel(controller),
                modifier = Modifier.fillMaxWidth().padding(horizontal = 6.dp),
                color = if (isRecording) Color(0xFFE24040) else Color.White,
                fontFamily = FontFamily.Monospace,
                fontWeight = FontWeight.SemiBold,
                fontSize = 24.sp,
                textAlign = TextAlign.Center,
                maxLines = 1,
            )
            WearFeed(
                controller = controller,
                modifier = Modifier.fillMaxWidth().weight(1f, fill = false),
            )
            Row(
                modifier =
                    Modifier.fillMaxWidth()
                        .padding(horizontal = 10.dp, vertical = 0.dp)
                        .padding(bottom = 6.dp),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                Text(
                    text = storageLabel(controller),
                    modifier = Modifier.weight(1f),
                    color = Color(0xFFC3C5C8),
                    fontSize = 11.sp,
                    maxLines = 1,
                )
                WearRecordButton(
                    isRecording = isRecording,
                    enabled = canRecord,
                    onClick = controller::sendToggleRecord,
                )
                Spacer(Modifier.width(6.dp))
                WearBatteryReadout(
                    percent = controller.state?.cameraBatteryPercent?.takeIf { it in 1..100 },
                    modifier = Modifier.weight(1f),
                )
            }
            controller.commandMessage?.let { message ->
                Text(
                    text = message,
                    modifier = Modifier.fillMaxWidth(),
                    color = Color(0xFFE5B567),
                    fontSize = 9.sp,
                    textAlign = TextAlign.Center,
                    maxLines = 2,
                )
            }
        }
    }
}

@Composable
private fun WearFeed(controller: WearRelayController, modifier: Modifier = Modifier) {
    val state = controller.state
    val recording = state?.isRecording == true
    Box(
        modifier =
            modifier
                .aspectRatio(16f / 9f)
                .background(Color(0xFF101114))
                .clipToBounds()
                .then(
                    if (recording) {
                        Modifier.border(3.dp, Color(0xFFE24040))
                    } else {
                        Modifier
                    },
                ),
        contentAlignment = Alignment.Center,
    ) {
        controller.frame?.let { preview ->
            Image(
                bitmap = preview.asImageBitmap(),
                contentDescription = "Live camera preview from phone",
                modifier = Modifier.fillMaxSize(),
                contentScale = ContentScale.Crop,
            )
        }
        val placeholder = placeholderLabel(controller)
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
    }
}

private fun placeholderLabel(controller: WearRelayController): String? =
    when {
        !controller.phoneReachable -> "Open OpenZCine on phone"
        controller.state == null -> "Waiting for phone monitor"
        controller.state?.connection == WatchConnectionState.DISCONNECTED -> "Phone monitor unavailable"
        controller.state?.connection == WatchConnectionState.NO_CAMERA -> "No camera connected"
        controller.state?.feedLive == false -> "Feed paused on phone"
        controller.frame == null -> "Waiting for camera preview"
        else -> null
    }

private fun timecodeLabel(controller: WearRelayController): String {
    val timecode = controller.frameTimecode ?: controller.state?.timecode
    return if (timecode?.on == true) timecode.label() else "--:--:--:--"
}

private fun storageLabel(controller: WearRelayController): String =
    controller.state?.mediaStatus?.capacityLabel()
        ?: controller.state?.media?.takeIf { it.isNotBlank() }
        ?: "—"

/** iOS-parity record glyph: circle + rounded red start/stop tally, not a text control. */
@Composable
private fun WearRecordButton(
    isRecording: Boolean,
    enabled: Boolean,
    onClick: () -> Unit,
) {
    val controlColor = if (isRecording) Color(0xFFE24040) else Color.White.copy(alpha = 0.6f)
    val innerSize = if (isRecording) 14.dp else 22.dp
    val innerShape = RoundedCornerShape(if (isRecording) 3.dp else 11.dp)
    Box(
        modifier =
            Modifier.size(44.dp)
                .alpha(if (enabled) 1f else 0.4f)
                .semantics {
                    contentDescription =
                        if (isRecording) "Stop camera recording" else "Start camera recording"
                    role = Role.Button
                }
                .clickable(enabled = enabled, onClick = onClick),
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
                    .background(Color(0xFFE24040), innerShape),
        )
    }
}

/** Compact battery glyph and honest camera charge readout. */
@Composable
private fun WearBatteryReadout(percent: Int?, modifier: Modifier = Modifier) {
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
            text = percent?.let { "$it%" } ?: "—",
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
