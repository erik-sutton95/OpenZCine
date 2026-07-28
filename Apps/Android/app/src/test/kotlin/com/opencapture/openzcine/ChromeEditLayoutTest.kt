package com.opencapture.openzcine

import com.opencapture.openzcine.settings.ChromeSection
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNotNull
import kotlin.test.assertNull
import kotlin.test.assertTrue

/**
 * Mirrors `editBadgesTakeACornerOfTheirOwnElementAndNeverStackUp` in
 * `Tests/OpenZCineCoreTests/OperatorPreferencesTests.swift` — same boxes, same expectations, so a
 * drift between the two shells' badge placement fails here.
 */
class ChromeEditLayoutTest {
    // Real measured landscape boxes from a 852x393 phone: the four readouts nest inside the status
    // bar, and the rail and camera-value strip sit flush against the screen edges.
    private val boxes =
        listOf(
            ChromeEditBox(ChromeSection.STATUS_BAR, 69f, 16f, 678f, 42f),
            ChromeEditBox(ChromeSection.SIDE_RAILS, 763f, 14f, 83f, 289f),
            ChromeEditBox(ChromeSection.ASSIST_TOOLBAR, 16f, 321f, 344f, 58f),
            ChromeEditBox(ChromeSection.CAMERA_VALUES, 368f, 321f, 466f, 58f),
            ChromeEditBox(ChromeSection.LOCK_BUTTON, 16f, 17f, 40f, 40f),
            ChromeEditBox(ChromeSection.BATTERY_INDICATORS, 8f, 63f, 41f, 35f),
            ChromeEditBox(ChromeSection.REC_READOUT, 81f, 23f, 67f, 27f),
            ChromeEditBox(ChromeSection.CODEC_READOUT, 377f, 22f, 98f, 30f),
            ChromeEditBox(ChromeSection.MEDIA_READOUT, 485f, 22f, 132f, 30f),
            ChromeEditBox(ChromeSection.FPS_READOUT, 627f, 22f, 108f, 29f),
        )

    @Test
    fun `badges take a corner of their own element and never stack up`() {
        val size = ChromeEditLayout.BADGE_SIZE_DP
        val placements = ChromeEditLayout.badgeFrames(boxes, 852f, 393f)

        assertEquals(boxes.size, placements.size, "every measured element must get a badge")
        placements.forEach { (section, placement) ->
            assertTrue(placement.left >= 0f && placement.top >= 0f, "$section badge ran off screen")
            assertTrue(
                placement.left + size <= 852f && placement.top + size <= 393f,
                "$section badge ran off the trailing or bottom edge",
            )
            val box = boxes.first { it.section == section }
            val centreX = placement.left + size / 2f
            val centreY = placement.top + size / 2f
            assertTrue(
                centreX >= box.left - size && centreX <= box.left + box.width + size &&
                    centreY >= box.top - size && centreY <= box.top + box.height + size,
                "$section badge drifted away from the element it controls",
            )
        }
        val all = placements.values.toList()
        for (i in all.indices) {
            for (j in i + 1 until all.size) {
                val a = all[i]
                val b = all[j]
                val apart =
                    a.left + size <= b.left || b.left + size <= a.left ||
                        a.top + size <= b.top || b.top + size <= a.top
                assertTrue(apart, "two badges overlap at $a and $b")
            }
        }
    }

    @Test
    fun `unmeasured elements are skipped`() {
        val placements =
            ChromeEditLayout.badgeFrames(
                listOf(
                    ChromeEditBox(ChromeSection.STATUS_BAR, 0f, 0f, 0f, 0f),
                    ChromeEditBox(ChromeSection.LOCK_BUTTON, 16f, 17f, 40f, 40f),
                ),
                852f,
                393f,
            )
        assertNull(placements[ChromeSection.STATUS_BAR])
        assertNotNull(placements[ChromeSection.LOCK_BUTTON])
    }
}
