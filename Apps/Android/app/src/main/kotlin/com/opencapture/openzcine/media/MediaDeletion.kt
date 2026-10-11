package com.opencapture.openzcine.media

import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.window.Dialog
import androidx.compose.ui.window.DialogProperties
import com.opencapture.opencine.nikon.NikonMediaClipRecord
import com.opencapture.opencine.nikon.NikonMediaContentKind
import com.opencapture.opencine.nikon.NikonMediaObjectIdentity
import java.util.Locale
import com.opencapture.opencine.nikon.NikonNative
import com.opencapture.opencine.appkit.LocalOperatorHaptics
import com.opencapture.monitorui.MonitorConfirmPopup
import com.opencapture.monitorui.MonitorStarRating

/**
 * Camera-card deletion policy and the star-rating chrome shared by the still
 * viewer, the player, and the browse selection bar. The Swift facade owns the
 * PTP operations; this file owns only which records one deletion touches and
 * how the operator confirms it.
 */

/**
 * True for the display side of a RAW+JPEG pair (iOS `isJPEGPhoto`).
 *
 * Reads the classification the shared core already made and sent over the listing wire, rather
 * than re-deriving it from the extension here: Kotlin does not classify camera filenames, and a
 * second copy of the extension set only stays right until one copy learns a new extension. (`.HIF`
 * was missing from the core's HEIF set while two other places already special-cased it, and every
 * Nikon HEIF went unlisted as a result.) Stills always carry the label — `MediaLibraryState`
 * enforces `contentKind == STILL_PHOTO` iff `stillPhoto != null`, and the cache round-trips it.
 */
internal val NikonMediaClipRecord.isJpegStill: Boolean
    get() = formatFilter() == MediaFormatFilter.JPEG

/** True for Nikon RAW stills (iOS `isRawPhoto`) — the tag-along pair side. */
internal val NikonMediaClipRecord.isRawStill: Boolean
    get() = formatFilter() == MediaFormatFilter.NEF

private val NikonMediaClipRecord.filenameExtension: String
    get() = filename.substringAfterLast('.', missingDelimiterValue = "").lowercase(Locale.US)

/**
 * Same-shot pair identity: cache bucket + storage slot + case-insensitive
 * stem (iOS `rawPairKey`). The slot is part of the key on purpose — split
 * recording writes RAW and JPEG to different cards, and those must stay
 * separate items. The bucket keeps two cameras' formulaic `DSC_0001` stems
 * apart in the offline multi-camera library.
 */
internal fun NikonMediaClipRecord.rawPairKey(ownerCameraID: String): String =
    "$ownerCameraID/$storageId/${filename.substringBeforeLast('.').lowercase(Locale.US)}"

/** The same-shot RAW behind a JPEG's item; null for unpaired stills. */
internal fun rawSibling(
    catalog: List<NikonMediaClipRecord>,
    clip: NikonMediaClipRecord,
    ownerCameraID: (NikonMediaClipRecord) -> String,
): NikonMediaClipRecord? {
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
    clip: NikonMediaClipRecord,
    rawSibling: NikonMediaClipRecord?,
    showingRaw: Boolean,
): NikonMediaClipRecord = if (showingRaw) rawSibling ?: clip else clip

private val masterExtensions = setOf("r3d", "nev")

private fun NikonMediaClipRecord.stemLowercase(): String =
    filename.substringBeforeLast('.').lowercase(Locale.US)

/**
 * Cross-card copies of the same shot: same bucket + case-insensitive stem + capture second on
 * ANOTHER card. Backup recording writes the shot to both cards; series membership is
 * same-storage by design, so a delete must widen to the twins itself. An undated clip never
 * matches (every undated file would twin). [verify-on-HW: backup-mode capture dates match]
 */
