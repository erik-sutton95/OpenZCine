package com.opencapture.openzcine.wear

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertTrue

class WearScreenLayoutTest {
    @Test
    fun `round screens protect corner readouts and timecode shrinks`() {
        val square = wearScreenLayout(isRound = false, widthDp = 192f)
        val round = wearScreenLayout(isRound = true, widthDp = 180f)

        assertTrue(round.timecodeHorizontalPaddingDp > square.timecodeHorizontalPaddingDp)
        assertTrue(round.bottomHorizontalPaddingDp > square.bottomHorizontalPaddingDp)
        assertTrue(round.timecodeFontSizeSp < square.timecodeFontSizeSp)
        assertTrue(round.timecodeFontSizeSp >= 14f)
    }

    @Test
    fun `long storage labels fit side slots without becoming illegible`() {
        assertEquals(11f, fittedSingleLineFontSize("4 GB", availableWidthDp = 60f))
        val compact = fittedSingleLineFontSize("521 GB · 47%", availableWidthDp = 56f)
        assertTrue(compact in 8f..<11f)
    }
}
