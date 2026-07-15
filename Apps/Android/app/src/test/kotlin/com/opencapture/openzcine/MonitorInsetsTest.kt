package com.opencapture.openzcine

import com.opencapture.openzcine.bridge.ZoneFrame
import kotlin.test.Test
import kotlin.test.assertEquals

/**
 * Pure-JVM check of the zone-map leading-inset derivation: the display cutout
 * floored at the synthesized iPhone island lane, plus any transient
 * system-bar lane on the same edge.
 */
class MonitorInsetsTest {
    @Test
    fun zeroCutoutFloorsAtTheIslandLane() {
        // SM-A127F: the punch-hole resolves to a zero inset — the floor alone
        // must carve the iPhone-parity left lane.
        assertEquals(IOS_ISLAND_LANE_DP, monitorLeadingInsetDp(0f, 0f))
    }

    @Test
    fun cutoutWiderThanTheLaneWins() {
        assertEquals(70f, monitorLeadingInsetDp(70f, 0f))
    }

    @Test
    fun transientBarAddsItsLaneOnTopOfTheFloor() {
        // Reverse-landscape nav bar on the leading edge: the bar lane stacks
        // on the floored cutout so the feed clears the overlay.
        assertEquals(IOS_ISLAND_LANE_DP + 48f, monitorLeadingInsetDp(0f, 48f))
    }

    @Test
    fun transientBarOverlappingTheCutoutOnlyAddsTheExcess() {
        // Bar (80) renders over the physical cutout (70): only the 10dp of
        // bar beyond the cutout stacks — no double count.
        assertEquals(80f, monitorLeadingInsetDp(70f, 80f))
    }

    @Test
    fun transientBarNarrowerThanTheCutoutAddsNothing() {
        assertEquals(70f, monitorLeadingInsetDp(70f, 40f))
    }

    @Test
    fun portraitBottomInsetKeepsTheSystemRailAboveTheGestureArea() {
        // In sticky immersive mode the SM-A127F reports no bottom inset, so
        // the adapter supplies a stable physical-edge clearance for the rail.
        assertEquals(
            PORTRAIT_SYSTEM_RAIL_BOTTOM_INSET_DP,
            monitorBottomInsetDp(rawInsetDp = 0f, isPortrait = true),
        )
        assertEquals(42f, monitorBottomInsetDp(rawInsetDp = 42f, isPortrait = true))
    }

    @Test
    fun landscapeBottomInsetRemainsThePhysicalInset() {
        assertEquals(0f, monitorBottomInsetDp(rawInsetDp = 0f, isPortrait = false))
        assertEquals(42f, monitorBottomInsetDp(rawInsetDp = 42f, isPortrait = false))
    }

    @Test
    fun liveColorNoticeClearsAnOverlaidLandscapeInfoDeck() {
        assertEquals(
            62f,
            liveFeedColorNoticeTopInsetDp(
                feed = ZoneFrame(59f, 0f, 734f, 393f),
                infoBar = ZoneFrame(100f, 8f, 500f, 46f),
                statusBarVisible = true,
            ),
        )
    }

    @Test
    fun liveColorNoticeUsesItsEdgeGapWhenTheDeckIsOutsideOrHidden() {
        val feed = ZoneFrame(0f, 52f, 400f, 622f)
        val infoBar = ZoneFrame(0f, 0f, 400f, 52f)
        assertEquals(8f, liveFeedColorNoticeTopInsetDp(feed, infoBar, statusBarVisible = true))
        assertEquals(8f, liveFeedColorNoticeTopInsetDp(feed, infoBar, statusBarVisible = false))
    }
}
