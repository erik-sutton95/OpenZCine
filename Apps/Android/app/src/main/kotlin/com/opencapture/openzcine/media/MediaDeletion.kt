package com.opencapture.openzcine.media

import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.window.Dialog
import androidx.compose.ui.window.DialogProperties
import com.opencapture.opencine.nikon.NikonMediaClipRecord
import com.opencapture.opencine.nikon.NikonMediaContentKind
import com.opencapture.opencine.nikon.NikonMediaDeletionPlan
import com.opencapture.opencine.nikon.NikonMediaObjectIdentity
import com.opencapture.opencine.appkit.LocalOperatorHaptics
import com.opencapture.monitorui.MonitorConfirmPopup
import com.opencapture.monitorui.MonitorStarRating

/**
 * Camera-card deletion confirmation and the star-rating chrome shared by the still viewer, the
 * player, and the browse selection bar. The Swift facade owns the PTP operations and Core's
 * `NikonMediaDeletionPlan` owns which records one deletion touches; this file owns how the
 * operator confirms it.
 */

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
    return deleteConfirmationMessage(selection, NikonMediaDeletionPlan.of(catalog, selection, ownerCameraID))
}

internal fun deleteConfirmationMessage(selection: List<NikonMediaClipRecord>, plan: NikonMediaDeletionPlan): String {
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
internal fun sameDeletionPlan(captured: NikonMediaDeletionPlan, current: NikonMediaDeletionPlan): Boolean =
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
