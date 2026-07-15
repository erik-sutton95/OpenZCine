package com.opencapture.openzcine

import com.opencapture.openzcine.bridge.ZoneFrame
import com.opencapture.openzcine.lut.PackedStoredLut
import com.opencapture.openzcine.lut.StoredLutCategory
import com.opencapture.openzcine.lut.StoredLutSelection
import com.opencapture.openzcine.settings.ScopeAssistConfiguration
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNull
import kotlin.test.assertTrue

/** Pure multi-scope selection, demand, and placement policy checks. */
class ScopeLayoutTest {
    @Test
    fun `portrait keeps two newest selections in canonical presentation order`() {
        val selected =
            setOf(
                ScopeKind.WAVEFORM,
                ScopeKind.PARADE,
                ScopeKind.HISTOGRAM,
                ScopeKind.TRAFFIC_LIGHTS,
            )

        val displayed =
            portraitDisplayedScopes(
                selected,
                listOf(
                    ScopeKind.WAVEFORM,
                    ScopeKind.PARADE,
                    ScopeKind.HISTOGRAM,
                    ScopeKind.TRAFFIC_LIGHTS,
                ),
            )

        assertEquals(listOf(ScopeKind.HISTOGRAM, ScopeKind.TRAFFIC_LIGHTS), displayed)
    }

    @Test
    fun `portrait migration without order falls back to canonical prefix`() {
        assertEquals(
            listOf(ScopeKind.WAVEFORM, ScopeKind.PARADE),
            portraitDisplayedScopes(
                setOf(ScopeKind.WAVEFORM, ScopeKind.PARADE, ScopeKind.HISTOGRAM),
                emptyList(),
            ),
        )
    }

    @Test
    fun `portrait fill keeps every selected scope floating in canonical order`() {
        val selected =
            setOf(
                ScopeKind.HISTOGRAM,
                ScopeKind.WAVEFORM,
                ScopeKind.VECTORSCOPE,
            )

        assertEquals(
            listOf(ScopeKind.WAVEFORM, ScopeKind.HISTOGRAM, ScopeKind.VECTORSCOPE),
            displayedScopeKinds(
                selectedScopes = selected,
                portraitScopes = listOf(ScopeKind.HISTOGRAM),
                isPortrait = true,
                portraitFloating = true,
            ),
        )
        assertEquals(
            listOf(ScopeKind.HISTOGRAM),
            displayedScopeKinds(
                selectedScopes = selected,
                portraitScopes = listOf(ScopeKind.HISTOGRAM),
                isPortrait = true,
                portraitFloating = false,
            ),
        )
    }

    @Test
    fun `sampler demand avoids trace or vector work unless a visible scope needs it`() {
        val lights = scopeSamplingDemand(setOf(ScopeKind.TRAFFIC_LIGHTS))
        assertTrue(lights.traces)
        assertTrue(lights.trafficLights)
        assertFalse(lights.vector)
        assertFalse(lights.pointTrace)

        val histogramWithEdgeBlocks =
            scopeSamplingDemand(setOf(ScopeKind.HISTOGRAM), histogramTrafficLightsEnabled = true)
        assertTrue(histogramWithEdgeBlocks.traces)
        assertTrue(histogramWithEdgeBlocks.histogram)
        assertTrue(histogramWithEdgeBlocks.trafficLights)

        val histogramWithoutEdgeBlocks =
            scopeSamplingDemand(setOf(ScopeKind.HISTOGRAM), histogramTrafficLightsEnabled = false)
        assertTrue(histogramWithoutEdgeBlocks.traces)
        assertTrue(histogramWithoutEdgeBlocks.histogram)
        assertFalse(histogramWithoutEdgeBlocks.trafficLights)

        val vector = scopeSamplingDemand(setOf(ScopeKind.VECTORSCOPE))
        assertFalse(vector.traces)
        assertTrue(vector.vector)

        val combined = scopeSamplingDemand(setOf(ScopeKind.WAVEFORM, ScopeKind.VECTORSCOPE))
        assertTrue(combined.traces)
        assertTrue(combined.pointTrace)
        assertTrue(combined.vector)
    }

    @Test
    fun `debug tokens support old single and ordered concurrent selections`() {
        assertEquals(listOf(ScopeKind.WAVEFORM), ScopeKind.parseTokens("wave"))
        assertEquals(
            listOf(ScopeKind.WAVEFORM, ScopeKind.TRAFFIC_LIGHTS, ScopeKind.HISTOGRAM),
            ScopeKind.parseTokens("wave,lights,wave,histo,unknown"),
        )
    }

    @Test
    fun `floating defaults stay inside bounds and keep traffic lights distinct`() {
        val viewport = ZoneFrame(0f, 0f, 848f, 393f)
        val feed = ZoneFrame(59f, 0f, 734f, 393f)
        val info = ZoneFrame(100f, 8f, 500f, 46f)
        val wave = floatingScopeFrame(ScopeKind.WAVEFORM, feed, info, viewport)
        val parade = floatingScopeFrame(ScopeKind.PARADE, feed, info, viewport)
        val vector = floatingScopeFrame(ScopeKind.VECTORSCOPE, feed, info, viewport)
        val lights = floatingScopeFrame(ScopeKind.TRAFFIC_LIGHTS, feed, info, viewport)
        val bottomEdge =
            viewport.y + viewport.height - 14f - LiveDesign.CONTROL_HEIGHT_DP - 10f

        ScopeKind.canonical.forEach { kind ->
            val frame = floatingScopeFrame(kind, feed, info, viewport)
            assertTrue(frame.x >= viewport.x)
            assertTrue(frame.y >= viewport.y)
            assertTrue(frame.x + frame.width <= viewport.x + viewport.width)
            assertTrue(frame.y + frame.height <= viewport.y + viewport.height)
        }
        assertTrue(lights.y + lights.height <= bottomEdge)
        assertTrue(wave.x != lights.x || wave.y != lights.y)
        assertEquals(parade.x + parade.width, vector.x + vector.width)
        assertEquals(parade.y, vector.y)
    }

