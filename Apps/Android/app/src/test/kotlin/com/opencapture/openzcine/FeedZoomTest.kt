package com.opencapture.openzcine

import kotlin.math.abs
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertTrue

/**
 * Pins the feed-zoom transform against the playback viewer's (`MediaStillViewer` /
 * `anchoredPinchPan`), which is the gesture this deliberately copies.
 *
 * The defining property is the Photos contract: the content point under the fingers stays under
 * the fingers while the pinch factor changes. That is asserted directly rather than pinning
 * arithmetic, which could be wrong the same way twice.
 */
class FeedZoomTest {
    private val width = 400f
    private val height = 300f

    private fun step(
        from: FeedZoom,
        zoomChange: Float,
        centroidX: Float = width / 2f,
        centroidY: Float = height / 2f,
        panX: Float = 0f,
        panY: Float = 0f,
    ) = feedZoomAfterTransform(
        from, zoomChange, centroidX, centroidY, panX, panY, width, height,
    )

    /** Where a content point renders: centre-pivot scale, then the offset. */
    private fun project(point: Float, center: Float, zoom: FeedZoom): Float =
        center + (point - center) * zoom.scale + zoom.offsetX

    @Test
    fun `the point under the pinch stays under the pinch`() {
        val centroid = 120f
        val zoomed = step(FeedZoom.NONE, 2f, centroidX = centroid)

        // Unzoomed, the content point under the finger is the finger position itself.
        val landed = project(centroid, width / 2f, zoomed)
        assertTrue(abs(landed - centroid) < 0.01f, "anchor drifted: want $centroid, got $landed")
    }

    /** Which content point currently renders at [screenX] — the inverse of [project]. */
    private fun contentUnder(screenX: Float, center: Float, zoom: FeedZoom): Float =
        center + (screenX - center - zoom.offsetX) / zoom.scale

    @Test
    fun `a re-pinch anchors on its own centroid, not an earlier one`() {
        val center = width / 2f
        val first = step(FeedZoom.NONE, 3f, centroidX = 80f)
        // Already transformed, so the content under the new centroid is not the centroid itself.
        val held = contentUnder(300f, center, first)
        val second = step(first, 1.5f, centroidX = 300f)

        val landed = project(held, center, second)
        assertTrue(abs(landed - 300f) < 0.01f, "re-pinch lunged: want 300, got $landed")
    }

    @Test
    fun `pinching back out returns exactly to the whole frame`() {
        val inward = step(FeedZoom.NONE, 4f, centroidX = 120f)
        val outward = step(inward, 0.25f, centroidX = 120f)

        assertEquals(FeedZoom.NONE, outward)
    }

    @Test
    fun `scale is clamped before the ratio so a pinch past the ceiling banks no dead travel`() {
        val hard = step(FeedZoom.NONE, 500f)
        assertEquals(FeedZoom.MAXIMUM, hard.scale, 0.001f)

        val eased = step(hard, 0.5f)
        assertEquals(FeedZoom.MAXIMUM / 2f, eased.scale, 0.001f)
    }

    @Test
    fun `a pinch below one never inverts the picture`() {
        val out = step(FeedZoom.NONE, 0.2f)
        assertEquals(FeedZoom.NONE, out)
        assertFalse(out.isZoomed)
    }

    @Test
    fun `pan is bounded by the overhang the zoom actually creates`() {
        val zoomed = step(FeedZoom.NONE, 2f)
        val panned = step(zoomed, 1f, panX = 10_000f, panY = 10_000f)

        assertEquals(width * (2f - 1f) / 2f, panned.offsetX, 0.001f)
        assertEquals(height * (2f - 1f) / 2f, panned.offsetY, 0.001f)
    }

    /**
     * A 16:9 picture letterboxed in a 4:3 zone: vertically the picture is shorter than the frame,
     * so at 2x it overhangs by less than the frame would suggest. Bounding by the zone instead
     * would let the picture be dragged until the black bars invade.
     */
    @Test
    fun `pan bounds on the picture, not the letterboxed zone`() {
        val pictureHeight = width * 9f / 16f // 225 inside a 300-tall zone
        val zoomed =
            feedZoomAfterTransform(
                FeedZoom.NONE, 2f, width / 2f, height / 2f, 0f, 0f,
                width, height, width, pictureHeight,
            )
        val panned =
            feedZoomAfterTransform(
                zoomed, 1f, width / 2f, height / 2f, 0f, 10_000f,
                width, height, width, pictureHeight,
            )

        assertEquals((pictureHeight * 2f - height) / 2f, panned.offsetY, 0.001f)
        assertTrue(
            panned.offsetY < height * (2f - 1f) / 2f,
            "bounding by the zone would have allowed ${height * 0.5f}, got ${panned.offsetY}",
        )
    }

    /** A picture smaller than the frame at 1x cannot pan at all — the bound floors at zero. */
    @Test
    fun `a picture that does not overhang cannot be dragged`() {
        val zoomed =
            feedZoomAfterTransform(
                FeedZoom.NONE, 1.2f, width / 2f, height / 2f, 0f, 0f,
                width, height, width, height / 2f,
            )
        assertEquals(0f, zoomed.offsetY, 0.001f)
    }

    @Test
    fun `a pinch released just above one settles back to the whole frame`() {
        assertEquals(FeedZoom.NONE, feedZoomSettled(FeedZoom(scale = 1.04f, offsetX = 12f)))
        val held = FeedZoom(scale = 1.5f, offsetX = 12f)
        assertEquals(held, feedZoomSettled(held))
    }

    @Test
    fun `leaving a zoom re-centres because the bound falls with the scale`() {
        val panned = step(step(FeedZoom.NONE, 4f), 1f, panX = 10_000f)
        assertTrue(panned.offsetX > 0f)

        val out = step(panned, 0.5f)
        assertTrue(out.offsetX < panned.offsetX, "the bound did not fall with the scale")
    }
}
