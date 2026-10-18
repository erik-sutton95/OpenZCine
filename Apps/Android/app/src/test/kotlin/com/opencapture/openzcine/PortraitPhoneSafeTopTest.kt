package com.opencapture.openzcine

import com.opencapture.monitorui.MonitorLayoutPolicy
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertTrue

/** The badge placement cases moved to Core `MonitorChromeEditBadgeLayoutTest` with the shared editor. */
class PortraitPhoneSafeTopTest {
    @Test
    fun aCutoutLessPortraitPhoneKeepsTheOriginalStatusAnchorAndCenteredTelemetry() {
        // Performance is centered in the48dp telemetry row; power has its13dp paint offset.
        fun bandGap(safeTop: Float): Float {
            val layout = MonitorLayoutPolicy.fieldMonitor(411f, 914f, safeTop = portraitPhoneSafeTop(safeTop, 411f, 914f))
            assertEquals(maxOf(44f, safeTop) - 6f, layout.status.y, 0.01f)
            val performanceBottom = layout.telemetry.y - 13f + 48f / 2f + 27.5f / 2f
            return layout.status.y - performanceBottom
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
