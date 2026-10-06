package com.opencapture.openzcine

import com.opencapture.monitorui.MonitorRect
import com.opencapture.opencine.appkit.MonitorChromeEditBadgeLayout
import com.opencapture.openzcine.settings.ChromeSection
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNotNull
import kotlin.test.assertNull
import kotlin.test.assertTrue

/**
 * Nikon's sections on the shared badge placement (OpenCine `MonitorChromeEditBadgeLayout`), with the
 * measured boxes and expectations iOS `RunnerTests` pins on the Swift twin.
 */
class ChromeEditLayoutTest {
    // Real measured landscape boxes from a 852x393 phone: the four readouts nest inside the status
    // bar, and the rail and camera-value strip sit flush against the screen edges.
    private val boxes =
        listOf(
            ChromeSection.STATUS_BAR to MonitorRect(69f, 16f, 678f, 42f),
            ChromeSection.SIDE_RAILS to MonitorRect(763f, 14f, 83f, 289f),
            ChromeSection.ASSIST_TOOLBAR to MonitorRect(16f, 321f, 344f, 58f),
            ChromeSection.CAMERA_VALUES to MonitorRect(368f, 321f, 466f, 58f),
            ChromeSection.LOCK_BUTTON to MonitorRect(16f, 17f, 40f, 40f),
            ChromeSection.BATTERY_INDICATORS to MonitorRect(8f, 63f, 41f, 35f),
            ChromeSection.REC_READOUT to MonitorRect(81f, 23f, 67f, 27f),
            ChromeSection.CODEC_READOUT to MonitorRect(377f, 22f, 98f, 30f),
            ChromeSection.MEDIA_READOUT to MonitorRect(485f, 22f, 132f, 30f),
            ChromeSection.FPS_READOUT to MonitorRect(627f, 22f, 108f, 29f),
        )

    @Test
    fun `badges take a corner of their own element and never stack up`() {
        val size = MonitorChromeEditBadgeLayout.BADGE_SIZE
        val placements = MonitorChromeEditBadgeLayout.badgeFrames(boxes, 852f, 393f).toMap()

        assertEquals(boxes.size, placements.size, "every measured element must get a badge")
        placements.forEach { (section, placement) ->
            assertTrue(placement.x >= 0f && placement.y >= 0f, "$section badge ran off screen")
            assertTrue(
                placement.x + size <= 852f && placement.y + size <= 393f,
                "$section badge ran off the trailing or bottom edge",
            )
            val box = boxes.first { it.first == section }.second
            val centreX = placement.x + size / 2f
            val centreY = placement.y + size / 2f
            assertTrue(
                centreX >= box.x - size && centreX <= box.x + box.width + size &&
                    centreY >= box.y - size && centreY <= box.y + box.height + size,
                "$section badge drifted away from the element it controls",
            )
        }
        val all = placements.values.toList()
        for (i in all.indices) {
            for (j in i + 1 until all.size) {
                val a = all[i]
                val b = all[j]
                val apart =
                    a.x + size <= b.x || b.x + size <= a.x ||
                        a.y + size <= b.y || b.y + size <= a.y
                assertTrue(apart, "two badges overlap at $a and $b")
            }
        }
    }

    @Test
    fun `portrait status bar and batteries get separate eyes in the host order`() {
        // Measured on a 411x914 dp portrait phone: the batteries sit in the status bar's top corner.
        val measured =
            mapOf(
                ChromeSection.STATUS_BAR to MonitorRect(8f, 0f, 383.2f, 44.2f),
                ChromeSection.BATTERY_INDICATORS to MonitorRect(358.1f, 4.2f, 45.3f, 22.1f),
                ChromeSection.CAMERA_VALUES to MonitorRect(14.1f, 728.8f, 383.2f, 81.5f),
                ChromeSection.FOCUS_BOX to MonitorRect(100f, 382f, 90.7f, 78.9f),
            )
        val size = MonitorChromeEditBadgeLayout.BADGE_SIZE
        val placements =
            MonitorChromeEditBadgeLayout.badgeFrames(
                NikonChromeEditHost.PLACEMENT_ORDER.mapNotNull { section -> measured[section]?.let { section to it } },
                411.4f,
                914.3f,
            )
        assertEquals(measured.size, placements.size)
        val all = placements.map { it.second }
        for (i in all.indices) {
            for (j in i + 1 until all.size) {
                val a = all[i]
                val b = all[j]
                assertTrue(
                    a.x + size <= b.x || b.x + size <= a.x || a.y + size <= b.y || b.y + size <= a.y,
                    "${placements[i].first} and ${placements[j].first} badges overlap",
                )
            }
        }
    }

    @Test
    fun `unmeasured elements are skipped`() {
        val placements =
            MonitorChromeEditBadgeLayout.badgeFrames(
                listOf(
                    ChromeSection.STATUS_BAR to MonitorRect(0f, 0f, 0f, 0f),
                    ChromeSection.LOCK_BUTTON to MonitorRect(16f, 17f, 40f, 40f),
                ),
                852f,
                393f,
            ).toMap()
        assertNull(placements[ChromeSection.STATUS_BAR])
        assertNotNull(placements[ChromeSection.LOCK_BUTTON])
    }
}
