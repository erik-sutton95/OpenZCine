package com.opencapture.openzcine

import com.opencapture.monitorui.MonitorAssistTool
import com.opencapture.monitorui.MonitorGuideAspect
import com.opencapture.monitorui.MonitorGuideGeometry
import com.opencapture.monitorui.MonitorScopeRect
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
        val feed = MonitorScopeRect(10f, 20f, 1_000f, 500f)

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

        assertEquals(MonitorScopeRect(260f, 20f, 500f, 500f), horizontal)
        assertEquals(MonitorScopeRect(10f, 145f, 1_000f, 250f), vertical)
    }

    @Test
    fun `multiple guide frames resolve within the supplied feed`() {
        val plan =
            localFramingRenderPlan(
                feed = MonitorScopeRect(40f, 60f, 1_920f, 1_080f),
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

        // The shared marks draw each guide with MonitorGuideGeometry inside the presentation rect.
        val vertical = MonitorGuideGeometry.rectForRatio(plan.presentationRect, MonitorGuideAspect.VERTICAL.ratio)
        val cinema = MonitorGuideGeometry.rectForRatio(plan.presentationRect, MonitorGuideAspect.CINEMA.ratio)
        assertEquals(setOf(MonitorGuideAspect.VERTICAL, MonitorGuideAspect.CINEMA), plan.guides)
        assertEquals(696.25f, vertical.x)
        assertEquals(60f, vertical.y)
        assertEquals(40f, cinema.x)
        assertEquals(198.32635f, cinema.y, absoluteTolerance = 0.001f)
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
        assertEquals(2, visible.guides.size)
        assertFalse(hidden.drawsInverseGuideMask)
        assertTrue(hidden.guides.isEmpty())
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
        assertEquals(1, live.guides.size)
        assertTrue(clean.drawsInverseGuideMask)
        assertEquals(1, clean.guides.size)
        assertFalse(clean.drawsRuleOfThirds)
        assertFalse(clean.drawsPhiGrid)
        assertFalse(clean.drawsDiagonalGrid)
        assertFalse(clean.drawsCenterCrosshair)
        assertEquals(live.presentationRect, clean.presentationRect)
    }

    @Test
    fun `portrait fill framing remains registered to the complete cropped feed`() {
        val feed = MonitorScopeRect(-333f, 0f, 1_067f, 600f)
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
        assertEquals(MonitorScopeRect(-66.25f, 0f, 533.5f, 600f), plan.presentationRect)
        assertEquals(
            plan.presentationRect.width,
            MonitorGuideGeometry.rectForRatio(plan.presentationRect, plan.guides.single().ratio).width,
        )
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

    @Test
    fun `mirror selections retain independent axes while each context admits visibility`() {
        val legacy = LocalFramingAssistConfiguration(mirrorEnabled = true)
        assertTrue(legacy.mirrorsHorizontally)
        assertFalse(legacy.flipsVertically)
        val vertical = legacy.copy(mirrorHorizontal = false, mirrorVertical = true)
        assertFalse(vertical.mirrorsHorizontally)
        assertTrue(vertical.flipsVertically)
        val hidden = vertical.copy(mirrorEnabled = false)
        assertFalse(hidden.mirrorsHorizontally)
        assertFalse(hidden.flipsVertically)
        assertFalse(hidden.mirrorHorizontal)
        assertTrue(hidden.mirrorVertical)
    }

}
