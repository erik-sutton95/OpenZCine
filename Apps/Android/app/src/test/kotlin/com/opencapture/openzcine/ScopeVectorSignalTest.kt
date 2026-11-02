package com.opencapture.openzcine

import com.opencapture.opencine.media.ScopeAssistBundle
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNull
import kotlin.test.assertTrue

/** VECTOR reads the camera signal: the look a curve maps through and what playback walks. */
class ScopeVectorSignalTest {
    private fun mapping(curve: Int) = ExposureAssistMapping(curve, 0f, 100f, 255f)

    @Test
    fun `a log camera maps through its built-in look and a stills curve plots as it is`() {
        assertEquals(FeedLut.LOG3G10_709,
            ScopeVectorLutRequest(mapping(ExposureCurveOrdinals.RED_LOG3G10).transfer).look)
        assertEquals(FeedLut.NLOG_709,
            ScopeVectorLutRequest(mapping(ExposureCurveOrdinals.NIKON_NLOG).transfer).look)
        // Stills previews are display referred (iOS `NikonScopeLook.display` returns nil): never
        // the Mono or R3D NE Monitor look that shares their ordinal on the look wire.
        assertNull(ScopeVectorLutRequest(mapping(ExposureCurveOrdinals.SRGB).transfer).look)
        assertNull(ScopeVectorLutRequest(mapping(ExposureCurveOrdinals.HLG).transfer).look)
    }

    @Test
    fun `playback walks points only for a selected trace or vectorscope`() {
        val stills = mapping(ExposureCurveOrdinals.SRGB)
        fun playback(vararg selected: ScopeKind) = NikonPlaybackScopeConfiguration(
            ScopeTickInputs(selected.toSet(), false, 0.0, stills.transfer, stills.clipByte,
                ScopeVectorLutRequest(stills.transfer), 84_000_000L),
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
