package com.opencapture.openzcine

import com.opencapture.openzcine.settings.LocalDesqueezeOrientation
import com.opencapture.openzcine.settings.LocalDesqueezeRatio
import com.opencapture.openzcine.settings.LocalFramingAspectRatio
import com.opencapture.openzcine.settings.LocalFramingAssistConfiguration
import com.opencapture.openzcine.settings.LocalFramingGuideFamily
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertTrue

class FramingAssistsTest {

    @Test
    fun `horizontal and vertical desqueeze remain centered inside the exact visible feed`() {
        val feed = FramingAssistRect(left = 10f, top = 20f, width = 1_000f, height = 500f)

        val horizontal =
            localDesqueezePresentationRect(
                feed = feed,
                enabled = true,
                factor = LocalDesqueezeRatio.X200.factor,
                orientation = LocalDesqueezeOrientation.HORIZONTAL,
            )
        val vertical =
            localDesqueezePresentationRect(
                feed = feed,
                enabled = true,
                factor = LocalDesqueezeRatio.X200.factor,
                orientation = LocalDesqueezeOrientation.VERTICAL,
            )

        assertEquals(260f, horizontal.left)
        assertEquals(20f, horizontal.top)
        assertEquals(500f, horizontal.width)
        assertEquals(500f, horizontal.height)
        assertEquals(10f, vertical.left)
        assertEquals(145f, vertical.top)
        assertEquals(1_000f, vertical.width)
        assertEquals(250f, vertical.height)
    }

    @Test
    fun `multiple guide frames resolve in stable narrow to wide order within supplied feed`() {
        val plan =
            localFramingRenderPlan(
                feed = FramingAssistRect(left = 40f, top = 60f, width = 1_920f, height = 1_080f),
                configuration =
                    framingConfiguration(
                        guidesVisible = true,
                        selectedGuideRatios =
                            setOf(
                                LocalFramingAspectRatio.RATIO_239,
                                LocalFramingAspectRatio.RATIO_9_16,
                            ),
                    ),
                cleanMode = false,
            )

        assertEquals(
            listOf(LocalFramingAspectRatio.RATIO_9_16, LocalFramingAspectRatio.RATIO_239),
            plan.guideFrames.map { it.ratio },
        )
        assertEquals(696.25f, plan.guideFrames.first().rect.left)
        assertEquals(60f, plan.guideFrames.first().rect.top)
        assertEquals(40f, plan.guideFrames.last().rect.left)
        assertEquals(198.32635f, plan.guideFrames.last().rect.top, absoluteTolerance = 0.001f)
        assertEquals(1_920f, plan.presentationRect.width)
        assertEquals(1_080f, plan.presentationRect.height)
    }

    @Test
    fun `inverse guide mask follows the union only when visible guide frames exist`() {
        val selected = setOf(LocalFramingAspectRatio.RATIO_239, LocalFramingAspectRatio.RATIO_16_9)
        val visible =
            localFramingRenderPlan(
                1_920f,
                1_080f,
                framingConfiguration(
                    guidesVisible = true,
                    selectedGuideRatios = selected,
                    guideMaskEnabled = true,
                ),
                cleanMode = false,
            )
        val hidden =
            localFramingRenderPlan(
                1_920f,
                1_080f,
                framingConfiguration(
                    guidesVisible = false,
                    selectedGuideRatios = selected,
                    guideMaskEnabled = true,
                ),
                cleanMode = false,
            )

        assertTrue(visible.drawsInverseGuideMask)
        assertEquals(2, visible.guideFrames.size)
        assertFalse(hidden.drawsInverseGuideMask)
        assertTrue(hidden.guideFrames.isEmpty())
    }

    @Test
    fun `grid patterns are independent and clean mode retains only delivery framing`() {
        val configuration =
            framingConfiguration(
                guidesVisible = true,
                selectedGuideRatios = setOf(LocalFramingAspectRatio.RATIO_239),
                guideMaskEnabled = true,
                gridVisible = true,
                thirds = true,
                phi = true,
                diagonal = true,
                crosshair = true,
                desqueezeEnabled = true,
                desqueezeRatio = LocalDesqueezeRatio.X133,
                desqueezeOrientation = LocalDesqueezeOrientation.VERTICAL,
            )

        val live = localFramingRenderPlan(1_920f, 1_080f, configuration, cleanMode = false)
        val clean = localFramingRenderPlan(1_920f, 1_080f, configuration, cleanMode = true)

        assertTrue(live.drawsRuleOfThirds)
        assertTrue(live.drawsPhiGrid)
        assertTrue(live.drawsDiagonalGrid)
        assertTrue(live.drawsCenterCrosshair)
        assertEquals(1, live.guideFrames.size)
        assertTrue(clean.drawsInverseGuideMask)
        assertEquals(1, clean.guideFrames.size)
        assertFalse(clean.drawsRuleOfThirds)
        assertFalse(clean.drawsPhiGrid)
        assertFalse(clean.drawsDiagonalGrid)
        assertFalse(clean.drawsCenterCrosshair)
        assertEquals(live.presentationRect, clean.presentationRect)
    }

    @Test
    fun `portrait fill framing remains registered to the complete cropped feed`() {
        val feed = FramingAssistRect(left = -333f, top = 0f, width = 1_067f, height = 600f)
        val plan =
            localFramingRenderPlan(
                feed = feed,
                configuration =
                    framingConfiguration(
                        guidesVisible = true,
                        selectedGuideRatios = setOf(LocalFramingAspectRatio.RATIO_239),
                        guideMaskEnabled = true,
                        gridVisible = true,
                        thirds = true,
                        crosshair = true,
                        desqueezeEnabled = true,
                        desqueezeRatio = LocalDesqueezeRatio.X200,
                    ),
                cleanMode = false,
            )

        // iOS scales the complete camera-pixel feed first and lets the screen
        // crop it. Rebasing this rectangle to 0...400 would move the guides.
        assertEquals(FramingAssistRect(-66.25f, 0f, 533.5f, 600f), plan.presentationRect)
        assertEquals(plan.presentationRect.width, plan.guideFrames.single().rect.width)
        assertTrue(plan.drawsInverseGuideMask)
        assertTrue(plan.drawsRuleOfThirds)
        assertTrue(plan.drawsCenterCrosshair)
    }

    private fun framingConfiguration(
        guidesVisible: Boolean = false,
        selectedGuideRatios: Set<LocalFramingAspectRatio> = emptySet(),
        guideMaskEnabled: Boolean = false,
        gridVisible: Boolean = false,
        thirds: Boolean = false,
        phi: Boolean = false,
        diagonal: Boolean = false,
        crosshair: Boolean = false,
        desqueezeEnabled: Boolean = false,
        desqueezeRatio: LocalDesqueezeRatio = LocalDesqueezeRatio.X100,
        desqueezeOrientation: LocalDesqueezeOrientation = LocalDesqueezeOrientation.HORIZONTAL,
    ): LocalFramingAssistConfiguration =
        LocalFramingAssistConfiguration(
            guidesVisible = guidesVisible,
            guideFamily = LocalFramingGuideFamily.FILM,
            selectedGuideRatios = selectedGuideRatios,
            guideMaskEnabled = guideMaskEnabled,
            gridVisible = gridVisible,
            ruleOfThirdsEnabled = thirds,
            phiGridEnabled = phi,
            diagonalGridEnabled = diagonal,
            centerCrosshairEnabled = crosshair,
            desqueezeEnabled = desqueezeEnabled,
            desqueezeRatio = desqueezeRatio,
            desqueezeOrientation = desqueezeOrientation,
        )
}
