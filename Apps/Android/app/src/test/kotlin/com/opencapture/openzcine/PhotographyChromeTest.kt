package com.opencapture.openzcine

import com.opencapture.openzcine.bridge.ZoneFrame
import com.opencapture.openzcine.settings.MonitorDisplayMode
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertTrue

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
    fun `photo feed spans the full height between the reserved side lanes`() {
        val viewport = ZoneFrame(0f, 0f, 914f, 384f)
        val cinema = ZoneFrame(59f, 0f, 683f, 384f)
        val railLane = 56f + 12f + ASSIST_RAIL_EXPANDED_WIDTH_DP + 8f // 136
        val rightRail = 914f - 70f

        val fx =
            photographyFeedFrame(
                cinemaFeed = cinema,
                viewport = viewport,
                imageArea = "FX",
                leadingLaneTrailing = railLane,
                trailingLaneLeading = rightRail,
            )
        // 3:2 at the FULL viewport height (the capture band's glass overlays
        // the image bottom, like iOS), letterboxed between the SIDE lanes.
        assertEquals(3f / 2f, fx.width / fx.height, 0.01f)
        assertEquals(viewport.height, fx.height, 0.01f)
        assertEquals(0f, fx.y, 0.01f)
        assertTrue(fx.x >= railLane)
        assertTrue(fx.x + fx.width <= rightRail)
        // Centred in the side-lane clear box.
        assertEquals(
            railLane + (rightRail - railLane) / 2f,
            fx.x + fx.width / 2f,
            0.5f,
        )

        // 1:1 keeps the square shape at full height inside the same lanes.
        val square = photographyFeedFrame(cinema, viewport, "1:1", railLane, rightRail)
        assertEquals(1f, square.width / square.height, 0.01f)
        assertEquals(viewport.height, square.height, 0.01f)

        // 16:9 takes the cinema placement exactly (iOS video-mode placement).
        assertEquals(
            cinema,
            photographyFeedFrame(cinema, viewport, "16:9", railLane, rightRail),
        )
    }

    @Test
    fun `photo strip host is symmetric about the feed centre`() {
        val band = ZoneFrame(100f, 320f, 700f, 58f)

        // Feed centred right of the band's own middle: the host slice clips to
        // the nearer band edge so Center alignment lands on the feed centre.
        val host = photographyStripHostFrame(band, feedCenterX = 500f)
        assertEquals(500f, host.x + host.width / 2f, 0.01f)
        assertTrue(host.x >= band.x)
        assertTrue(host.x + host.width <= band.x + band.width + 0.01f)

        // A feed centre outside the band degrades to a zero-width slice at it.
        assertEquals(0f, photographyStripHostFrame(band, feedCenterX = 90f).width)
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
