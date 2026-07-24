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

/**
 * This clip as a burst-detection frame (iOS `MediaClip.burstFrame`): capture identity plus a
 * format/dimensions signature, keyed by the object's library id so members map back to records.
 * RAW and JPEG of one shot share the stem so a burst of pairs counts once.
 */
internal fun MediaClipRecord.burstFrame(ownerCameraID: String): BurstFrame =
    BurstFrame(
        id = libraryKey(ownerCameraID),
        storageId = storageId,
        handle = handle,
        captureDate = captureDate,
        stem = filename.substringBeforeLast('.').lowercase(Locale.US),
        isRaw = isRawStill,
        formatKey = "$filenameExtension|${pixelWidth}x$pixelHeight",
    )

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

private val masterExtensions = setOf("r3d", "nev")

private fun MediaClipRecord.stemLowercase(): String =
    filename.substringBeforeLast('.').lowercase(Locale.US)

/**
 * Cross-card copies of the same shot: same bucket + case-insensitive stem + capture second on
 * ANOTHER card. Backup recording writes the shot to both cards; series membership is
 * same-storage by design, so a delete must widen to the twins itself. An undated clip never
 * matches (every undated file would twin). [verify-on-HW: backup-mode capture dates match]
 */
internal fun crossCardTwins(
    catalog: List<MediaClipRecord>,
    clip: MediaClipRecord,
    ownerCameraID: (MediaClipRecord) -> String,
): List<MediaClipRecord> {
    if (clip.captureDate.isEmpty()) return emptyList()
    val owner = ownerCameraID(clip)
    val stem = clip.stemLowercase()
    return catalog.filter {
        it.storageId != clip.storageId &&
            ownerCameraID(it) == owner &&
            it.captureDate == clip.captureDate &&
            it.stemLowercase() == stem
    }
}

/**
 * Same-stem camera masters (`.R3D` / `.NEV`) on the same card as a playable proxy — the grid
 * hides them behind the proxy, so deleting the proxy must take them along.
 */
internal fun linkedMasters(
    catalog: List<MediaClipRecord>,
    clip: MediaClipRecord,
    ownerCameraID: (MediaClipRecord) -> String,
): List<MediaClipRecord> {
    if (clip.contentKind != MediaContentKind.PLAYABLE_PROXY) return emptyList()
    val owner = ownerCameraID(clip)
    val stem = clip.stemLowercase()
    return catalog.filter {
        MediaObjectIdentity(it) != MediaObjectIdentity(clip) &&
            it.storageId == clip.storageId &&
            ownerCameraID(it) == owner &&
            it.filenameExtension in masterExtensions &&
            it.stemLowercase() == stem
    }
}

/**
 * Everything one deletion will actually remove, and why — the confirm copy and the delete run
 * from the same expansion so they can never disagree (iOS `DeletionPlan`).
 */
internal data class DeletionPlan(
    val targets: List<MediaClipRecord>,
    /** RAW siblings pulled in behind requested JPEGs. */
    val pairCount: Int,
    /** Same-stem camera masters pulled in behind requested proxies. */
    val masterCount: Int,
    /** Cross-card copies of the same shots (backup recording, split RAW) pulled in. */
    val backupCount: Int,
)

/**
 * Expands a deletion request to the full set of objects it honestly removes: each shot's RAW
 * sibling, its hidden camera master, and the cross-card twins of all of those.
 */
internal fun deletionPlan(
    catalog: List<MediaClipRecord>,
    selection: List<MediaClipRecord>,
    ownerCameraID: (MediaClipRecord) -> String,
): DeletionPlan {
    val targets = LinkedHashMap<MediaObjectIdentity, MediaClipRecord>()
    var pairs = 0
    var masters = 0
    var backups = 0
    fun insert(clip: MediaClipRecord): Boolean {
        val identity = MediaObjectIdentity(clip)
        if (targets.containsKey(identity)) return false
        targets[identity] = clip
        return true
    }
    selection.forEach { clip ->
        val shot = buildList {
            add(clip)
            rawSibling(catalog, clip, ownerCameraID)?.let(::add)
            addAll(linkedMasters(catalog, clip, ownerCameraID))
        }
        shot.forEachIndexed { index, piece ->
            if (insert(piece) && index > 0) {
                if (piece.isRawStill) pairs += 1 else masters += 1
            }
            crossCardTwins(catalog, piece, ownerCameraID).forEach { twin ->
                if (insert(twin)) backups += 1
            }
        }
    }
    return DeletionPlan(targets.values.toList(), pairs, masters, backups)
}

/**
 * Expands a deletion selection to every companion object of the same shots (RAW siblings,
 * hidden camera masters, cross-card backup twins), de-duplicated in selection order.
 */
internal fun cameraDeletionTargets(
    catalog: List<MediaClipRecord>,
    selection: List<MediaClipRecord>,
    ownerCameraID: (MediaClipRecord) -> String,
): List<MediaClipRecord> = deletionPlan(catalog, selection, ownerCameraID).targets

/**
 * Destructive-confirmation copy naming only what this request actually removes: still wording
 * for stills, master wording for proxies with hidden masters, and the cross-card note only
 * when backup twins really exist (iOS `deletionConfirmMessage`).
 */
internal fun deleteConfirmationMessage(
    catalog: List<MediaClipRecord>,
    selection: List<MediaClipRecord>,
    ownerCameraID: (MediaClipRecord) -> String,
): String {
    val plan = deletionPlan(catalog, selection, ownerCameraID)
    var message =
        if (selection.size == 1) {
            val only = selection.single()
            if (only.contentKind == MediaContentKind.STILL_PHOTO) {
                "Delete this photo from the camera card?"
            } else {
                "Delete ${only.filename} from the camera card?"
            }
        } else {
            "Delete ${selection.size} items from the camera card?"
        }
    if (plan.pairCount > 0) message += " Both the RAW and JPEG files of a pair are removed."
    if (plan.masterCount > 0) message += " The camera master file is removed with its proxy."
    if (plan.backupCount > 0) message += " The backup copies on the other card are removed too."
    return message
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
 * The outcome of `SwiftCore.sessionSetObjectRating`, whose packed `Int` return encodes three
 * cases: a confirmed 0–5 star count, a state-based refusal carrying the body's wire code, or a
 * generic failure with no code. The camera stays source of truth — a refusal is surfaced with
 * its code, never a silent rollback, and never mirrored into the local favorite index.
 */
internal sealed interface RatingWriteResult {
    data class Confirmed(val stars: Int) : RatingWriteResult

    /** [code] is the raw PTP response (e.g. 0x2013 Access Denied); 0 when none was reported. */
    data class Refused(val code: Int) : RatingWriteResult
}

/** Decodes the packed return: `>= 0` confirmed stars; `< -1` a negated wire code; `-1` no code. */
internal fun ratingWriteResult(returnValue: Int): RatingWriteResult =
    if (returnValue >= 0) {
        RatingWriteResult.Confirmed(returnValue)
    } else {
        RatingWriteResult.Refused(if (returnValue < -1) -returnValue else 0)
    }

/** Operator-facing refusal line carrying the body's response code (the diagnostic discriminator). */
internal fun ratingRefusalMessage(code: Int): String =
    when {
        code == 0 -> "Rating not saved — the camera didn't respond."
        code == 0x2013 ->
            "Rating not saved — camera refused (Access Denied ${ratingCodeHex(code)}). " +
                "It may not accept ratings in this mode."
        else -> "Rating not saved — camera refused (${ratingCodeHex(code)})."
    }

private fun ratingCodeHex(code: Int): String = "0x%04X".format(code)

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
