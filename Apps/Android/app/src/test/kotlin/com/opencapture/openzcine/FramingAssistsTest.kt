package com.opencapture.openzcine

import com.opencapture.openzcine.settings.LocalDesqueezeOrientation
import com.opencapture.openzcine.settings.LocalDesqueezeRatio
import com.opencapture.openzcine.settings.LocalFramingAspectRatio
import com.opencapture.openzcine.settings.LocalFramingAssistConfiguration
import com.opencapture.openzcine.settings.LocalFramingGuideFamily
import com.opencapture.openzcine.settings.LocalMagnificationFactor
import com.opencapture.openzcine.settings.magnificationAnchor
import com.opencapture.openzcine.settings.magnificationAnchorBoxIndex
import com.opencapture.openzcine.settings.MonitorDisplayMode
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNull
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
            )

        assertTrue(visible.drawsInverseGuideMask)
        assertEquals(2, visible.guideFrames.size)
        assertFalse(hidden.drawsInverseGuideMask)
        assertTrue(hidden.guideFrames.isEmpty())
    }

    @Test
    fun `grid patterns are independent and clean view draws only the pinned tools`() {
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

        // The render plan no longer decides DISP policy: the caller hands it a configuration
        // already filtered by `renderedFramingAssists`. Clean with only GUIDES pinned keeps the
        // delivery frame and its mask and drops the grid and crosshair (#256).
        val live = localFramingRenderPlan(1_920f, 1_080f, configuration)
        val clean =
            localFramingRenderPlan(
                1_920f,
                1_080f,
                renderedFramingAssists(
                    configuration,
                    MonitorDisplayMode.CLEAN,
                    setOf(AssistTool.GUIDES, AssistTool.DESQ),
                    photography = false,
                ),
            )

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
        magnificationEnabled: Boolean = false,
        magnificationFactor: LocalMagnificationFactor = LocalMagnificationFactor.X2,
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
            magnificationEnabled = magnificationEnabled,
            magnificationFactor = magnificationFactor,
        )

    /**
     * The punch-in is exactly 1 unless the tool is on AND the key is pressed, which is what makes
     * punching out land on the identical framing rather than a re-derived one. Every guard here is
     * a way the feed could otherwise be left magnified with no visible control explaining it.
     */
    @Test
    fun `punch-in only scales when the tool is on and the key is pressed`() {
        val off = framingConfiguration()
        assertEquals(1f, off.magnificationScale(isActive = true))
        assertEquals(1f, off.magnificationScale(isActive = false))

        val armed =
            framingConfiguration(
                magnificationEnabled = true,
                magnificationFactor = LocalMagnificationFactor.X3,
            )
        assertEquals(1f, armed.magnificationScale(isActive = false))
        assertEquals(3f, armed.magnificationScale(isActive = true))

        // Every offered factor is a real punch-in; none quietly resolves to 1.
        LocalMagnificationFactor.entries.forEach { factor ->
            val scale =
                framingConfiguration(magnificationEnabled = true, magnificationFactor = factor)
                    .magnificationScale(isActive = true)
            assertEquals(factor.scale, scale)
            assertTrue(scale > 1f)
        }
    }

    /**
     * De-squeeze settles the image's SHAPE, so it has to compose with the punch-in rather than be
     * replaced by it. Applying the punch-in first would re-fit to a different rectangle and the
     * image would jump sideways as it zoomed.
     */
    @Test
    fun `punch-in composes with desqueeze instead of replacing it`() {
        val both =
            framingConfiguration(
                desqueezeEnabled = true,
                desqueezeRatio = LocalDesqueezeRatio.X200,
                desqueezeOrientation = LocalDesqueezeOrientation.HORIZONTAL,
                magnificationEnabled = true,
                magnificationFactor = LocalMagnificationFactor.X2,
            )
        val punchIn = both.magnificationScale(isActive = true)
        // 2x squeeze halves the horizontal scale; a 2x punch-in brings it back to 1 while the
        // vertical axis doubles — the anamorphic shape is preserved, not undone.
        assertEquals(1f, both.horizontalPresentationScale * punchIn)
        assertEquals(2f, both.verticalPresentationScale * punchIn)
        // The de-squeezed still ratio is untouched: punch-in is a presentation scale, not a shape.
        assertEquals(
            both.desqueezedAspectRatio(4_000, 2_000),
            framingConfiguration(
                desqueezeEnabled = true,
                desqueezeRatio = LocalDesqueezeRatio.X200,
                desqueezeOrientation = LocalDesqueezeOrientation.HORIZONTAL,
            ).desqueezedAspectRatio(4_000, 2_000),
        )
    }

    /**
     * The whole point of the tool: focus is rarely in the middle of the shot, so a centred punch-in
     * magnifies whatever happens to be there rather than the thing being focused.
     */
    @Test
    fun `punch-in aims at the focus box, not the middle of the frame`() {
        val anchor =
            magnificationAnchor(
                boxCenterX = 1_512,
                boxCenterY = 850,
                coordinateWidth = 6_048,
                coordinateHeight = 3_400,
            )
        assertEquals(0.25f to 0.25f, anchor)
        // Moving the point moves the anchor — read per frame, never latched.
        assertEquals(
            0.75f to 0.75f,
            magnificationAnchor(4_536, 2_550, 6_048, 3_400),
        )
    }

    /**
     * The anchor is the scale's FIXED POINT, so the visible window stays inside the frame at every
     * factor without clamping — including hard against a corner, where recentring could not.
     */
    @Test
    fun `any in-frame anchor keeps the magnified window inside the picture`() {
        for (factor in LocalMagnificationFactor.entries) {
            for (unit in listOf(0f, 0.25f, 0.5f, 0.75f, 1f)) {
                // A scale of s about origin a maps p -> a + s(p - a); the visible window is the
                // preimage of [0, 1].
                val start = unit * (1f - 1f / factor.scale)
                val end = start + 1f / factor.scale
                assertTrue(start >= -1e-6f, "window starts inside the frame")
                assertTrue(end <= 1f + 1e-6f, "window ends inside the frame")
            }
        }
    }

    @Test
    fun `punch-in falls back to the centre with no box to aim at`() {
        assertEquals(0.5f to 0.5f, magnificationAnchor(null, null, 6_048, 3_400))
        // A header that reported no coordinate space cannot be divided by.
        assertEquals(0.5f to 0.5f, magnificationAnchor(100, 100, 0, 0))
        // A box outside the reported space clamps rather than throwing the view off the picture.
        assertEquals(1f to 0f, magnificationAnchor(9_000, -40, 6_048, 3_400))
    }

    /**
     * With subject detection on, the selected box is the face or eye actually being focused. At 4x
     * the difference between "the face" and "the eye" is the whole question.
     */
    @Test
    fun `punch-in follows the selected subject box, else the AF area`() {
        assertEquals(2, magnificationAnchorBoxIndex(boxCount = 3, selectedBoxIndex = 2))
        assertEquals(0, magnificationAnchorBoxIndex(boxCount = 3, selectedBoxIndex = null))
        assertNull(magnificationAnchorBoxIndex(boxCount = 0, selectedBoxIndex = null))
        assertNull(magnificationAnchorBoxIndex(boxCount = 0, selectedBoxIndex = 1))
        // A selection the box array cannot honour falls back to the AF area rather than trapping.
        assertEquals(0, magnificationAnchorBoxIndex(boxCount = 2, selectedBoxIndex = 7))
        assertEquals(0, magnificationAnchorBoxIndex(boxCount = 2, selectedBoxIndex = -1))
    }
}
