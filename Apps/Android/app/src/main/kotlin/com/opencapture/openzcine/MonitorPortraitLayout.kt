package com.opencapture.openzcine

import com.opencapture.openzcine.bridge.ZoneFrame
import kotlin.math.max
import kotlin.math.min

/**
 * Portrait monitor geometry that both shells must agree on.
 *
 * Twin of the shared core's `MonitorPortraitLayout`; both are tested against the same numbers, so
 * the rail can never sit in one place on iPhone and another on Android. Change one, change both.
 */
public object MonitorPortraitLayout {
    /** Width of the assist rail when the operator expands it. */
    public const val ASSIST_RAIL_EXPANDED_WIDTH: Float = 60f

    /** The collapsed rail's pill, and the margin it keeps from every edge it touches. */
    public const val ASSIST_RAIL_COLLAPSED_SIZE: Float = 44f
    public const val ASSIST_RAIL_EDGE_INSET: Float = 10f

    /**
     * Where the portrait FILL-mode assist rail sits: down the feed's leading edge, ending above
     * the capture strip rather than under it.
     *
     * This arithmetic existed twice — inline in the iOS portrait overlay and again here — and the
     * two had already drifted. Android clamped the capture strip's top into the feed before
     * measuring from it; iOS did not, so a strip reported above the feed (a transient during a
     * rotation or a chrome remount) gave iOS a negative span where Android gave a sane one. The
     * collapsed pill was worse: iOS placed it from the FEED's bottom minus the strip height, and
     * this from the STRIP's top. Those agree only while the strip is flush with the feed — the
     * common case, and exactly why nobody noticed.
     *
     * @param captureStripTop the y of the capture strip when that chrome mounts; null when the
     *   rail may run to the feed's bottom edge.
     */
    public fun fillAssistRail(
        feed: ZoneFrame,
        captureStripTop: Float?,
        expanded: Boolean,
    ): ZoneFrame {
        val edge = ASSIST_RAIL_EDGE_INSET
        val feedBottom = feed.y + feed.height
        // A strip outside the feed says nothing usable about where the rail must stop.
        val railBottom = captureStripTop?.let { min(max(it, feed.y), feedBottom) } ?: feedBottom
        val top = feed.y + edge
        val width = if (expanded) ASSIST_RAIL_EXPANDED_WIDTH else ASSIST_RAIL_COLLAPSED_SIZE
        val height =
            if (expanded) max(0f, railBottom - top - edge) else ASSIST_RAIL_COLLAPSED_SIZE
        val y = if (expanded) top else max(top, railBottom - height - edge)
        return ZoneFrame(feed.x + edge, y, width, height)
    }
}
