package com.opencapture.openzcine

import kotlin.math.abs
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertTrue

/**
 * Pins the feed-zoom transform against the iOS twin in `ios/Runner/MonitorExperience.swift`.
 * The defining property is the Photos contract: the content point under the fingers stays under
 * the fingers while the pinch factor changes.
 */
class FeedZoomTest {
    private val width = 400f
    private val height = 300f

    /** Where a content point lands after a center-anchored scale then an offset. */
    private fun project(point: Float, center: Float, zoom: FeedZoom, offset: Float): Float =
        center + (point - center) * zoom.scale + offset

    @Test
    fun `the point under the pinch stays under the pinch while zooming in`() {
        val start = 120f
        val zoomed = feedZoomAfterPinch(FeedZoom.NONE, 2f, start, 150f, width, height)

        // Unzoomed, the content point under the finger is the finger position itself.
        val landed = project(start, width / 2f, zoomed, zoomed.offsetX)
        assertTrue(
            abs(landed - start) < 0.01f,
            "pinch anchor drifted: expected $start, got $landed",
        )
    }

    @Test
    fun `pinching back out tracks the fingers at the same rate`() {
        val start = 120f
        val inward = feedZoomAfterPinch(FeedZoom.NONE, 4f, start, 150f, width, height)
        // A pinch of 1/4 from a 4x committed state returns exactly to the whole frame.
        val outward = feedZoomAfterPinch(inward, 0.25f, start, 150f, width, height)

        assertEquals(1f, outward.scale, 0.001f)
        assertEquals(0f, outward.offsetX, 0.001f)
        assertEquals(0f, outward.offsetY, 0.001f)
    }

    @Test
    fun `scale is clamped before it is applied so pinching past the limit banks no dead travel`() {
        val hard = feedZoomAfterPinch(FeedZoom.NONE, 500f, 200f, 150f, width, height)
        assertEquals(FeedZoom.MAXIMUM, hard.scale, 0.001f)

        // One notch back from the ceiling must move immediately, not unwind phantom travel.
        val eased = feedZoomAfterPinch(hard, 0.5f, 200f, 150f, width, height)
        assertEquals(FeedZoom.MAXIMUM / 2f, eased.scale, 0.001f)
    }

    @Test
    fun `a pinch below one never inverts the picture`() {
        val out = feedZoomAfterPinch(FeedZoom.NONE, 0.2f, 200f, 150f, width, height)
        assertEquals(1f, out.scale, 0.001f)
        assertFalse(out.isZoomed)
    }

    @Test
    fun `pan is bounded by the overhang the zoom actually creates`() {
        val zoomed = FeedZoom(scale = 2f)
        val panned = feedZoomAfterPan(zoomed, 10_000f, 10_000f, width, height)

        // At 2x the picture overhangs by size*(scale-1)/2 on each side.
        assertEquals(width * (2f - 1f) / 2f, panned.offsetX, 0.001f)
        assertEquals(height * (2f - 1f) / 2f, panned.offsetY, 0.001f)
    }

    @Test
    fun `an unzoomed drag is not a pan — it belongs to the DISP swipe`() {
        val panned = feedZoomAfterPan(FeedZoom.NONE, 50f, 50f, width, height)
        assertEquals(FeedZoom.NONE, panned)
    }

    @Test
    fun `a pinch released just above one settles back to the whole frame`() {
        assertEquals(FeedZoom.NONE, feedZoomSettled(FeedZoom(scale = 1.04f, offsetX = 12f)))
        val held = FeedZoom(scale = 1.5f, offsetX = 12f)
        assertEquals(held, feedZoomSettled(held))
    }

    @Test
    fun `leaving a zoom re-centres because the bound falls with the scale`() {
        val panned = feedZoomAfterPan(FeedZoom(scale = 4f), 10_000f, 0f, width, height)
        assertTrue(panned.offsetX > 0f)

        // Pinching all the way back out drags the offset to zero through the clamp alone.
        val out = feedZoomAfterPinch(panned, 0.25f, 200f, 150f, width, height)
        assertEquals(1f, out.scale, 0.001f)
        assertEquals(0f, out.offsetX, 0.001f)
    }
}
