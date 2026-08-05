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
 * The live transform for an in-flight pinch, derived fresh from the committed state.
 *
 * One exact formula instead of anchor bookkeeping: with a center-anchored scale, keeping the
 * content point under the fingers pinned while the factor changes is
 * `O' = (f - c) - ((f - c) - O) * m` with `s' = s * m` — for pinching in AND out, so both
 * directions track the fingers at the same rate. The factor is clamped BEFORE it is applied, so
 * pinching past the limits accumulates no dead travel to unwind.
 *
 * [startX]/[startY] are the pinch's own start centroid, so every pinch pivots on where it began —
 * re-pinching after a pan must not reuse an earlier pinch's stale anchor or the picture lunges.
 */
internal fun feedZoomAfterPinch(
    committed: FeedZoom,
    pinchFactor: Float,
    startX: Float,
    startY: Float,
    width: Float,
    height: Float,
): FeedZoom {
    val target = (committed.scale * pinchFactor).coerceIn(1f, FeedZoom.MAXIMUM)
    val factor = if (committed.scale > 0f) target / committed.scale else 1f
    val centerX = width / 2f
    val centerY = height / 2f
    val offsetX = (startX - centerX) - ((startX - centerX) - committed.offsetX) * factor
    val offsetY = (startY - centerY) - ((startY - centerY) - committed.offsetY) * factor
    val (clampedX, clampedY) = clampFeedPan(offsetX, offsetY, width, height, target)
    return FeedZoom(target, clampedX, clampedY)
}

/** Applies a pan translation. A drag while unzoomed is the DISP swipe's, not the pan's. */
internal fun feedZoomAfterPan(
    committed: FeedZoom,
    translationX: Float,
    translationY: Float,
    width: Float,
    height: Float,
): FeedZoom {
    if (!committed.isZoomed) return committed
    val (clampedX, clampedY) =
        clampFeedPan(
            committed.offsetX + translationX,
            committed.offsetY + translationY,
            width,
            height,
            committed.scale,
        )
    return committed.copy(offsetX = clampedX, offsetY = clampedY)
}

/** Settles a released pinch: anything below [FeedZoom.SNAP_BACK_BELOW] returns to the whole frame. */
internal fun feedZoomSettled(zoom: FeedZoom): FeedZoom =
    if (zoom.scale < FeedZoom.SNAP_BACK_BELOW) FeedZoom.NONE else zoom
