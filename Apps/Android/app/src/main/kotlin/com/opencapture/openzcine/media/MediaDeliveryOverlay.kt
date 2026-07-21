package com.opencapture.openzcine.media

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
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.shadow
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import com.opencapture.openzcine.LiveDesign
import com.opencapture.openzcine.chromeStyle
import com.opencapture.openzcine.glass

/**
 * iOS `MediaDeliveryOverlay` — progress pill for share / save / Frame.io prep.
 * Used both on media surfaces and as the app-root global chrome.
 */
private val DeliveryCapsule = RoundedCornerShape(percent = 50)

@Composable
internal fun MediaDeliveryProgressOverlay(
    state: MediaDeliveryOverlayState,
    onCancel: (() -> Unit)?,
    modifier: Modifier = Modifier,
    expanded: Boolean = true,
    filename: String? = state.filename,
    onExpandToggle: (() -> Unit)? = null,
) {
    if (expanded) {
        ExpandedDeliveryPanel(
            state = state,
            filename = filename,
            onCancel = onCancel,
            onCollapse = onExpandToggle,
            modifier = modifier,
        )
    } else {
        CompactDeliveryPill(
            state = state,
            onCancel = onCancel,
            onExpand = onExpandToggle,
            modifier = modifier,
        )
    }
}

