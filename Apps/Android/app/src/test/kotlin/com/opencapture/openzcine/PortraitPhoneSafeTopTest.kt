package com.opencapture.openzcine

import com.opencapture.monitorui.MonitorLayoutPolicy
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertTrue

/** The badge placement cases moved to Core `MonitorChromeEditBadgeLayoutTest` with the shared editor. */
class PortraitPhoneSafeTopTest {
    @Test
    fun aCutoutLessPortraitPhoneGetsThePunchHoleBandAboveTheStatusRow() {
        // The FPS chip and batteries hang from telemetry.y; the chip is 27.5 dp tall.
        fun bandGap(safeTop: Float): Float {
            val layout = MonitorLayoutPolicy.fieldMonitor(411f, 914f, safeTop = portraitPhoneSafeTop(safeTop, 411f, 914f))
            return layout.status.y - (layout.telemetry.y + 27.5f)
        }
        val punchHole = bandGap(52f)
        assertTrue(punchHole > 0f)
        assertEquals(punchHole, bandGap(0f), 0.01f)
        assertEquals(punchHole, bandGap(24f), 0.01f)
        // Landscape and tablets keep their inset.
        assertEquals(0f, portraitPhoneSafeTop(0f, 914f, 411f))
        assertEquals(0f, portraitPhoneSafeTop(0f, 820f, 1180f))
    }
}
