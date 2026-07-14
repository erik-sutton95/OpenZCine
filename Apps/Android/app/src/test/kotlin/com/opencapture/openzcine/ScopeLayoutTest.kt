package com.opencapture.openzcine

import com.opencapture.openzcine.bridge.ZoneFrame
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
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
    fun `sampler demand avoids trace or vector work unless a visible scope needs it`() {
        val lights = scopeSamplingDemand(setOf(ScopeKind.TRAFFIC_LIGHTS))
        assertTrue(lights.traces)
        assertTrue(lights.trafficLights)
        assertFalse(lights.vector)
        assertFalse(lights.pointTrace)

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
    }
}
