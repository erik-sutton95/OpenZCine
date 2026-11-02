package com.opencapture.openzcine

import com.opencapture.opencine.media.ScopeAssistBundle
import kotlin.test.Test
import kotlin.test.assertTrue

/** VECTOR reads the camera signal: what playback walks for it. */
class ScopeVectorSignalTest {
    private fun mapping(curve: Int) = ExposureAssistMapping(curve, 0f, 100f, 255f)

    @Test
    fun `playback walks points only for a selected trace or vectorscope`() {
        val stills = mapping(ExposureCurveOrdinals.SRGB)
        fun playback(vararg selected: ScopeKind) = NikonPlaybackScopeConfiguration(
            ScopeTickInputs(selected.toSet(), false, 0.0, stills.transfer, stills.clipByte,
                ScopeVectorLutRequest(stills.curveOrdinal), 84_000_000L),
            look = null)
        val frame = colourFrame()

        assertTrue(playback(ScopeKind.HISTOGRAM).samples(frame).points.isEmpty())

        // A vectorscope without a look (identity) still plots its chroma.
        val vector = playback(ScopeKind.VECTORSCOPE)
        val bundle = vector.bundle(vector.samples(frame), ScopeAssistBundle.EMPTY)
        assertTrue(bundle.vectorscopePoints.isNotEmpty())
    }

    /** A saturated red, green and blue frame: every scope has signal to plot. */
    private fun colourFrame(width: Int = 48, height: Int = 32): ReducedScopeFrame {
        val rgba = ByteArray(width * height * 4)
        for (y in 0 until height) for (x in 0 until width) {
            val offset = (y * width + x) * 4
            rgba[offset + x * 3 / width] = 0xC0.toByte()
            rgba[offset + 3] = 0xFF.toByte()
        }
        return ReducedScopeFrame(rgba, width, height, width * 4)
    }
}
