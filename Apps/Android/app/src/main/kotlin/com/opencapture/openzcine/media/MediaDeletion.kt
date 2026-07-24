package com.opencapture.openzcine.media

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Star
import androidx.compose.material.icons.filled.StarBorder
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.role
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.window.Dialog
import androidx.compose.ui.window.DialogProperties
import com.opencapture.openzcine.LiveDesign
import com.opencapture.openzcine.chromeClickable
import com.opencapture.openzcine.chromeStyle
import com.opencapture.openzcine.glass
import java.util.Locale

/**
 * Camera-card deletion policy and the star-rating chrome shared by the still
 * viewer, the player, and the browse selection bar. The Swift facade owns the
 * PTP operations; this file owns only which records one deletion touches and
 * how the operator confirms it.
 */

/** True for the display side of a RAW+JPEG pair (iOS `isJPEGPhoto`). */
internal val MediaClipRecord.isJpegStill: Boolean
    get() = filenameExtension in setOf("jpg", "jpeg", "jpe")

/** True for Nikon RAW stills (iOS `isRawPhoto`) — the tag-along pair side. */
internal val MediaClipRecord.isRawStill: Boolean
    get() = filenameExtension in setOf("nef", "nrw", "dng")

private val MediaClipRecord.filenameExtension: String
    get() = filename.substringAfterLast('.', missingDelimiterValue = "").lowercase(Locale.US)

/**
 * Same-shot pair identity: cache bucket + storage slot + case-insensitive
 * stem (iOS `rawPairKey`). The slot is part of the key on purpose — split
 * recording writes RAW and JPEG to different cards, and those must stay
 * separate items. The bucket keeps two cameras' formulaic `DSC_0001` stems
 * apart in the offline multi-camera library.
 */
internal fun MediaClipRecord.rawPairKey(ownerCameraID: String): String =
    "$ownerCameraID/$storageId/${filename.substringBeforeLast('.').lowercase(Locale.US)}"

/** The same-shot RAW behind a JPEG's item; null for unpaired stills. */
internal fun rawSibling(
    catalog: List<MediaClipRecord>,
    clip: MediaClipRecord,
    ownerCameraID: (MediaClipRecord) -> String,
): MediaClipRecord? {
    if (!clip.isJpegStill) return null
    val pairKey = clip.rawPairKey(ownerCameraID(clip))
    return catalog.firstOrNull { it.isRawStill && it.rawPairKey(ownerCameraID(it)) == pairKey }
}

/**
 * The pair side the still viewer loads, names, and shares for a JPG ⇄ RAW
 * toggle state (iOS viewer `displayClip`). Ratings and deletion stay keyed on
 * the JPEG side regardless of the toggle.
 */
internal fun stillViewerDisplaySide(
    clip: MediaClipRecord,
    rawSibling: MediaClipRecord?,
    showingRaw: Boolean,
): MediaClipRecord = if (showingRaw) rawSibling ?: clip else clip

/**
 * Expands a deletion selection with each JPEG's RAW sibling (a RAW+JPEG pair
 * deletes both sides, like iOS `deleteMediaClips`), de-duplicated by object
 * identity in selection order.
 */
internal fun cameraDeletionTargets(
    catalog: List<MediaClipRecord>,
    selection: List<MediaClipRecord>,
    ownerCameraID: (MediaClipRecord) -> String,
): List<MediaClipRecord> {
    val targets = LinkedHashMap<MediaObjectIdentity, MediaClipRecord>()
    selection.forEach { clip ->
        targets[MediaObjectIdentity(clip)] = clip
        rawSibling(catalog, clip, ownerCameraID)?.let { raw ->
            targets[MediaObjectIdentity(raw)] = raw
        }
    }
    return targets.values.toList()
}

