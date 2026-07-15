package com.opencapture.openzcine.media

import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import com.opencapture.openzcine.LiveDesign
import com.opencapture.openzcine.chromeStyle

/** Operator-selected native delivery outcomes shared by browser and playback. */
@Composable
internal fun NativeMediaDeliveryDialog(
    selectedCount: Int,
    shareReadyCount: Int,
    galleryReadyCount: Int,
    busy: Boolean,
    onDismiss: () -> Unit,
    onShare: () -> Unit,
    onSaveToGallery: () -> Unit,
) {
    AlertDialog(
        onDismissRequest = onDismiss,
        title = {
            Text(
                "Deliver media",
                style = chromeStyle(18f, FontWeight.SemiBold),
                color = LiveDesign.text,
            )
        },
        text = {
            Column {
                Text(
                    "$selectedCount ${itemNoun(selectedCount)} selected. Choose where complete cached media goes.",
                    style = chromeStyle(12f, FontWeight.Medium),
                    color = LiveDesign.muted,
                )
                Spacer(Modifier.height(14.dp))
                DeliveryChoiceButton(
                    title = "Share",
                    detail =
                        if (shareReadyCount > 0) {
                            "Open Android's chooser for $shareReadyCount complete cached " +
                                itemNoun(shareReadyCount) + "."
                        } else {
                            "No complete cached media is ready to share."
                        },
                    enabled = shareReadyCount > 0 && !busy,
                    onClick = onShare,
                )
                Spacer(Modifier.height(10.dp))
                DeliveryChoiceButton(
                    title = "Save to Gallery",
                    detail =
                        if (galleryReadyCount > 0) {
                            "Save $galleryReadyCount complete cached " +
                                videoNoun(galleryReadyCount) + " to Movies/OpenZCine."
                        } else {
                            "No complete cached video is ready. Non-video items stay private."
                        },
                    enabled = galleryReadyCount > 0 && !busy,
                    onClick = onSaveToGallery,
                )
            }
        },
        confirmButton = {
            TextButton(onClick = onDismiss, enabled = !busy) {
                Text("Close", color = if (busy) LiveDesign.faint else LiveDesign.text)
            }
        },
        containerColor = LiveDesign.surface,
        titleContentColor = LiveDesign.text,
        textContentColor = LiveDesign.muted,
    )
}

@Composable
private fun DeliveryChoiceButton(
    title: String,
    detail: String,
    enabled: Boolean,
    onClick: () -> Unit,
) {
    OutlinedButton(
        onClick = onClick,
        enabled = enabled,
        modifier = Modifier.fillMaxWidth(),
        shape = RoundedCornerShape(LiveDesign.CORNER_RADIUS_DP.dp),
        border = BorderStroke(1.dp, if (enabled) LiveDesign.accent else LiveDesign.hairline),
        colors =
            ButtonDefaults.outlinedButtonColors(
                contentColor = LiveDesign.text,
                disabledContentColor = LiveDesign.faint,
            ),
    ) {
        Column(Modifier.fillMaxWidth().padding(vertical = 4.dp)) {
            Text(title, style = chromeStyle(14f, FontWeight.SemiBold))
            Text(
                detail,
                style = chromeStyle(10.5f, FontWeight.Medium),
                color = if (enabled) LiveDesign.muted else LiveDesign.faint,
            )
        }
    }
}

private fun itemNoun(count: Int): String = if (count == 1) "item" else "items"

private fun videoNoun(count: Int): String = if (count == 1) "video" else "videos"
