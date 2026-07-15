package com.opencapture.openzcine.bridge

import com.opencapture.openzcine.core.LiveFocusResult
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNull
import kotlin.test.assertTrue

class LiveFrameMetadataWireTest {
    @Test
    fun `camera focus wire retains coordinates state and selected subject`() {
        val focus =
            liveFocusInfoFromWire(
                hasFocus = true,
                coordinateWidth = 6_048,
                coordinateHeight = 3_400,
                focusResult = 2,
                subjectDetectionActive = true,
                trackingAFActive = true,
                selectedBoxIndex = 1,
                flattenedBoxes = intArrayOf(3_024, 1_700, 800, 600, 2_900, 1_450, 180, 180),
            )

        requireNotNull(focus)
        assertEquals(LiveFocusResult.FOCUSED, focus.result)
        assertTrue(focus.subjectDetectionActive)
        assertTrue(focus.trackingAFActive)
        assertEquals(1, focus.selectedBoxIndex)
        assertEquals(2, focus.boxes.size)
        assertEquals(3_024, focus.boxes.first().centerX)
        assertEquals(180, focus.boxes.last().height)
    }

    @Test
    fun `invalid focus primitives fail closed instead of drawing off feed`() {
        assertNull(
            liveFocusInfoFromWire(
                hasFocus = true,
                coordinateWidth = 1_920,
                coordinateHeight = 1_080,
                focusResult = 2,
                subjectDetectionActive = false,
                trackingAFActive = false,
                selectedBoxIndex = -1,
                flattenedBoxes = intArrayOf(100, 100, 200),
            ),
        )
        assertNull(
            liveFocusInfoFromWire(
                hasFocus = true,
                coordinateWidth = 1_920,
                coordinateHeight = 1_080,
                focusResult = 2,
                subjectDetectionActive = false,
                trackingAFActive = false,
                selectedBoxIndex = -1,
                flattenedBoxes = intArrayOf(2_100, 100, 200, 100),
            ),
        )
    }

    @Test
    fun `camera level is unavailable for missing or nonfinite primitives`() {
        assertNull(liveCameraLevelFromWire(false, 0.0, 0.0, 0.0))
        assertNull(liveCameraLevelFromWire(true, Double.NaN, 0.0, 0.0))

        val level = liveCameraLevelFromWire(true, -0.5, 1.25, 0.0)
        requireNotNull(level)
        assertEquals(-0.5, level.rollDegrees)
        assertEquals(1.25, level.pitchDegrees)
    }
}
