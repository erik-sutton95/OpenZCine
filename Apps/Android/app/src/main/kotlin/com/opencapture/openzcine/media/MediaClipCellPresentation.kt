package com.opencapture.openzcine.media

import com.opencapture.monitorui.MonitorClipValue
import com.opencapture.monitorui.MonitorMediaMasonry
import com.opencapture.opencine.nikon.NikonMediaClipRecord
import com.opencapture.opencine.nikon.NikonMediaContentKind

/** Width over height as the grid shows it: the listed pixel size, turned for a still whose
 * orientation this session has learned (from its tagged thumbnail or its full file). */
internal fun mediaClipAspectRatio(value: NikonLibraryClip): Double? =
    MonitorMediaMasonry.uprightAspect(value.clip.pixelWidth, value.clip.pixelHeight,
        MediaExifOrientation.learned(value.clip.libraryKey(value.bucket)))

/** Source facts only; cache bytes, command admission and rating writes stay with the host. */
internal fun mediaClipCellPresentation(
    clip: NikonMediaClipRecord, cameraID: String, favorite: Boolean, hasRawSibling: Boolean,
    burstCount: Int?, list: Boolean, selecting: Boolean, selected: Boolean,
): MonitorClipValue = MonitorClipValue(
    id = clip.libraryKey(cameraID), title = clip.filename,
    detail = if (list) "${pairAwareBadgeLabel(clip, hasRawSibling)} · ${clipActionLabel(clip)}" else "",
    duration = null, source = if (list) null else clipActionLabel(clip), favorite = favorite,
    burstCount = if (list || selecting) null else burstCount,
    mediaBadge = if (list) null else pairAwareBadgeLabel(clip, hasRawSibling),
    accessibilityDescription = clipAccessibilityLabel(clip, selected, selecting),
    favoriteLabel = if (favorite) "Remove ${clip.filename} from favorites" else "Add ${clip.filename} to favorites",
    selectionEntryLabel = if (selecting) null else "Select ${clip.filename}",
)

private fun clipActionLabel(clip: NikonMediaClipRecord): String =
    when (clip.contentKind) {
        NikonMediaContentKind.PLAYABLE_PROXY -> "PLAY"
        NikonMediaContentKind.STILL_PHOTO -> "VIEW"
        NikonMediaContentKind.R3D_MASTER -> "MASTER"
        NikonMediaContentKind.UNSUPPORTED -> "MEDIA"
    }

/** A paired still's one cell announces both sides (iOS `RAW+J` badge). */
private fun pairAwareBadgeLabel(clip: NikonMediaClipRecord, hasRawSibling: Boolean): String =
    if (hasRawSibling) listOf(clip.sizeLabel, "RAW+J").filter { it.isNotEmpty() }.joinToString(" · ") else clip.badgeLabel

private fun clipAccessibilityLabel(
    clip: NikonMediaClipRecord,
    selected: Boolean,
    isSelecting: Boolean,
): String =
    buildString {
        append(clip.filename)
        append(", ")
        append(clipActionLabel(clip).lowercase())
        if (isSelecting) append(if (selected) ", selected" else ", not selected")
    }
