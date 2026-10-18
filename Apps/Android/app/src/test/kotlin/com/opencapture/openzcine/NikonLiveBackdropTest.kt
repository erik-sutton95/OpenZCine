package com.opencapture.openzcine

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNotNull
import kotlin.test.assertNull

/** A3-09: the shared material samples the picture where the feed actually draws it. */
class NikonLiveBackdropTest {
    @Test
    fun theSampledPictureIsTheFittedRasterAfterTheDesqueeze() {
        // 1024x576 fits a 1000x500 zone as 889x500, centred.
        val fit = assertNotNull(liveBackdropImageRect(1000f, 500f, 1024, 576, aspectFill = false, scaleX = 1f, scaleY = 1f))
        assertEquals(56f, fit.left)
        assertEquals(0f, fit.top)
        assertEquals(945f, fit.right)
        assertEquals(500f, fit.bottom)
        // A 1.33x anamorphic de-squeeze widens it about the zone centre.
        val wide = assertNotNull(liveBackdropImageRect(1000f, 500f, 1024, 576, aspectFill = false, scaleX = 1.33f, scaleY = 1f))
        assertEquals(500f - 444f * 1.33f, wide.left, absoluteTolerance = 0.01f)
        assertEquals(500f + 445f * 1.33f, wide.right, absoluteTolerance = 0.01f)
        // Portrait fill crops the sides instead.
        val fill = assertNotNull(liveBackdropImageRect(400f, 800f, 1024, 576, aspectFill = true, scaleX = 1f, scaleY = 1f))
        assertEquals(800f, fill.height)
        assertEquals(200f, fill.center.x, absoluteTolerance = 0.5f)
        assertNull(liveBackdropImageRect(1000f, 500f, 0, 0, aspectFill = false, scaleX = 1f, scaleY = 1f), "no frame yet")
    }
}
