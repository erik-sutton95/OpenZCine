package com.opencapture.openzcine.media

import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import com.opencapture.monitorui.MonitorMediaDeliveryProgress
import com.opencapture.monitorui.MonitorMediaDeliveryProgressPanel
import com.opencapture.monitorui.MonitorMediaDeliveryProgressDetailsValue
import com.opencapture.openzcine.LiveDesign
import com.opencapture.openzcine.chromeStyle
import com.opencapture.monitorui.MonitorMaterial
import com.opencapture.monitorui.monitorMaterial

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
    val value = state.monitorProgressValue()
    if (expanded) {
        MonitorMediaDeliveryProgressPanel(
            value = value,
            details = MonitorMediaDeliveryProgressDetailsValue(
                filename = filename?.takeIf { it.isNotBlank() },
                destination = destinationTitle(state.destination),
            ),
            onCancel = onCancel,
            onCollapse = onExpandToggle,
            modifier = modifier.widthIn(max = 420.dp),
            destinationIcon = {},
        )
    } else {
        MonitorMediaDeliveryProgress(
            value = value,
            onCancel = onCancel,
            onExpand = onExpandToggle,
            modifier = modifier.widthIn(max = 420.dp),
            destinationIcon = {},
        )
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
                    .monitorMaterial(MonitorMaterial.Compact, DeliveryCapsule)
                    .padding(horizontal = 16.dp, vertical = 10.dp),
        )
    }
}
