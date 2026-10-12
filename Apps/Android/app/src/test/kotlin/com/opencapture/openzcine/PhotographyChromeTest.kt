package com.opencapture.openzcine

import kotlin.test.Test
import kotlin.test.assertEquals

/** JVM coverage for photography chrome policy helpers. */
class PhotographyChromeTest {
    @Test
    fun `profile tile compacts the built-in picture controls`() {
        assertEquals("SD", compactPictureControlLabel("Standard"))
        assertEquals("NL", compactPictureControlLabel("Neutral"))
        assertEquals("MC", compactPictureControlLabel("Monochrome"))
        assertEquals("DTM", compactPictureControlLabel("Deep Tone Mono"))
        assertEquals("RTP", compactPictureControlLabel("Rich Tone Portrait"))
        // Auto and the creative names show whole; unknown stays untouched.
        assertEquals("Auto", compactPictureControlLabel("Auto"))
        assertEquals("Denim", compactPictureControlLabel("Denim"))
        assertEquals(null, compactPictureControlLabel(null))
    }
}