/** iOS confirmation copy for a batch or single camera-card deletion. */
internal fun deleteConfirmationMessage(selection: List<MediaClipRecord>, hasRawPair: Boolean): String {
    if (selection.size == 1) {
        return if (hasRawPair) {
            "Delete this photo from the camera card? Both the RAW and JPEG files are removed."
        } else {
            "Delete ${selection.single().filename} from the camera card?"
        }
    }
    return "Delete ${selection.size} items from the camera card? RAW+JPEG pairs delete both files."
}

/**
 * Five-star rating row on glass (iOS `StarRatingRow`): tap a star to set the
 * count, tap the active count to clear. Optimistic — the caller writes to the
 * camera and rolls back on failure.
 */
@Composable
internal fun StarRatingRow(
    stars: Int,
    modifier: Modifier = Modifier,
    onSelect: (Int) -> Unit,
) {
    Row(
        modifier
            // CircleShape renders as a capsule on a wide row, like iOS's Capsule.
            .glass(CircleShape)
            .padding(horizontal = 16.dp, vertical = 9.dp),
        horizontalArrangement = Arrangement.spacedBy(10.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        (1..5).forEach { star ->
            val filled = star <= stars
            Icon(
                if (filled) Icons.Filled.Star else Icons.Filled.StarBorder,
                contentDescription = "Rate $star star${if (star == 1) "" else "s"}",
                tint = if (filled) LiveDesign.accent else LiveDesign.muted,
                modifier =
                    Modifier.size(22.dp)
                        .semantics { role = Role.Button }
                        .chromeClickable { onSelect(if (star == stars) 0 else star) },
            )
        }
    }
}

/**
 * Destructive camera-card deletion confirmation on the media glass style —
 * matching iOS's confirmation dialog rather than a Material alert.
 */
@Composable
internal fun MediaDeleteConfirmDialog(
    message: String,
    onDelete: () -> Unit,
    onDismiss: () -> Unit,
) {
    Dialog(
        onDismissRequest = onDismiss,
        properties = DialogProperties(usePlatformDefaultWidth = false),
    ) {
        Box(
            Modifier
                .fillMaxSize()
                .background(Color.Black.copy(alpha = 0.45f))
                .chromeClickable(onClick = onDismiss),
            contentAlignment = Alignment.Center,
        ) {
            Column(
                Modifier
                    .padding(horizontal = 20.dp)
                    .widthIn(max = 400.dp)
                    .fillMaxWidth()
                    .glass(RoundedCornerShape(LiveDesign.CORNER_RADIUS_DP.dp))
                    .chromeClickable(onClick = {}) // absorb taps so the backdrop doesn't dismiss
                    .padding(16.dp),
                verticalArrangement = Arrangement.spacedBy(14.dp),
            ) {
                Text(
                    message,
                    style = chromeStyle(14f, FontWeight.Medium),
                    color = LiveDesign.text,
                )
                Row(
                    Modifier.fillMaxWidth(),
                    horizontalArrangement = Arrangement.spacedBy(10.dp, Alignment.End),
                    verticalAlignment = Alignment.CenterVertically,
                ) {
                    Text(
                        "Cancel",
                        style = chromeStyle(13f, FontWeight.SemiBold),
                        color = LiveDesign.muted,
                        modifier =
                            Modifier.glass(CircleShape)
                                .semantics {
                                    contentDescription = "Cancel deletion"
                                    role = Role.Button
                                }.chromeClickable(onClick = onDismiss)
                                .padding(horizontal = 14.dp, vertical = 9.dp),
                    )
                    Text(
                        "Delete",
                        style = chromeStyle(13f, FontWeight.SemiBold),
                        color = Color(0xFFFF5A54),
                        modifier =
                            Modifier.glass(CircleShape)
                                .semantics {
                                    contentDescription = "Delete from the camera card"
                                    role = Role.Button
                                }.chromeClickable(onClick = onDelete)
                                .padding(horizontal = 14.dp, vertical = 9.dp),
                    )
                }
            }
        }
    }
}
