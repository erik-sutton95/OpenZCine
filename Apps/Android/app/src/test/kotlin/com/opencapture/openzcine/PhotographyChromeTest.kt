package com.opencapture.openzcine

import com.opencapture.openzcine.settings.MonitorDisplayMode
import kotlin.test.Test
import kotlin.test.assertEquals

/** JVM coverage for photography chrome policy helpers. */
class PhotographyChromeTest {
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
