package com.opencapture.openzcine

import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.absoluteOffset
import androidx.compose.foundation.layout.size
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.semantics.clearAndSetSemantics
import androidx.compose.ui.semantics.contentDescription
import com.opencapture.opencine.cameracontrols.MonitorOperatorFocusLayer
import com.opencapture.opencine.vocabulary.TrackingBox
import com.opencapture.opencine.vocabulary.TrackingHud
import com.opencapture.opencine.nikon.LiveFocusBox
import com.opencapture.opencine.nikon.LiveFocusInfo
import com.opencapture.opencine.nikon.LiveFocusResult

// Nikon AF metadata on the shared focus layer: the camera reports one or more AF boxes in its own
// coordinates; this file only normalizes them and hands them to MonitorOperatorFocusLayer.

/**
 * Maps one camera-coordinate AF box into [feed]'s actual visible image rect.
 *
 * [mirrored] folds the box across the feed the same way the shader folds the picture, so the
 * outline stays on the subject it belongs to when the mirror assist is on.
 */
internal fun liveFocusBoxRect(
    focus: LiveFocusInfo,
    box: LiveFocusBox,
    feed: LiveOverlayRect,
    mirrored: Boolean = false,
    mirroredVertical: Boolean = false,
): LiveOverlayRect? {
    if (
        focus.coordinateWidth <= 0 ||
            focus.coordinateHeight <= 0 ||
            box.width <= 0 ||
            box.height <= 0 ||
            feed.width <= 0f ||
            feed.height <= 0f
    ) {
        return null
    }
    val scaleX = feed.width / focus.coordinateWidth
    val scaleY = feed.height / focus.coordinateHeight
    val width = box.width * scaleX
    val height = box.height * scaleY
    val centerX = box.centerX * scaleX
    return LiveOverlayRect(
        left = feed.left + (if (mirrored) feed.width - centerX else centerX) - width / 2f,
        top = feed.top + (if (mirroredVertical) feed.height - box.centerY * scaleY else box.centerY * scaleY) - height / 2f,
        width = width,
        height = height,
    )
}


/**
 * The camera's AF boxes on the shared focus layer, mounted over the visible feed rectangle: the
 * primary box is the focus mark (its size, focus result colour, hold-to-lock fill and lock glyph),
 * further group-AF boxes draw as plain confirmed areas.
 */
@Composable
internal fun CameraFocusOverlay(
    focus: LiveFocusInfo?,
    feed: LiveOverlayRect,
    locked: Boolean,
    lockProgress: Float,
    alpha: Float = 1f,
    editModifier: Modifier? = null,
    mirrored: Boolean = false,
    mirroredVertical: Boolean = false,
) {
    if (focus == null || focus.boxes.isEmpty()) return
    val marks = nikonFocusAreas(focus) ?: return
    val description =
        focus.accessibilityDescription() +
            if (locked) " Focus point position locked in app." else ""
    val density = LocalDensity.current
    // The Edit view's outline and badge go on the primary AF box, not the whole feed: a dashed
    // rectangle round the entire image would name nothing.
    val primaryRect = liveFocusBoxRect(focus, focus.boxes.first(), feed, mirrored, mirroredVertical)
    if (editModifier != null && primaryRect != null) {
        with(density) {
            // Offset and size FIRST: `chromeEditable`'s `onGloballyPositioned` reports the bounds
            // of its own node, and an offset applied inside it moves only the child (the badge
            // landed at the overlay's origin instead of on the box).
            Box(
                Modifier
                    .absoluteOffset(primaryRect.left.toDp(), primaryRect.top.toDp())
                    .size(primaryRect.width.toDp(), primaryRect.height.toDp())
                    .then(editModifier),
            )
        }
    }
    with(density) {
        MonitorOperatorFocusLayer(
            hud = TrackingHud(),
            focus = marks.primary?.let { it.centerX.toFloat() to it.centerY.toFloat() },
            mirrored = mirrored,
            showTapFocusBox = true,
            modifier = Modifier
                .absoluteOffset(feed.left.toDp(), feed.top.toDp())
                .size(feed.width.toDp(), feed.height.toDp())
                .alpha(alpha)
                .clearAndSetSemantics { contentDescription = description },
            flippedVertically = mirroredVertical,
            focusLocked = locked,
            focusArea = marks.primary,
            otherFocusAreas = marks.others,
            focusConfirmed = marks.confirmed,
            focusLockProgress = lockProgress,
        )
    }
}

/** Nikon AF boxes in camera orientation, normalized to the camera's coordinate space. */
internal data class NikonFocusAreas(
    val primary: TrackingBox?,
    val others: List<TrackingBox>,
    /** Focus achieved, or the camera is tracking a subject: the shared confirmed colour. */
    val confirmed: Boolean,
)

/** Null when the camera reports no usable coordinate space. */
internal fun nikonFocusAreas(focus: LiveFocusInfo): NikonFocusAreas? {
    if (focus.coordinateWidth <= 0 || focus.coordinateHeight <= 0) return null
    val width = focus.coordinateWidth.toDouble()
    val height = focus.coordinateHeight.toDouble()
    fun normalized(box: LiveFocusBox): TrackingBox? =
        if (box.width <= 0 || box.height <= 0) null
        else TrackingBox((box.centerX - box.width / 2.0) / width, (box.centerY - box.height / 2.0) / height,
            box.width / width, box.height / height)
    return NikonFocusAreas(
        primary = focus.boxes.firstOrNull()?.let(::normalized),
        others = focus.boxes.drop(1).mapNotNull(::normalized),
        confirmed = focus.result == LiveFocusResult.FOCUSED || focus.trackingAFActive,
    )
}

/** Accessible focus copy that distinguishes debug fixtures from camera metadata. */
internal fun LiveFocusInfo.accessibilityDescription(): String {
    val state =
        when (result) {
            LiveFocusResult.FOCUSED -> "focused"
            LiveFocusResult.NOT_FOCUSED -> "not focused"
            LiveFocusResult.UNKNOWN -> "focus state unknown"
        }
    val subject = if (subjectDetectionActive) "Subject detection active." else ""
    val tracking = if (trackingAFActive) " Tracking active." else ""
    val origin =
        if (isDebugFixture) {
            "Debug focus fixture, not camera focus data."
        } else {
            "Camera focus overlay."
        }
    return "$origin ${boxes.size} boxes. $state. $subject$tracking"
}
