package com.opencapture.openzcine.bridge

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import kotlin.test.assertNull

/** Pure-JVM check of the wire decoding against a hand-built record array. */
class MonitorZonesTest {
    // [kind, style, x, y, width, height] — kinds 0..9 required, 10/13 optional.
    private val flat =
        floatArrayOf(
            0f, -1f, 59f, 0f, 734f, 393f, // feed
            1f, 0f, 100f, 8f, 500f, 46f, // infoBar, INFO_PILL
            2f, 2f, 300f, 321f, 400f, 58f, // captureStrip, AXIS_HORIZONTAL
            4f, 3f, 16f, 14f, 60f, 365f, // systemCluster, AXIS_VERTICAL
            5f, -1f, 16f, 14f, 40f, 40f, // lock
            6f, -1f, 780f, 300f, 44f, 34f, // disp
            7f, -1f, 776f, 160f, 72f, 72f, // record
            8f, -1f, 782f, 100f, 40f, 40f, // media
            9f, -1f, 782f, 50f, 40f, 40f, // settings
            10f, 6f, 16f, 80f, 38f, 233f, // batteryCluster, BATTERY_RAIL
            13f, -1f, 16f, 90f, 38f, 70f, // batteryPhone
            14f, -1f, 16f, 230f, 38f, 70f, // batteryCamera
        )

    @Test
    fun parsesRequiredAndOptionalZones() {
        val zones = MonitorZones.parse(flat)
        assertEquals(ZoneFrame(59f, 0f, 734f, 393f), zones.feed)
        assertEquals(ZoneFrame(776f, 160f, 72f, 72f), zones.record)
        assertEquals(ZoneStyle.BATTERY_RAIL, zones.batteryStyle)
        assertEquals(ZoneFrame(16f, 90f, 38f, 70f), zones.batteryPhone)
        assertNull(zones.assistStrip)
        assertNull(zones.scopes)
        assertNull(zones.controlsGrid)
    }

    @Test
    fun rejectsMissingRequiredZone() {
        // Drop the feed record (first 6 floats).
        assertFailsWith<IllegalArgumentException> {
            MonitorZones.parse(flat.copyOfRange(6, flat.size))
        }
    }

    @Test
    fun rejectsTornArray() {
        assertFailsWith<IllegalArgumentException> {
            MonitorZones.parse(flat.copyOfRange(0, 7))
        }
    }
}
