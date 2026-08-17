package com.opencapture.openzcine.core

import kotlin.test.Test
import kotlin.test.assertEquals

/** Pins the display-rotation helper to the shared Swift `PTPLiveViewRotation.displayed`. */
class LiveFeedRotationTest {

    @Test
    fun `auto-rotate off keeps every body orientation as landscape`() {
        for (rotation in LiveFeedRotation.entries) {
            assertEquals(rotation, rotation.displayed(autoRotateEnabled = true))
            assertEquals(LiveFeedRotation.LANDSCAPE, rotation.displayed(autoRotateEnabled = false))
        }
    }
}
