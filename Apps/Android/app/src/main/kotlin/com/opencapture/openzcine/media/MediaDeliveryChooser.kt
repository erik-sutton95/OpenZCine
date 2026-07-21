package com.opencapture.openzcine.media

import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.Switch
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import com.opencapture.openzcine.LiveDesign
import com.opencapture.openzcine.FeedLutSelection
import com.opencapture.openzcine.chromeStyle
import com.opencapture.openzcine.frameio.MediaDeliveryConfiguration
import com.opencapture.openzcine.frameio.MediaExportContainer

/** Operator-selected native delivery outcomes shared by browser and playback. */
@Composable
internal fun NativeMediaDeliveryDialog(
    selectedCount: Int,
    shareReadyCount: Int,
    galleryReadyCount: Int,
    busy: Boolean,
    selectedLut: FeedLutSelection?,
    selectedLutLabel: String?,
    onDismiss: () -> Unit,
    onShare: (MediaDeliveryConfiguration) -> Unit,
    onSaveToGallery: (MediaDeliveryConfiguration) -> Unit,
) {
    var bakeLut by remember(selectedLut) { mutableStateOf(selectedLut != null) }
    var exportContainer by remember { mutableStateOf(MediaExportContainer.MOV) }
    var includeMetadata by remember { mutableStateOf(true) }
    val configuration =
        MediaDeliveryConfiguration(
            bakeLut = bakeLut,
            exportContainer = exportContainer,
            includeMetadata = includeMetadata,
            selectedLut = selectedLut.takeIf { bakeLut },
        )
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
            Column(Modifier.heightIn(max = 290.dp).verticalScroll(rememberScrollState())) {
                Text(
                    "$selectedCount ${itemNoun(selectedCount)} selected. Choose where complete cached media goes.",
                    style = chromeStyle(12f, FontWeight.Medium),
                    color = LiveDesign.muted,
                )
                Spacer(Modifier.height(14.dp))
                NativeExportOptions(
                    bakeLut = bakeLut,
                    exportContainer = exportContainer,
                    includeMetadata = includeMetadata,
                    selectedLutLabel = selectedLutLabel,
                    onBakeLutChanged = { bakeLut = it },
                    onExportContainerChanged = { exportContainer = it },
                    onIncludeMetadataChanged = { includeMetadata = it },
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
                    onClick = { onShare(configuration) },
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
                    onClick = { onSaveToGallery(configuration) },
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
internal fun NativeExportOptions(
    bakeLut: Boolean,
    exportContainer: MediaExportContainer,
    includeMetadata: Boolean,
    selectedLutLabel: String?,
    onBakeLutChanged: (Boolean) -> Unit,
    onExportContainerChanged: (MediaExportContainer) -> Unit,
    onIncludeMetadataChanged: (Boolean) -> Unit,
) {
    DeliveryOptionRow(
        title = "Bake selected LUT",
        detail =
            selectedLutLabel?.let { "$it, temporary ${exportContainer.label} copy" }
                ?: "No approved monitor LUT is selected",
        checked = bakeLut,
        enabled = selectedLutLabel != null,
        onCheckedChange = onBakeLutChanged,
    )
    Text(
        "Container for baked exports",
        style = chromeStyle(10f, FontWeight.Medium),
        color = LiveDesign.muted,
    )
    Row(horizontalArrangement = Arrangement.spacedBy(6.dp)) {
        MediaExportContainer.entries.forEach { container ->
            TextButton(onClick = { onExportContainerChanged(container) }) {
                Text(if (container == exportContainer) "${container.label} ✓" else container.label)
            }
        }
    }
    DeliveryOptionRow(
        title = "Include metadata",
        detail = "Share clip details and preserve camera capture time in Gallery",
        checked = includeMetadata,
        enabled = true,
        onCheckedChange = onIncludeMetadataChanged,
    )
    Text(
        "Container applies only when a LUT is baked. Originals are never changed.",
        style = chromeStyle(10f, FontWeight.Medium),
        color = LiveDesign.faint,
    )
}

@Composable
private fun DeliveryOptionRow(
    title: String,
    detail: String,
    checked: Boolean,
    enabled: Boolean,
    onCheckedChange: (Boolean) -> Unit,
) {
    Row(
        modifier = Modifier.fillMaxWidth(),
        horizontalArrangement = Arrangement.spacedBy(10.dp),
    ) {
        Column(Modifier.weight(1f)) {
            Text(title, style = chromeStyle(12f, FontWeight.SemiBold), color = LiveDesign.text)
            Text(detail, style = chromeStyle(10f, FontWeight.Medium), color = LiveDesign.muted)
        }
        Switch(
            checked = checked,
            enabled = enabled,
            onCheckedChange = onCheckedChange,
        )
    }
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
