package com.opencapture.openzcine

import com.opencapture.monitorui.MonitorAssistTool
import com.opencapture.monitorui.MonitorGuideAspect
import com.opencapture.opencine.appkit.MonitorAssistState
import com.opencapture.openzcine.settings.LocalLevelStyle
import com.opencapture.openzcine.settings.MonitorDisplayMode
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNull
import kotlin.test.assertSame
import kotlin.test.assertTrue
import com.opencapture.opencine.nikon.LiveFrame
import com.opencapture.opencine.nikon.LiveFrameSource

/**
 * Android's half of the shared clean-view contract (#256). The rule itself is asserted once in the
 * core (`MonitorChromePolicy`); this covers the Kotlin projections the Compose shell renders from.
 */
class MonitorCleanViewPolicyTest {
    /** Every tool switched on, nothing pinned: the stored set the DISP filter projects from. */
    private fun allOn(): MonitorAssistState =
        MonitorAssistState(pinnedNames = emptySet()).apply {
            syncVisible(MonitorAssistTool.entries.toSet())
        }

    @Test
    fun `clean hides every tool that is not pinned and command hides all of them`() {
        val state = allOn()
        for (tool in MonitorAssistTool.entries) {
            state.pinned = emptySet()
            assertTrue(
                state.rendersLive(tool, MonitorDisplayMode.LIVE, photography = false),
                "$tool must render in live",
            )
            assertFalse(
                state.rendersLive(tool, MonitorDisplayMode.CLEAN, photography = false),
                "$tool must be hidden in clean by default",
            )
            state.pinned = setOf(tool)
            assertFalse(
                state.rendersLive(tool, MonitorDisplayMode.COMMAND, photography = false),
                "$tool must be hidden in command even when pinned",
            )
            assertTrue(
                state.rendersLive(tool, MonitorDisplayMode.CLEAN, photography = false),
                "$tool must render in clean once pinned",
            )
        }
    }

    @Test
    fun `clean renders exactly the pinned scopes and leaves the stored set alone`() {
        val state = MonitorAssistState(pinnedNames = emptySet())
        state.syncVisible(setOf(MonitorAssistTool.WAVE, MonitorAssistTool.HISTO, MonitorAssistTool.LIGHTS))
        val selected = setOf(ScopeKind.WAVEFORM, ScopeKind.HISTOGRAM, ScopeKind.TRAFFIC_LIGHTS)
        fun rendered(mode: MonitorDisplayMode) = scopesShown { state.rendersLive(it, mode, photography = false) }

        assertEquals(selected, rendered(MonitorDisplayMode.LIVE))
        assertTrue(rendered(MonitorDisplayMode.CLEAN).isEmpty())
        state.pinned = setOf(MonitorAssistTool.HISTO)
        assertEquals(setOf(ScopeKind.HISTOGRAM), rendered(MonitorDisplayMode.CLEAN))
        assertTrue(rendered(MonitorDisplayMode.COMMAND).isEmpty())
        assertEquals(selected, scopesShown(state::isOn))
    }

    @Test
    fun `clean bakes only the pinned feed effects`() {
        val assists = NikonAssists(allOn(), FeedLutSelection.BuiltIn(FeedLut.LOG3G10_709)) {}
        val state = assists.shared
        state.setSplitComparison(false)
        fun rendered(mode: MonitorDisplayMode) = assists.feedEffects { state.rendersLive(it, mode, photography = false) }
        val effects =
            FeedEffects(
                lut = FeedLutSelection.BuiltIn(FeedLut.LOG3G10_709),
                falseColor = FeedFalseColorScale.STOPS,
                peaking = true,
                zebra = true,
            )

        assertEquals(effects, rendered(MonitorDisplayMode.LIVE))
        assertTrue(rendered(MonitorDisplayMode.CLEAN).isIdentity)

        state.pinned = setOf(MonitorAssistTool.PEAK)
        val pinnedPeaking = rendered(MonitorDisplayMode.CLEAN)
        assertTrue(pinnedPeaking.peaking)
        assertFalse(pinnedPeaking.zebra)
        assertNull(pinnedPeaking.lut)
        assertNull(pinnedPeaking.falseColor)

        // Leaving clean restores the operator's set untouched.
        assertEquals(effects, rendered(MonitorDisplayMode.LIVE))
    }

    @Test
    fun `clean draws only the pinned framing aids`() {
        val state = allOn()
        state.selectedGuides = setOf(MonitorGuideAspect.CINEMA)
        fun rendered(mode: MonitorDisplayMode) =
            state.framing({ state.rendersLive(it, mode, photography = false) }, LocalLevelStyle.HORIZON)

        val live = rendered(MonitorDisplayMode.LIVE)
        assertEquals(state.framing(state::isOn, LocalLevelStyle.HORIZON), live)
        assertTrue(live.guidesVisible && live.gridVisible && live.centerCrosshairEnabled)
        assertTrue(live.levelEnabled && live.evMeterEnabled && live.desqueezeEnabled)

        val bare = rendered(MonitorDisplayMode.CLEAN)
        assertFalse(bare.guidesVisible)
        assertFalse(bare.gridVisible)
        assertFalse(bare.centerCrosshairEnabled)
        assertFalse(bare.levelEnabled)
        assertFalse(bare.evMeterEnabled)
        assertFalse(bare.desqueezeEnabled)

        state.pinned = setOf(MonitorAssistTool.GUIDES)
        val pinnedGuides = rendered(MonitorDisplayMode.CLEAN)
        assertTrue(pinnedGuides.guidesVisible)
        assertFalse(pinnedGuides.gridVisible)
    }

    @Test
    fun `command keeps the timecode source while dropping every preview consumer`() {
        val source = object : LiveFrameSource {
            override val frames = kotlinx.coroutines.flow.emptyFlow<LiveFrame>()
        }
        assertNull(monitorPreviewFrameSource(source, isCommandMode = true))
        assertSame(source, monitorTimecodeFrameSource(source))
        assertNull(monitorTimecodeFrameSource(null))
    }
}
