package com.opencapture.openzcine

import com.opencapture.monitorui.MonitorRect
import kotlin.test.Test
import kotlin.test.assertEquals

/**
 * Pure-JVM check of where the live colour notice sits. The zone-map leading and bottom insets
 * are the shared monitor-ui helpers, covered by its own MonitorInsetsTest.
 */
class MonitorInsetsTest {
    @Test
    fun liveColorNoticeClearsAnOverlaidLandscapeInfoDeck() {
        assertEquals(
            62f,
            liveFeedColorNoticeTopInsetDp(
                feed = MonitorRect(59f, 0f, 734f, 393f),
                infoBar = MonitorRect(100f, 8f, 500f, 46f),
                statusBarVisible = true,
            ),
        )
    }

    @Test
    fun liveColorNoticeUsesItsEdgeGapWhenTheDeckIsOutsideOrHidden() {
        val feed = MonitorRect(0f, 52f, 400f, 622f)
        val infoBar = MonitorRect(0f, 0f, 400f, 52f)
        assertEquals(8f, liveFeedColorNoticeTopInsetDp(feed, infoBar, statusBarVisible = true))
        assertEquals(8f, liveFeedColorNoticeTopInsetDp(feed, infoBar, statusBarVisible = false))
    }
}
