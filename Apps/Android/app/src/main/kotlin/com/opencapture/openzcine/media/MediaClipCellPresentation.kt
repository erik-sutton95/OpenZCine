package com.opencapture.openzcine.media

import com.opencapture.monitorui.MonitorClipValue

/** Source facts only; cache bytes, command admission and rating writes stay with the host. */
internal fun mediaClipCellPresentation(
    clip: MediaClipRecord, cameraID: String, favorite: Boolean, hasRawSibling: Boolean,
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

private fun clipActionLabel(clip: MediaClipRecord): String =
    when (clip.contentKind) {
        MediaContentKind.PLAYABLE_PROXY -> "PLAY"
        MediaContentKind.STILL_PHOTO -> "VIEW"
        MediaContentKind.R3D_MASTER -> "MASTER"
        MediaContentKind.UNSUPPORTED -> "MEDIA"
    }

/** A paired still's one cell announces both sides (iOS `RAW+J` badge). */
private fun pairAwareBadgeLabel(clip: MediaClipRecord, hasRawSibling: Boolean): String =
    if (hasRawSibling) "${clip.sizeLabel} · RAW+J" else clip.badgeLabel

private fun clipAccessibilityLabel(
    clip: MediaClipRecord,
    selected: Boolean,
    isSelecting: Boolean,
): String =
    buildString {
        append(clip.filename)
        append(", ")
        append(clipActionLabel(clip).lowercase())
        if (isSelecting) append(if (selected) ", selected" else ", not selected")
    }
