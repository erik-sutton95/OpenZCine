package com.opencapture.openzcine

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertTrue

/** Pure-JVM checks of the glass tier resolution and the auto-degrade counter. */
class GlassTierTest {
    @Test
    fun platformCeilingPicksTheTier() {
        assertEquals(GlassTier.FULL, resolveTier(33))
        assertEquals(GlassTier.FULL, resolveTier(36))
        assertEquals(GlassTier.BLUR, resolveTier(31))
        assertEquals(GlassTier.BLUR, resolveTier(32))
        assertEquals(GlassTier.FLAT, resolveTier(29))
    }

    @Test
    fun overrideLowersButNeverRaises() {
        assertEquals(GlassTier.BLUR, resolveTier(33, "blur"))
        assertEquals(GlassTier.FLAT, resolveTier(33, "flat"))
        // FULL needs RuntimeShader — an API 31 device stays at its BLUR ceiling.
        assertEquals(GlassTier.BLUR, resolveTier(31, "full"))
        assertEquals(GlassTier.FLAT, resolveTier(29, "full"))
    }

    @Test
    fun unknownOverrideFallsBackToTheCeiling() {
        assertEquals(GlassTier.FULL, resolveTier(33, "chrome"))
        assertEquals(GlassTier.FULL, resolveTier(33, null))
    }

    @Test
    fun backdropUsesTheFeedRenderersFitAndFillTransforms() {
        val fit = requireNotNull(glassBackdropContentRect(400f, 600f, 1_920, 1_080, false))
        val fill = requireNotNull(glassBackdropContentRect(400f, 600f, 1_920, 1_080, true))

        assertTrue(fit.top > 0)
        assertEquals(400, fit.width)
        assertTrue(fill.left < 0)
        assertEquals(600, fill.height)
    }

    private fun window() =
        FrameBudgetWindow(budgetNanos = 48, window = 10, maxOverBudget = 1, warmup = 2)

    @Test
    fun healthyWindowNeverDemotes() {
        val budget = window()
        repeat(50) { assertFalse(budget.frame(16)) }
    }

    @Test
    fun sustainedOverrunDemotesAfterAFullWindow() {
        val budget = window()
        repeat(2) { budget.frame(999) } // warmup: ignored, however bad
        repeat(9) { assertFalse(budget.frame(999)) }
        assertTrue(budget.frame(999)) // 10th frame closes the window
    }

    @Test
    fun windowResetsAfterEachDecision() {
        val budget = window()
        repeat(2) { budget.frame(16) }
        // One bad frame per window is within maxOverBudget — never demotes.
        repeat(4) {
            repeat(9) { assertFalse(budget.frame(16)) }
            assertFalse(budget.frame(999))
        }
    }
}
