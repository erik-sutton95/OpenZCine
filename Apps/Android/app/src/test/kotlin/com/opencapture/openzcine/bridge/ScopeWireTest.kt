package com.opencapture.openzcine.bridge

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith

/** Pure-JVM check of the scope wire decoding against hand-built payloads. */
class ScopeWireTest {
    @Test
    fun parsesAnchors() {
        val flat =
            floatArrayOf(0.05f, 0.47f, 0.95f) +
                FloatArray(12) { (it - 6) / 24f } // 6 (cb, cr) pairs
        val anchors = ScopeAnchors.parse(flat)
        assertEquals(0.05f, anchors.crushLine)
        assertEquals(0.47f, anchors.midGray)
        assertEquals(0.95f, anchors.clipLine)
        assertEquals(6, anchors.vectorTargets.size)
        assertEquals(Pair(-6 / 24f, -5 / 24f), anchors.vectorTargets[0])
    }

    @Test
    fun rejectsTornAnchors() {
        assertFailsWith<IllegalArgumentException> { ScopeAnchors.parse(FloatArray(4)) }
    }

    @Test
    fun parsesTraces() {
        // Two points, then 4 × 256 histogram bins tagged by channel.
        val points =
            floatArrayOf(
                0.0f, 0.1f, 0.2f, 0.3f, 0.4f,
                1.0f, 0.5f, 0.6f, 0.7f, 0.8f,
            )
        val histograms = FloatArray(4 * 256) { (it / 256).toFloat() }
        val traces = ScopeTraces.parse(floatArrayOf(2f) + points + histograms)
        assertEquals(2, traces.pointCount)
        assertEquals(0.5f, traces.points[1 * ScopeTraces.POINT_STRIDE + 1]) // point 1 luma
        assertEquals(0f, traces.histogramLuma[0])
        assertEquals(1f, traces.histogramRed[0])
        assertEquals(2f, traces.histogramGreen[255])
        assertEquals(3f, traces.histogramBlue[128])
    }

    @Test
    fun rejectsTornTraces() {
        assertFailsWith<IllegalArgumentException> { ScopeTraces.parse(floatArrayOf(3f, 0f)) }
        assertFailsWith<IllegalArgumentException> { ScopeTraces.parse(FloatArray(0)) }
    }
}
