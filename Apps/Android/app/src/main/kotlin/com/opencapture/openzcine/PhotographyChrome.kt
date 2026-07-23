package com.opencapture.openzcine

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.opencapture.openzcine.core.CameraPropertySnapshot
import com.opencapture.openzcine.pairing.StartupColors

/**
 * Compact photography capture strip when the body reports photo mode.
 *
 * Single row matching cinema capture height. The system-rail shutter replaces
 * the red record button; this strip is exposure/drive readouts only.
 */
@Composable
internal fun PhotographyCaptureStrip(
    properties: CameraPropertySnapshot,
    onSelectDrive: () -> Unit,
    onSelectMode: () -> Unit,
    onSelectIso: () -> Unit,
    onSelectShutter: () -> Unit,
    onSelectIris: () -> Unit,
    onSelectMetering: () -> Unit,
    onSelectFlash: () -> Unit,
    onSelectQuality: () -> Unit,
    onSelectFocus: () -> Unit,
    onInstantPlayback: () -> Unit,
    modifier: Modifier = Modifier,
) {
    Row(
        modifier
            .clip(RoundedCornerShape(18.dp))
            .background(StartupColors.control.copy(alpha = 0.55f))
            .padding(horizontal = 10.dp, vertical = 4.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(6.dp),
    ) {
        PhotographyModeBadge()
        PhotographyTile("ISO", properties.iso?.toString() ?: "—", onSelectIso)
        PhotographyTile("SHUTTER", properties.shutterSpeed ?: "—", onSelectShutter)
        PhotographyTile("IRIS", properties.iris ?: "—", onSelectIris)
        PhotographyTile("MODE", properties.exposureMode ?: "—", onSelectMode)
        PhotographyTile("DRIVE", properties.stillCaptureMode ?: "Single", onSelectDrive)
        PhotographyTile("FOCUS", properties.focusMode ?: "—", onSelectFocus)
        PhotographyTile(
            "QUAL",
            properties.compression ?: properties.imageSize ?: "—",
            onSelectQuality,
        )
        PhotographyTile("FLASH", properties.flashMode ?: "—", onSelectFlash)
        PhotographyTile("METER", properties.meteringMode ?: "—", onSelectMetering)
        Box(
            Modifier
                .size(36.dp)
                .clip(CircleShape)
                .background(StartupColors.control.copy(alpha = 0.75f))
                .clickable(onClick = onInstantPlayback)
                .semantics { contentDescription = "Instant playback" },
            contentAlignment = Alignment.Center,
        ) {
            Text("IMG", color = StartupColors.ink, fontSize = 10.sp, fontWeight = FontWeight.Bold)
        }
    }
}

/** System-rail still shutter (replaces the red record control in photography mode). */
@Composable
internal fun PhotographyShutterButton(
    isCapturing: Boolean,
    onClick: () -> Unit,
    modifier: Modifier = Modifier,
    enabled: Boolean = true,
) {
    Box(
        modifier
            .size(54.dp)
            .clip(CircleShape)
            .border(3.dp, Color.White.copy(alpha = 0.92f), CircleShape)
            .clickable(enabled = enabled && !isCapturing, onClick = onClick)
            .semantics {
                contentDescription = if (isCapturing) "Capturing" else "Shutter"
            },
        contentAlignment = Alignment.Center,
    ) {
        Box(
            Modifier
                .size(42.dp)
                .clip(CircleShape)
                .background(if (isCapturing) Color.White.copy(alpha = 0.5f) else Color.White),
        )
    }
}

@Composable
internal fun PhotographyModeBadge(modifier: Modifier = Modifier) {
    Text(
        "PHOTO",
        modifier =
            modifier
                .clip(RoundedCornerShape(50))
                .background(StartupColors.accent.copy(alpha = 0.9f))
                .padding(horizontal = 7.dp, vertical = 5.dp)
                .semantics { contentDescription = "Photography mode" },
        color = StartupColors.ink,
        fontSize = 9.sp,
        fontWeight = FontWeight.Bold,
        letterSpacing = 1.sp,
    )
}

/** Whether the shell should show photography chrome for this snapshot. */
internal fun prefersPhotographyChrome(properties: CameraPropertySnapshot): Boolean =
    properties.captureSelector.equals("photo", ignoreCase = true)

@Composable
private fun PhotographyTile(
    title: String,
    value: String,
    onClick: () -> Unit,
) {
    Column(
        Modifier
            .clip(RoundedCornerShape(10.dp))
            .background(StartupColors.control.copy(alpha = 0.82f))
            .clickable(onClick = onClick)
            .padding(horizontal = 7.dp, vertical = 4.dp)
            .semantics { contentDescription = "$title $value" },
    ) {
        Text(
            title,
            color = StartupColors.muted,
            fontSize = 8.sp,
            fontWeight = FontWeight.SemiBold,
            letterSpacing = 0.5.sp,
        )
        Spacer(Modifier.height(1.dp))
        Text(
            value,
            color = StartupColors.ink,
            fontSize = 12.sp,
            fontWeight = FontWeight.SemiBold,
            maxLines = 1,
        )
    }
}