    @Test
    fun `false color reference mirrors inside the feed when outside is unavailable`() {
        val viewport = ZoneFrame(0f, 0f, 848f, 393f)
        val feed = ZoneFrame(59f, 0f, 734f, 393f)

        val frame = falseColorReferenceDefaultFrame(feed, viewport)

        assertEquals(59f, frame.x)
        assertEquals(264f, frame.width)
        assertEquals(52f, frame.height)
        assertTrue(frame.y >= viewport.y)
        assertTrue(frame.y + frame.height <= viewport.y + viewport.height)
        assertTrue(
            frame.y + frame.height <=
                viewport.y + viewport.height - 14f - LiveDesign.CONTROL_HEIGHT_DP,
        )
    }

    @Test
    fun `playback reference uses its already chrome-safe viewport directly`() {
        val viewport = ZoneFrame(0f, 52f, 800f, 226f)
        val feed = ZoneFrame(81f, 0f, 640f, 360f)

        val frame =
            falseColorReferenceDefaultFrame(
                feed,
                viewport,
                bottomChromeClearance = 0f,
            )

        assertEquals(216f, frame.y)
        assertEquals(268f, frame.y + frame.height)

        val trailing =
            falseColorReferenceDefaultFrame(
                feed,
                viewport,
                bottomChromeClearance = 0f,
                horizontalFraction = 1f,
            )
        assertEquals(feed.x + feed.width - trailing.width, trailing.x)
    }

    @Test
    fun `false color panel movement snaps to the iOS four point grid`() {
        assertEquals(
            ZoneFrame(60f, 100f, 264f, 52f),
            snapFalseColorReferenceFrame(ZoneFrame(59f, 101f, 264f, 52f)),
        )
    }

    @Test
    fun `operator scale changes the physical landscape footprint`() {
        val configuration =
            ScopeAssistConfiguration(
                waveformScale = 1.6f,
                histogramScale = 0.6f,
            )

        assertEquals(400f to 244.8f, scopePanelSize(ScopeKind.WAVEFORM, configuration))
        assertEquals(150f to 46.2f, scopePanelSize(ScopeKind.HISTOGRAM, configuration))
        assertEquals(
            1.6f,
            ScopeAssistConfiguration().withScale(ScopeKind.VECTORSCOPE, 2f).vectorscopeScale,
        )
        assertEquals(
            ZoneFrame(60f, 100f, 190f, 190f),
            snapScopeFrame(ZoneFrame(59f, 101f, 190f, 190f)),
        )
    }

    @Test
    fun `boosted trace alpha saturates instead of wrapping`() {
        assertEquals(255, scopeTraceAlpha(colorAlpha = 0.8f, opacity = 2f))
        assertEquals(0, scopeTraceAlpha(colorAlpha = 0.8f, opacity = -1f))
        assertEquals(listOf(1f), scopeTracePassOpacities(1f))
        assertEquals(listOf(1f, 0.5f), scopeTracePassOpacities(1.5f))
        assertEquals(listOf(1f, 1f), scopeTracePassOpacities(2f))
    }

    @Test
    fun `vectorscope bitmap wire accepts only the exact core payload`() {
        assertTrue(isValidVectorPayloadSize(2 * 128 * 128 * 4))
        assertFalse(isValidVectorPayloadSize(0))
        assertFalse(isValidVectorPayloadSize(3))
        assertFalse(isValidVectorPayloadSize(128 * 128 * 4))
        assertFalse(isValidVectorPayloadSize(128 * 128 * 4 + 4))
    }

    @Test
    fun `vectorscope LUT request follows active built in and stored selections`() {
        assertEquals(1, scopeVectorLutRequest(null, curveOrdinal = 1) { null }?.lookOrdinal)
        assertEquals(
            2,
            scopeVectorLutRequest(
                FeedLutSelection.BuiltIn(FeedLut.MONO),
                curveOrdinal = 0,
            ) { null }?.lookOrdinal,
        )
        val stored =
            StoredLutSelection.generated(
                StoredLutCategory.CUSTOM,
                "look-123456789abc.cube",
            )
        assertNull(
            scopeVectorLutRequest(
                FeedLutSelection.Stored(stored),
                curveOrdinal = 0,
            ) { null },
        )
        val packed = PackedStoredLut(2, ByteArray(2 * 2 * 2 * 4))
        val request =
            requireNotNull(
                scopeVectorLutRequest(FeedLutSelection.Stored(stored), curveOrdinal = 0) { packed },
            )

        assertEquals(-1, request.lookOrdinal)
        assertEquals(2, request.cubeSize)
        assertTrue(request.packedRgba === packed.rgba)
    }
}