internal fun crossCardTwins(
    catalog: List<NikonMediaClipRecord>,
    clip: NikonMediaClipRecord,
    ownerCameraID: (NikonMediaClipRecord) -> String,
): List<NikonMediaClipRecord> {
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
    catalog: List<NikonMediaClipRecord>,
    clip: NikonMediaClipRecord,
    ownerCameraID: (NikonMediaClipRecord) -> String,
): List<NikonMediaClipRecord> {
    if (clip.contentKind != NikonMediaContentKind.PLAYABLE_PROXY) return emptyList()
    val owner = ownerCameraID(clip)
    val stem = clip.stemLowercase()
    return catalog.filter {
        NikonMediaObjectIdentity(it) != NikonMediaObjectIdentity(clip) &&
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
    val targets: List<NikonMediaClipRecord>,
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
    catalog: List<NikonMediaClipRecord>,
    selection: List<NikonMediaClipRecord>,
    ownerCameraID: (NikonMediaClipRecord) -> String,
): DeletionPlan {
    val targets = LinkedHashMap<NikonMediaObjectIdentity, NikonMediaClipRecord>()
    var pairs = 0
    var masters = 0
    var backups = 0
    fun insert(clip: NikonMediaClipRecord): Boolean {
        val identity = NikonMediaObjectIdentity(clip)
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
    catalog: List<NikonMediaClipRecord>,
    selection: List<NikonMediaClipRecord>,
    ownerCameraID: (NikonMediaClipRecord) -> String,
): List<NikonMediaClipRecord> = deletionPlan(catalog, selection, ownerCameraID).targets

/**
 * Destructive-confirmation copy naming only what this request actually removes: still wording
 * for stills, master wording for proxies with hidden masters, and the cross-card note only
 * when backup twins really exist (iOS `deletionConfirmMessage`).
 */
internal fun deleteConfirmationMessage(
    catalog: List<NikonMediaClipRecord>,
    selection: List<NikonMediaClipRecord>,
    ownerCameraID: (NikonMediaClipRecord) -> String,
): String {
    return deleteConfirmationMessage(selection, deletionPlan(catalog, selection, ownerCameraID))
}

internal fun deleteConfirmationMessage(selection: List<NikonMediaClipRecord>, plan: DeletionPlan): String {
    var message =
        if (selection.size == 1) {
            val only = selection.single()
            if (only.contentKind == NikonMediaContentKind.STILL_PHOTO) {
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

/** Revalidation never expands the confirmed request into newly discovered objects. */
internal fun sameDeletionPlan(captured: DeletionPlan, current: DeletionPlan): Boolean =
    captured.pairCount == current.pairCount && captured.masterCount == current.masterCount &&
        captured.backupCount == current.backupCount && captured.targets.size == current.targets.size &&
        captured.targets.zip(current.targets).all { (old, actual) ->
            NikonMediaObjectIdentity(old) == NikonMediaObjectIdentity(actual) &&
                sameNikonActionContent(old, actual)
        }

/**
 * Five-star rating row on glass (iOS `StarRatingRow`): tap a star to set the
 * count, tap the active count to clear. The caller writes to the
 * camera and rolls back on failure.
 */
@Composable
internal fun StarRatingRow(
    stars: Int,
    modifier: Modifier = Modifier,
    onSelect: (Int) -> Unit,
) {
    val haptics = LocalOperatorHaptics.current
    MonitorStarRating(stars, onSelect, modifier = modifier, selectionFeedback = haptics::selection)
}

/**
 * The outcome of `NikonNative.sessionSetObjectRating`, whose packed `Int` return encodes three
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
 * Destructive camera-card deletion confirmation: the shared confirm card in its own window, so it
 * sits over every overlay and Back dismisses it.
 */
@Composable
internal fun MediaDeleteConfirmDialog(
    message: String,
    onDelete: () -> Unit,
    onDismiss: () -> Unit,
) {
    val haptics = LocalOperatorHaptics.current
    Dialog(onDismissRequest = onDismiss, properties = DialogProperties(usePlatformDefaultWidth = false)) {
        MonitorConfirmPopup(
            title = message,
            confirmTitle = "Delete",
            onDismiss = onDismiss,
            onConfirm = onDelete,
            onClickFeedback = { haptics.selection() },
        )
    }
}
