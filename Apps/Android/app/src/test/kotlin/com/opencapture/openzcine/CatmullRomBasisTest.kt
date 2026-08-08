package com.opencapture.openzcine

import kotlin.math.abs
import kotlin.test.Test
import kotlin.test.assertTrue

/**
 * Certifies the Catmull-Rom basis transcribed into `playback_feed_fragment_es2.glsl`
 * (`sampleSourceReconstructed`), which upscales a magnified live feed.
 *
 * GLSL cannot be exercised from a JVM unit test, so the weights are re-derived here in the same
 * form the shader uses and checked against the properties that make the filter correct. Getting
 * these wrong is invisible on a screenshot — it shows up as a slow level drift or edge ringing
 * that reads as "the feed looks a bit off" long after the change.
 */
class CatmullRomBasisTest {
    /** Exactly the shader's four weight expressions, for a fractional position within a cell. */
    private fun weights(f: Double): DoubleArray =
        doubleArrayOf(
            f * (-0.5 + f * (1.0 - 0.5 * f)),
            1.0 + f * f * (-2.5 + 1.5 * f),
            f * (0.5 + f * (2.0 - 1.5 * f)),
            f * f * (-0.5 + 0.5 * f),
        )

    private fun samples(steps: Int = 257) = (0 until steps).map { it.toDouble() / (steps - 1) }

    /**
     * Partition of unity. If the weights did not sum to 1, a flat grey area would change level
     * with sub-pixel position — the picture would breathe as the feed or the zoom moved.
     */
    @Test
    fun `weights sum to one everywhere in the cell`() {
        for (f in samples()) {
            val sum = weights(f).sum()
            assertTrue(abs(sum - 1.0) < 1e-9, "weights at f=$f summed to $sum")
        }
    }

    /**
     * Interpolating, not approximating: landing exactly on a source sample must return that
     * sample untouched. This is what separates Catmull-Rom from a B-spline, which would blur
     * every source pixel and undo the point of the change.
     */
    @Test
    fun `landing on a source sample returns it exactly`() {
        val atSample = weights(0.0)
        assertTrue(abs(atSample[1] - 1.0) < 1e-12, "centre weight was ${atSample[1]}")
        assertTrue(abs(atSample[0]) < 1e-12 && abs(atSample[2]) < 1e-12 && abs(atSample[3]) < 1e-12)

        val atNext = weights(1.0)
        assertTrue(abs(atNext[2] - 1.0) < 1e-12, "neighbour weight was ${atNext[2]}")
        assertTrue(abs(atNext[0]) < 1e-12 && abs(atNext[1]) < 1e-12 && abs(atNext[3]) < 1e-12)
    }

    /**
     * The inner pair is collapsed into ONE bilinear fetch at its weighted centroid, so `w1 + w2`
     * is a divisor in the shader. It must never approach zero.
     */
    @Test
    fun `the inner pair weight never approaches zero`() {
        for (f in samples()) {
            val w = weights(f)
            val inner = w[1] + w[2]
            assertTrue(inner > 0.5, "inner pair fell to $inner at f=$f")
        }
    }

    /**
     * The bilinear-pair trick is only exact if the fetch sits at the pair's centroid, which must
     * stay inside the pair's own span or the sample lands on the wrong texels.
     */
    @Test
    fun `the collapsed fetch stays between the two samples it replaces`() {
        for (f in samples()) {
            val w = weights(f)
            val offset = w[2] / (w[1] + w[2])
            assertTrue(offset >= -1e-12 && offset <= 1.0 + 1e-12, "offset $offset at f=$f")
        }
    }

    /**
     * The sharpening lobes are what make this resolve edges rather than ramp them, and they are
     * also what makes it overshoot — which is why the shader clamps the undershoot.
     */
    @Test
    fun `the outer lobes are negative inside the cell`() {
        val w = weights(0.5)
        assertTrue(w[0] < 0.0 && w[3] < 0.0, "expected negative lobes, got ${w[0]} and ${w[3]}")
    }
}
