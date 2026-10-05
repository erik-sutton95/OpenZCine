package com.opencapture.openzcine

import com.opencapture.openzcine.bridge.MonitorZones
import com.opencapture.openzcine.bridge.ZoneFrame
import com.opencapture.openzcine.bridge.ZoneStyle
import com.opencapture.openzcine.settings.MonitorDisplayMode
import kotlin.test.Test
import kotlin.test.assertEquals

/** JVM coverage for photography chrome policy helpers. */
class PhotographyChromeTest {
    private val lock = ZoneFrame(x = 16f, y = 12f, width = 40f, height = 40f)
    private val band = ZoneFrame(x = 59f, y = 320f, width = 700f, height = 58f)

    private fun tabletZones(
        lock: ZoneFrame,
        batteryStyle: ZoneStyle? = ZoneStyle.BATTERY_INLINE,
        batteryCluster: ZoneFrame?,
        batteryPhone: ZoneFrame? = null,
    ): MonitorZones =
        MonitorZones(
            feed = ZoneFrame(0f, 0f, 1133f, 744f),
            infoBar = ZoneFrame(140f, 8f, 800f, 46f),
            captureStrip = null,
            assistStrip = band,
            systemCluster = lock,
            lock = lock,
            disp = ZoneFrame(1000f, 300f, 44f, 34f),
            record = ZoneFrame(1050f, 600f, 72f, 72f),
            media = ZoneFrame(1000f, 12f, 40f, 40f),
            settings = ZoneFrame(1090f, 12f, 40f, 40f),
            batteryCluster = batteryCluster,
            batteryStyle = batteryStyle,
            batteryPhone = batteryPhone,
            batteryCamera = null,
            scopes = null,
            controlsGrid = null,
        )

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

        assertEquals(order, photographyDisplayModeOrder(order, hidesCommand = false))
        assertEquals(
            listOf(MonitorDisplayMode.LIVE, MonitorDisplayMode.CLEAN),
            photographyDisplayModeOrder(order, hidesCommand = true),
        )
        // A COMMAND-only preference recovers to the always-safe live mode.
        assertEquals(
            listOf(MonitorDisplayMode.LIVE),
            photographyDisplayModeOrder(
                listOf(MonitorDisplayMode.COMMAND),
                hidesCommand = true,
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
