package com.opencapture.openzcine

import com.opencapture.monitorui.MonitorAssistTool
import com.opencapture.monitorui.MonitorGuideAspect
import com.opencapture.opencine.appkit.MonitorAssistState
import com.opencapture.opencine.media.MonitorDesqueezeDirection
import com.opencapture.opencine.media.MonitorDesqueezePreset
import com.opencapture.openzcine.settings.LocalFramingAssistConfiguration
import com.opencapture.openzcine.settings.LocalLevelStyle
import com.opencapture.openzcine.settings.MonitorDisplayMode
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNull
import kotlin.test.assertTrue

class FramingAssistsTest {

    @Test
    fun `narrowing and widening desqueeze remain centered inside the exact visible feed`() {
        val feed = FramingAssistRect(left = 10f, top = 20f, width = 1_000f, height = 500f)

        val horizontal =
            localDesqueezePresentationRect(
                feed = feed,
                enabled = true,
                factor = 2f,
                direction = MonitorDesqueezeDirection.VERTICAL,
            )
        val vertical =
            localDesqueezePresentationRect(
                feed = feed,
                enabled = true,
                factor = 2f,
                direction = MonitorDesqueezeDirection.HORIZONTAL,
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
                                MonitorGuideAspect.CINEMA,
                                MonitorGuideAspect.VERTICAL,
                            ),
                    ),
            )

        assertEquals(
            listOf(MonitorGuideAspect.VERTICAL, MonitorGuideAspect.CINEMA),
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
        val selected = setOf(MonitorGuideAspect.CINEMA, MonitorGuideAspect.HD)
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
        val state = MonitorAssistState(pinnedNames = setOf("GUIDES", "DESQ"))
        state.syncVisible(
            setOf(MonitorAssistTool.GUIDES, MonitorAssistTool.GRID, MonitorAssistTool.CROSS, MonitorAssistTool.DESQ),
        )
        state.selectedGuides = setOf(MonitorGuideAspect.CINEMA)
        state.guideMask = true
        state.setGridOption(thirds = true, phi = true, diagonal = true)
        state.selectDesqueezePreset(MonitorDesqueezePreset.X133)
        state.updateDesqueezeDirection(MonitorDesqueezeDirection.HORIZONTAL)
        fun configuration(mode: MonitorDisplayMode) =
            state.framing({ state.rendersLive(it, mode, photography = false) }, LocalLevelStyle.HORIZON)

        // The render plan does not decide DISP policy: the caller hands it a configuration
        // already filtered by `rendersLive`. Clean with only GUIDES pinned keeps the
        // delivery frame and its mask and drops the grid and crosshair (#256).
        val live = localFramingRenderPlan(1_920f, 1_080f, configuration(MonitorDisplayMode.LIVE))
        val clean = localFramingRenderPlan(1_920f, 1_080f, configuration(MonitorDisplayMode.CLEAN))

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
                        selectedGuideRatios = setOf(MonitorGuideAspect.CINEMA),
                        guideMaskEnabled = true,
                        gridVisible = true,
                        thirds = true,
                        crosshair = true,
                        desqueezeEnabled = true,
                        desqueezeFactor = 2f,
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
        selectedGuideRatios: Set<MonitorGuideAspect> = emptySet(),
        guideMaskEnabled: Boolean = false,
        gridVisible: Boolean = false,
        thirds: Boolean = false,
        phi: Boolean = false,
        diagonal: Boolean = false,
        crosshair: Boolean = false,
        desqueezeEnabled: Boolean = false,
        desqueezeFactor: Float = 1f,
        // The pre-shared default: Nikon narrowed the picture (a pillarbox).
        desqueezeDirection: MonitorDesqueezeDirection = MonitorDesqueezeDirection.VERTICAL,
    ): LocalFramingAssistConfiguration =
        LocalFramingAssistConfiguration(
            guidesVisible = guidesVisible,
            selectedGuideRatios = selectedGuideRatios,
            guideMaskEnabled = guideMaskEnabled,
            gridVisible = gridVisible,
            ruleOfThirdsEnabled = thirds,
            phiGridEnabled = phi,
            diagonalGridEnabled = diagonal,
            centerCrosshairEnabled = crosshair,
            desqueezeEnabled = desqueezeEnabled,
            desqueezeFactor = desqueezeFactor,
            desqueezeDirection = desqueezeDirection,
        )
}
