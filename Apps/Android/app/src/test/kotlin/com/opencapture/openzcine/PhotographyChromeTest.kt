package com.opencapture.openzcine

import com.opencapture.openzcine.bridge.ZoneFrame
import com.opencapture.openzcine.settings.MonitorDisplayMode
import kotlin.test.Test
import kotlin.test.assertEquals

/** JVM coverage for photography chrome policy helpers. */
class PhotographyChromeTest {
    private val lock = ZoneFrame(x = 16f, y = 12f, width = 40f, height = 40f)
    private val band = ZoneFrame(x = 59f, y = 320f, width = 700f, height = 58f)

    @Test
    fun `photo assist rail hugs the lock row and clears the widest left chrome`() {
        // Battery stack reaches further right than the lock button.
        val frame =
            photographyAssistRailFrame(
                lock = lock,
                batteryTrailing = 78f,
                assistBand = band,
                measuredCaptureBar = null,
                expanded = true,
            )

        assertEquals(78f + 12f, frame.x)
        assertEquals(lock.y, frame.y)
        assertEquals(ASSIST_RAIL_EXPANDED_WIDTH_DP, frame.width)
        // No strip in the lane: the rail runs to the band's bottom edge.
        assertEquals(band.y + band.height - lock.y, frame.height)
    }

    @Test
    fun `photo assist rail stops above the band when the capture strip enters its lane`() {
        val laneTrailing = 78f + 12f + ASSIST_RAIL_EXPANDED_WIDTH_DP
        val strip = ZoneFrame(x = laneTrailing + 10f, y = 322f, width = 500f, height = 54f)

        val frame =
            photographyAssistRailFrame(
                lock = lock,
                batteryTrailing = 78f,
                assistBand = band,
                measuredCaptureBar = strip,
                expanded = true,
            )

        assertEquals(band.y - 10f - lock.y, frame.height)
    }

    @Test
    fun `collapsed photo rail pill centre-aligns on the lock button`() {
        val frame =
            photographyAssistRailFrame(
                lock = lock,
                batteryTrailing = null,
                assistBand = band,
                measuredCaptureBar = null,
                expanded = false,
            )

        assertEquals(ASSIST_RAIL_COLLAPSED_PILL_DP, frame.width)
        assertEquals(ASSIST_RAIL_COLLAPSED_PILL_DP, frame.height)
        // Vertically centred on the lock row.
        assertEquals(
            lock.y + (lock.height - ASSIST_RAIL_COLLAPSED_PILL_DP) / 2f,
            frame.y,
        )
        // Horizontally centred in the expanded rail's lane.
        val laneCentre = lock.x + lock.width + 12f + ASSIST_RAIL_EXPANDED_WIDTH_DP / 2f
        assertEquals(laneCentre - ASSIST_RAIL_COLLAPSED_PILL_DP / 2f, frame.x)
    }
    @Test
    fun `profile tile compacts the built-in picture controls`() {
        assertEquals("SD", compactPictureControlLabel("Standard"))
        assertEquals("NL", compactPictureControlLabel("Neutral"))
        assertEquals("MC", compactPictureControlLabel("Monochrome"))
        assertEquals("DTM", compactPictureControlLabel("Deep Tone Mono"))
        assertEquals("RTP", compactPictureControlLabel("Rich Tone Portrait"))
        // Auto and the creative names show whole; unknown stays untouched.
        assertEquals("Auto", compactPictureControlLabel("Auto"))
        assertEquals("Denim", compactPictureControlLabel("Denim"))
        assertEquals(null, compactPictureControlLabel(null))
    }

    @Test
    fun `photography filters command out of the DISP order and video keeps it`() {
        val order =
            listOf(
                MonitorDisplayMode.LIVE,
                MonitorDisplayMode.CLEAN,
                MonitorDisplayMode.COMMAND,
            )

        assertEquals(order, photographyDisplayModeOrder(order, photography = false))
        assertEquals(
            listOf(MonitorDisplayMode.LIVE, MonitorDisplayMode.CLEAN),
            photographyDisplayModeOrder(order, photography = true),
        )
        // A COMMAND-only preference recovers to the always-safe live mode.
        assertEquals(
            listOf(MonitorDisplayMode.LIVE),
            photographyDisplayModeOrder(
                listOf(MonitorDisplayMode.COMMAND),
                photography = true,
            ),
        )
    }

    @Test
    fun `next display mode wraps the effective order and recovers stale modes`() {
        val order = listOf(MonitorDisplayMode.LIVE, MonitorDisplayMode.CLEAN)

        assertEquals(
            MonitorDisplayMode.CLEAN,
            nextDisplayModeInOrder(order, MonitorDisplayMode.LIVE),
        )
        assertEquals(
            MonitorDisplayMode.LIVE,
            nextDisplayModeInOrder(order, MonitorDisplayMode.CLEAN),
        )
        // A mode filtered away mid-session (photo flip while in COMMAND)
        // recovers to the order's first entry.
        assertEquals(
            MonitorDisplayMode.LIVE,
            nextDisplayModeInOrder(order, MonitorDisplayMode.COMMAND),
        )
    }
}