@Composable
private fun CompactDeliveryPill(
    state: MediaDeliveryOverlayState,
    onCancel: (() -> Unit)?,
    onExpand: (() -> Unit)?,
    modifier: Modifier = Modifier,
) {
    Row(
        modifier
            .widthIn(max = 420.dp)
            .shadow(12.dp, DeliveryCapsule, ambientColor = Color.Black.copy(alpha = 0.35f))
            .clip(DeliveryCapsule)
            .glass(DeliveryCapsule)
            .border(1.dp, LiveDesign.hairline.copy(alpha = 0.65f), DeliveryCapsule)
            .padding(horizontal = 14.dp, vertical = 11.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(10.dp),
    ) {
        Row(
            Modifier.weight(1f).then(
                if (onExpand != null) Modifier.clickable(onClick = onExpand) else Modifier,
            ),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(10.dp),
        ) {
            if (state.isPreparingClip) {
                CircularProgressIndicator(
                    modifier = Modifier.size(16.dp),
                    color = LiveDesign.accent,
                    strokeWidth = 2.dp,
                )
            }
            Column(Modifier.weight(1f)) {
                Text(
                    state.statusLine,
                    style = chromeStyle(12f, FontWeight.SemiBold),
                    color = LiveDesign.text,
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis,
                )
                state.batchLine?.let { batch ->
                    Text(
                        batch,
                        style = chromeStyle(10f, FontWeight.Medium, mono = true),
                        color = LiveDesign.muted,
                        maxLines = 1,
                    )
                }
            }
            if (!state.isPreparingClip) {
                Box(
                    Modifier.width(44.dp).height(4.dp).clip(DeliveryCapsule)
                        .background(LiveDesign.hairline.copy(alpha = 0.55f)),
                ) {
                    Box(
                        Modifier.fillMaxWidth(state.overallFraction.toFloat().coerceIn(0.05f, 1f))
                            .height(4.dp)
                            .clip(DeliveryCapsule)
                            .background(LiveDesign.accent),
                    )
                }
            }
        }
        if (onCancel != null) {
            Text(
                "Cancel",
                style = chromeStyle(11f, FontWeight.SemiBold),
                color = LiveDesign.muted,
                modifier = Modifier.clickable(onClick = onCancel),
            )
        }
    }
}

@Composable
private fun ExpandedDeliveryPanel(
    state: MediaDeliveryOverlayState,
    filename: String?,
    onCancel: (() -> Unit)?,
    onCollapse: (() -> Unit)?,
    modifier: Modifier = Modifier,
) {
    Column(
        modifier
            .widthIn(max = 420.dp)
            .shadow(12.dp, RoundedCornerShape(LiveDesign.CORNER_RADIUS_DP.dp))
            .clip(RoundedCornerShape(LiveDesign.CORNER_RADIUS_DP.dp))
            .glass(RoundedCornerShape(LiveDesign.CORNER_RADIUS_DP.dp))
            .border(
                1.dp,
                LiveDesign.hairline.copy(alpha = 0.65f),
                RoundedCornerShape(LiveDesign.CORNER_RADIUS_DP.dp),
            )
            .padding(horizontal = 16.dp, vertical = 12.dp),
        verticalArrangement = Arrangement.spacedBy(8.dp),
    ) {
        Row(
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(10.dp),
        ) {
            if (state.isPreparingClip) {
                CircularProgressIndicator(
                    modifier = Modifier.size(16.dp),
                    color = LiveDesign.accent,
                    strokeWidth = 2.dp,
                )
            }
            Column(Modifier.weight(1f)) {
                state.batchLine?.let { batch ->
                    Text(
                        batch,
                        style = chromeStyle(10f, FontWeight.SemiBold, mono = true),
                        color = LiveDesign.muted,
                    )
                }
                Text(
                    state.statusLine,
                    style = chromeStyle(13f, FontWeight.SemiBold),
                    color = LiveDesign.text,
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis,
                )
            }
            if (onCancel != null) {
                Text(
                    "Cancel",
                    style = chromeStyle(12f, FontWeight.SemiBold),
                    color = LiveDesign.muted,
                    modifier = Modifier.clickable(onClick = onCancel),
                )
            }
        }
        if (!state.isPreparingClip) {
            Box(
                Modifier.fillMaxWidth().height(4.dp).clip(DeliveryCapsule)
                    .background(LiveDesign.hairline.copy(alpha = 0.55f)),
            ) {
                Box(
                    Modifier.fillMaxWidth(state.overallFraction.toFloat().coerceIn(0.05f, 1f))
                        .height(4.dp)
                        .clip(DeliveryCapsule)
                        .background(LiveDesign.accent),
                )
            }
        }
        filename?.takeIf { it.isNotBlank() }?.let { name ->
            Row(horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                Text("File", style = chromeStyle(10f, FontWeight.SemiBold), color = LiveDesign.muted)
                Text(
                    name,
                    style = chromeStyle(11f, FontWeight.Medium, mono = true),
                    color = LiveDesign.text,
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis,
                    modifier = Modifier.weight(1f),
                )
            }
        }
        Text(
            "Destination: ${destinationTitle(state.destination)}",
            style = chromeStyle(11f, FontWeight.Medium),
            color = LiveDesign.muted,
        )
        if (onCollapse != null) {
            Text(
                "Collapse",
                style = chromeStyle(12f, FontWeight.SemiBold),
                color = LiveDesign.accent,
                modifier =
                    Modifier.align(Alignment.End).clickable(onClick = onCollapse),
            )
        }
    }
}

private fun destinationTitle(kind: MediaDeliveryKind): String =
    when (kind) {
        MediaDeliveryKind.NATIVE_SHARE -> "Share"
        MediaDeliveryKind.SAVE_TO_PHOTOS -> "Photos"
        MediaDeliveryKind.FRAMEIO -> "Frame.io"
    }

/** Bottom toast after a delivery run completes (iOS completion toast). */
@Composable
internal fun MediaDeliveryCompletionToast(message: String, modifier: Modifier = Modifier) {
    Box(modifier.fillMaxWidth(), contentAlignment = Alignment.BottomCenter) {
        Text(
            message,
            style = chromeStyle(13f, FontWeight.Medium),
            color = LiveDesign.text,
            modifier =
                Modifier.padding(bottom = 28.dp)
                    .clip(DeliveryCapsule)
                    .glass(DeliveryCapsule)
                    .padding(horizontal = 16.dp, vertical = 10.dp),
        )
    }
}
