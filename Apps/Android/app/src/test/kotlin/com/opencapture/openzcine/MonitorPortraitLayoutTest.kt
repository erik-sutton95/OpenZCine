package com.opencapture.openzcine

import com.opencapture.openzcine.bridge.ZoneFrame
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertTrue

/**
 * Twin of the fill-assist-rail cases in `Tests/OpenZCineCoreTests/MonitorPortraitLayoutTests.swift`.
 * Identical numbers on purpose: the rail cannot sit in one place on iPhone and another here.
 */
class MonitorPortraitLayoutTest {
    private val feed = ZoneFrame(0f, 100f, 390f, 500f)

    @Test
    fun `the expanded rail ends above the capture strip`() {
        val rail =
            MonitorPortraitLayout.fillAssistRail(feed, captureStripTop = 540f, expanded = true)

        assertEquals(10f, rail.x)
        assertEquals(110f, rail.y)
        assertEquals(MonitorPortraitLayout.ASSIST_RAIL_EXPANDED_WIDTH, rail.width)
        // 540 (strip top) − 110 (rail top) − 10 (margin)
        assertEquals(420f, rail.height)
        assertTrue(rail.y + rail.height <= 540f)
    }

    @Test
    fun `with no capture strip the rail runs to the feed bottom`() {
        val rail =
            MonitorPortraitLayout.fillAssistRail(feed, captureStripTop = null, expanded = true)

        assertEquals(480f, rail.height)
        assertEquals(590f, rail.y + rail.height)
    }

    @Test
    fun `the collapsed pill clears the capture strip`() {
        val rail =
            MonitorPortraitLayout.fillAssistRail(feed, captureStripTop = 540f, expanded = false)

        assertEquals(MonitorPortraitLayout.ASSIST_RAIL_COLLAPSED_SIZE, rail.width)
        assertEquals(MonitorPortraitLayout.ASSIST_RAIL_COLLAPSED_SIZE, rail.height)
        // 540 − 44 − 10
        assertEquals(486f, rail.y)
    }

    /**
     * A capture strip reported outside the feed is not evidence about where the rail must stop.
     * This is exactly where the two shells had drifted apart.
     */
    @Test
    fun `a capture strip outside the feed cannot produce a negative rail`() {
        val above = MonitorPortraitLayout.fillAssistRail(feed, captureStripTop = 20f, expanded = true)
        assertEquals(0f, above.height)
        assertTrue(above.y >= feed.y)

        val below =
            MonitorPortraitLayout.fillAssistRail(feed, captureStripTop = 9_000f, expanded = true)
        assertTrue(below.y + below.height <= feed.y + feed.height)
    }
}
