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
import androidx.compose.foundation.layout.width
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
 * First-iteration photography capture strip when the body reports photo mode.
 *
 * Same warm-dark tile language as the cinema monitor; shutter replaces the
 * record button. Actions are callbacks — the shell wires still release and
 * pickers to the session when those paths are ready.
 */
@Composable
internal fun PhotographyCaptureStrip(
    properties: CameraPropertySnapshot,
    isCapturing: Boolean,
    onShutter: () -> Unit,
    onSelectDrive: () -> Unit,
    onSelectMode: () -> Unit,
    onSelectIso: () -> Unit,
    onSelectShutter: () -> Unit,
    onSelectIris: () -> Unit,
    onInstantPlayback: () -> Unit,
    modifier: Modifier = Modifier,
) {
    Row(
        modifier
            .fillMaxWidth()
            .clip(RoundedCornerShape(18.dp))
            .background(StartupColors.control.copy(alpha = 0.55f))
            .padding(horizontal = 12.dp, vertical = 8.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(8.dp),
    ) {
        PhotographyTile("MODE", properties.exposureMode ?: "—", onSelectMode)
        PhotographyTile("DRIVE", properties.stillCaptureMode ?: "Single", onSelectDrive)
        PhotographyTile("ISO", properties.iso?.toString() ?: "—", onSelectIso)
        PhotographyTile("SHUTTER", properties.shutterSpeed ?: "—", onSelectShutter)
        PhotographyTile("IRIS", properties.iris ?: "—", onSelectIris)
        Spacer(Modifier.weight(1f))
        Box(
            Modifier
                .size(40.dp)
                .clip(CircleShape)
                .background(StartupColors.control.copy(alpha = 0.75f))
                .clickable(onClick = onInstantPlayback)
                .semantics { contentDescription = "Instant playback" },
            contentAlignment = Alignment.Center,
        ) {
            Text("IMG", color = StartupColors.ink, fontSize = 10.sp, fontWeight = FontWeight.Bold)
        }
        Box(
            Modifier
                .size(58.dp)
                .clip(CircleShape)
                .border(3.dp, Color.White.copy(alpha = 0.92f), CircleShape)
                .clickable(enabled = !isCapturing, onClick = onShutter)
                .semantics {
                    contentDescription = if (isCapturing) "Capturing" else "Shutter"
                },
            contentAlignment = Alignment.Center,
        ) {
            Box(
                Modifier
                    .size(46.dp)
                    .clip(CircleShape)
                    .background(if (isCapturing) Color.White.copy(alpha = 0.55f) else Color.White),
            )
        }
    }
}

@Composable
internal fun PhotographySecondaryStrip(
    properties: CameraPropertySnapshot,
    onSelectMetering: () -> Unit,
    onSelectFlash: () -> Unit,
    onSelectQuality: () -> Unit,
    onSelectFocus: () -> Unit,
    modifier: Modifier = Modifier,
) {
    Row(
        modifier.fillMaxWidth().padding(horizontal = 12.dp),
        horizontalArrangement = Arrangement.spacedBy(8.dp),
    ) {
        PhotographyTile("METER", properties.meteringMode ?: "—", onSelectMetering, compact = true)
        PhotographyTile("FLASH", properties.flashMode ?: "—", onSelectFlash, compact = true)
        PhotographyTile(
            "QUAL",
            properties.compression ?: properties.imageSize ?: "—",
            onSelectQuality,
            compact = true,
        )
        PhotographyTile("FOCUS", properties.focusMode ?: "—", onSelectFocus, compact = true)
        properties.exposureBias?.let { PhotographyTile("EV", it, {}, compact = true) }
        Spacer(Modifier.weight(1f))
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
                .padding(horizontal = 8.dp, vertical = 4.dp)
                .semantics { contentDescription = "Photography mode" },
        color = StartupColors.ink,
        fontSize = 10.sp,
        fontWeight = FontWeight.Bold,
        letterSpacing = 1.2.sp,
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
    compact: Boolean = false,
) {
    Column(
        Modifier
            .clip(RoundedCornerShape(12.dp))
            .background(StartupColors.control.copy(alpha = 0.82f))
            .clickable(onClick = onClick)
            .padding(horizontal = if (compact) 8.dp else 10.dp, vertical = if (compact) 6.dp else 8.dp)
            .semantics { contentDescription = "$title $value" },
    ) {
        Text(
            title,
            color = StartupColors.muted,
            fontSize = if (compact) 8.sp else 9.sp,
            fontWeight = FontWeight.SemiBold,
            letterSpacing = 0.6.sp,
        )
        Spacer(Modifier.height(2.dp))
        Text(
            value,
            color = StartupColors.ink,
            fontSize = if (compact) 12.sp else 14.sp,
            fontWeight = FontWeight.SemiBold,
            maxLines = 1,
        )
    }
}
