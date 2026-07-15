package com.opencapture.openzcine.wear

import kotlin.test.Test
import kotlin.test.assertEquals

class WearPreviewPacingTest {
    @Test
    fun `acknowledgements adapt preview size quality and cadence`() {
        val pacing = AdaptiveWearPreviewPacing()

        assertEquals(336, pacing.currentProfile().maximumWidth)
        assertEquals(416, pacing.acknowledge(90L).maximumWidth)

        pacing.reset()
        assertEquals(336, pacing.acknowledge(250L).maximumWidth)
        pacing.reset()
        assertEquals(256, pacing.acknowledge(400L).maximumWidth)
        assertEquals(24, pacing.currentProfile().jpegQuality)
    }

    @Test
    fun `missing acknowledgement degrades one tier and reset is conservative`() {
        val pacing = AdaptiveWearPreviewPacing()

        assertEquals(256, pacing.timedOut().maximumWidth)
        assertEquals(256, pacing.timedOut().maximumWidth)
        pacing.reset()
        assertEquals(336, pacing.currentProfile().maximumWidth)
    }
}
