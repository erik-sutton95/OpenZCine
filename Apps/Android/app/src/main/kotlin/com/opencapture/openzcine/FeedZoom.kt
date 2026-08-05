package com.opencapture.openzcine

/**
 * Direct-manipulation zoom for the live feed — the Photos-app contract, and the twin of the iOS
 * implementation in `ios/Runner/MonitorExperience.swift` ("Pinch zoom").
 *
 * Pinch anywhere on the feed and it zooms about the pinch, drag to pan, pinch back out (or below
 * [SNAP_BACK_BELOW]) and it settles to 1x. This replaces the fixed-factor MAG tool, which zoomed by
 * a preset amount about the AF box rather than about the operator's fingers.
 *
 * The transform is a CENTER-anchored scale followed by an offset, in that order — every formula
 * here is written against that pair, so the render must apply it the same way.
 */
internal data class FeedZoom(
    val scale: Float = 1f,
    val offsetX: Float = 0f,
    val offsetY: Float = 0f,
) {
    val isZoomed: Boolean get() = scale > ZOOMED_ABOVE

    internal companion object {
        /** Furthest a pinch can magnify. Matches iOS `maximumZoom`. */
        const val MAXIMUM = 8f

        /** A pinch that ends below this settles all the way back to 1x. Matches iOS. */
        const val SNAP_BACK_BELOW = 1.05f

        /** Float-noise floor for "actually zoomed". Matches iOS `isZoomed`. */
        const val ZOOMED_ABOVE = 1.001f

        val NONE = FeedZoom()
    }
}

/**
 * Pan bound for a center-anchored scale: the picture overflows the frame by `size*(scale-1)/2` on
 * each side, and the offset may travel exactly that far — the content edge pins to the frame edge.
 *
 * The bound falls to zero as the scale falls to 1, which is what re-centers the picture on the way
 * out of a zoom. Clamping DURING the gesture is load-bearing, not just a commit-time tidy.
 */
internal fun clampFeedPan(
    offsetX: Float,
    offsetY: Float,
    width: Float,
    height: Float,
    scale: Float,
): Pair<Float, Float> {
    // scale is always >= 1 by construction; guard anyway so a degenerate call cannot invert the
    // coerce bounds (Kotlin throws on a reversed range, which would take the feed down).
    val safeScale = maxOf(scale, 1f)
    val limitX = width * (safeScale - 1f) / 2f
    val limitY = height * (safeScale - 1f) / 2f
    return offsetX.coerceIn(-limitX, limitX) to offsetY.coerceIn(-limitY, limitY)
}

/**
 * One transform step, taking the centroid, zoom change and pan change together exactly as the
 * playback viewer does (`MediaStillViewer` / `anchoredPinchPan`).
 *
 * With a center-pivot scale followed by a translation, a content point p renders at
 * `p * scale + offset`, so holding the point under the pinch centroid fixed across a scale step
 * means `offset' = a - (a - offset) * ratio`, with the simultaneous finger drag added on top.
 * Because the step is relative, every event re-anchors on the current centroid — a re-pinch after
 * a pan cannot reuse a stale anchor and lunge sideways.
 *
 * The scale is clamped BEFORE the ratio is taken, so a pinch past the limits banks no dead travel.
 */
internal fun feedZoomAfterTransform(
    committed: FeedZoom,
    zoomChange: Float,
    centroidX: Float,
    centroidY: Float,
    panChangeX: Float,
    panChangeY: Float,
    width: Float,
    height: Float,
): FeedZoom {
    val target = (committed.scale * zoomChange).coerceIn(1f, FeedZoom.MAXIMUM)
    if (target <= 1f) return FeedZoom.NONE
    val ratio = if (committed.scale > 0f) target / committed.scale else 1f
    val anchorX = centroidX - width / 2f
    val anchorY = centroidY - height / 2f
    val (clampedX, clampedY) =
        clampFeedPan(
            anchorX - (anchorX - committed.offsetX) * ratio + panChangeX,
            anchorY - (anchorY - committed.offsetY) * ratio + panChangeY,
            width,
            height,
            target,
        )
    return FeedZoom(target, clampedX, clampedY)
}

/** Settles a released pinch: anything below [FeedZoom.SNAP_BACK_BELOW] returns to the whole frame. */
internal fun feedZoomSettled(zoom: FeedZoom): FeedZoom =
    if (zoom.scale < FeedZoom.SNAP_BACK_BELOW) FeedZoom.NONE else zoom
