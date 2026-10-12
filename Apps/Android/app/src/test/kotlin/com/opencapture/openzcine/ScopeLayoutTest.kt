package com.opencapture.openzcine

import com.opencapture.monitorui.MonitorRect
import com.opencapture.monitorui.MonitorScopePanelMath
import com.opencapture.monitorui.MonitorScopePoint
import com.opencapture.openzcine.lut.PackedStoredLut
import com.opencapture.openzcine.lut.StoredLutCategory
import com.opencapture.openzcine.lut.StoredLutSelection
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNull
import kotlin.test.assertTrue

/** Pure multi-scope selection, demand, and placement policy checks. */
class ScopeLayoutTest {
    @Test
    fun `portrait keeps the first two eligible canonical selections`() {
        val selected =
            setOf(
                ScopeKind.WAVEFORM,
                ScopeKind.PARADE,
                ScopeKind.HISTOGRAM,
                ScopeKind.TRAFFIC_LIGHTS,
            )

        val displayed = portraitDisplayedScopes(selected)
        assertEquals(listOf(ScopeKind.WAVEFORM, ScopeKind.PARADE), displayed)
        assertEquals(4, selected.size, "Fit placement must not alter the active selection")
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
    fun `false color reference mirrors inside the feed when outside is unavailable`() {
        val viewport = MonitorRect(0f, 0f, 848f, 393f)
        val feed = MonitorRect(59f, 0f, 734f, 393f)

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
        val viewport = MonitorRect(0f, 52f, 800f, 226f)
        val feed = MonitorRect(81f, 0f, 640f, 360f)

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
    fun `movable panels snap to the iOS four point grid`() {
        assertEquals(4f, MonitorScopePanelMath.POSITION_GRID)
        assertEquals(
            MonitorScopePoint(192f, 124f),
            MonitorScopePanelMath.snap(MonitorScopePoint(190.5f, 125f)),
        )
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
