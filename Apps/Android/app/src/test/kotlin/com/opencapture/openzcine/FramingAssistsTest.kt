package com.opencapture.openzcine

import com.opencapture.openzcine.settings.LocalDesqueezePresentation
import com.opencapture.openzcine.settings.LocalFramingAssistConfiguration
import com.opencapture.openzcine.settings.LocalFramingGuide
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNotNull
import kotlin.test.assertNull
import kotlin.test.assertTrue

class FramingAssistsTest {

    @Test
    fun `desqueeze presentation remains centered inside the existing feed zone`() {
        val rect =
            localDesqueezePresentationRect(
                width = 1_000f,
                height = 500f,
                presentation = LocalDesqueezePresentation.X200,
            )

        assertEquals(250f, rect.left)
        assertEquals(0f, rect.top)
        assertEquals(500f, rect.width)
        assertEquals(500f, rect.height)
    }

    @Test
    fun `cinema guide letterboxes a wide feed without inventing new feed geometry`() {
        val guide =
            centeredGuideRect(
                feed = FramingAssistRect(left = 0f, top = 0f, width = 1_920f, height = 1_080f),
                guide = LocalFramingGuide.CINEMA_239,
            )

        assertNotNull(guide)
        assertEquals(0f, guide.left)
        assertEquals(138.32635f, guide.top, absoluteTolerance = 0.001f)
        assertEquals(1_920f, guide.width)
        assertEquals(803.3473f, guide.height, absoluteTolerance = 0.001f)
    }

    @Test
    fun `widescreen guide pillarboxes a portrait feed`() {
        val guide =
            centeredGuideRect(
                feed = FramingAssistRect(left = 0f, top = 0f, width = 900f, height = 1_600f),
                guide = LocalFramingGuide.WIDESCREEN_16_9,
            )

        assertNotNull(guide)
        assertEquals(0f, guide.left)
        assertEquals(546.875f, guide.top)
        assertEquals(900f, guide.width)
        assertEquals(506.25f, guide.height)
        assertNull(
            centeredGuideRect(
                feed = FramingAssistRect(left = 0f, top = 0f, width = 900f, height = 1_600f),
                guide = LocalFramingGuide.OFF,
            ),
        )
    }

    @Test
    fun `clean mode retains local delivery framing but suppresses busy assists`() {
        val configuration =
            LocalFramingAssistConfiguration(
                ruleOfThirdsEnabled = true,
                centerCrosshairEnabled = true,
                guide = LocalFramingGuide.CINEMA_239,
                desqueezePresentation = LocalDesqueezePresentation.X133,
            )

        val live = localFramingRenderPlan(1_920f, 1_080f, configuration, cleanMode = false)
        val clean = localFramingRenderPlan(1_920f, 1_080f, configuration, cleanMode = true)

        assertTrue(live.drawsRuleOfThirds)
        assertTrue(live.drawsCenterCrosshair)
        assertNotNull(live.guideRect)
        assertFalse(clean.drawsRuleOfThirds)
        assertFalse(clean.drawsCenterCrosshair)
        assertNotNull(clean.guideRect)
        assertEquals(live.presentationRect, clean.presentationRect)
    }
}
