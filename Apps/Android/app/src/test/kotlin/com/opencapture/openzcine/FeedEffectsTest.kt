package com.opencapture.openzcine

import com.opencapture.monitorui.MonitorAssistTool
import com.opencapture.monitorui.MonitorZebraUnit
import com.opencapture.opencine.appkit.MonitorAssistState
import com.opencapture.opencine.media.MonitorLUTCube
import com.opencapture.opencine.media.MonitorPeakingColor
import com.opencapture.opencine.media.MonitorPeakingSense
import com.opencapture.opencine.media.MonitorZebraPaint
import com.opencapture.openzcine.settings.MonitorDisplayMode
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNull
import kotlin.test.assertTrue

class FeedEffectsTest {
    @Test
    fun `no extras means the identity feed`() {
        val effects = FeedEffects.parse(null, null, null)
        assertEquals(FeedEffects.NONE, effects)
        assertTrue(effects.isIdentity)
    }

    @Test
    fun `parses a combined assist list`() {
        val effects = FeedEffects.parse("lut,zebra,peaking", null, null)
        assertEquals(FeedLutSelection.BuiltIn(FeedLut.LOG3G10_709), effects.lut)
        assertNull(effects.falseColor)
        assertTrue(effects.peaking)
        assertTrue(effects.zebra)
        assertFalse(effects.isIdentity)
    }

    @Test
    fun `false colour retains lut activation while the renderer chooses precedence`() {
        val effects = FeedEffects.parse("lut,falsecolor", "mono", "ire")
        assertEquals(FeedLutSelection.BuiltIn(FeedLut.MONO), effects.lut)
        assertEquals(FeedFalseColorScale.IRE, effects.falseColor)
    }

    @Test
    fun `variant ids select looks and scales`() {
        assertEquals(
            FeedLutSelection.BuiltIn(FeedLut.MONO),
            FeedEffects.parse("lut", "mono", null).lut,
        )
        assertEquals(
            FeedLutSelection.BuiltIn(FeedLut.NLOG_709),
            FeedEffects.parse("lut", "nlog", null).lut,
        )
        assertEquals(
            FeedFalseColorScale.STOPS,
            FeedEffects.parse("falsecolor", null, null).falseColor,
        )
    }

    @Test
    fun `unknown tokens and ids fall back to defaults`() {
        val effects = FeedEffects.parse("sparkle, LUT , zebra", "not-a-look", null)
        assertEquals(FeedLutSelection.BuiltIn(FeedLut.LOG3G10_709), effects.lut)
        assertTrue(effects.zebra)
        assertFalse(effects.peaking)
        assertEquals(
            FeedFalseColorScale.STOPS,
            FeedEffects.parse("falsecolor", null, "bogus").falseColor,
        )
    }

    @Test
    fun `the 50-50 comparison needs a lut to compare against`() {
        val off = FeedEffects(splitComparison = FeedSplitOrientation.VERTICAL)
        assertNull(off.activeSplitComparison)

        val on =
            off.copy(lut = FeedLutSelection.BuiltIn(FeedLut.MONO))
        assertEquals(FeedSplitOrientation.VERTICAL, on.activeSplitComparison)
    }

    /** [tools] on, nothing pinned, the comparison armed with the given axis. */
    private fun assists(lut: FeedLut, split: FeedSplitOrientation, vararg tools: MonitorAssistTool): NikonAssists {
        val state = MonitorAssistState(pinnedNames = emptySet())
        state.syncVisible(tools.toSet())
        state.setSplitComparison(true, vertical = split == FeedSplitOrientation.VERTICAL)
        state.syncVisible(tools.toSet())
        return NikonAssists(state, FeedLutSelection.BuiltIn(lut)) {}
    }

    private fun NikonAssists.rendered(mode: MonitorDisplayMode, photography: Boolean = false) =
        feedEffects { shared.rendersLive(it, mode, photography) }

    @Test
    fun `clean view drops the comparison with the lut it belongs to`() {
        val assists = assists(FeedLut.MONO, FeedSplitOrientation.HORIZONTAL, MonitorAssistTool.LUT)
        assertEquals(FeedSplitOrientation.HORIZONTAL, assists.rendered(MonitorDisplayMode.LIVE).activeSplitComparison)
        // Clean drops an unpinned LUT, and the divider and labels have to leave with it.
        assertNull(assists.rendered(MonitorDisplayMode.CLEAN).activeSplitComparison)
        assists.shared.pinned = setOf(MonitorAssistTool.LUT)
        assertEquals(FeedSplitOrientation.HORIZONTAL, assists.rendered(MonitorDisplayMode.CLEAN).activeSplitComparison)
    }

    @Test
    fun `photography drops a video lut instead of grading an already-display-referred frame`() {
        // The reported bug: a LUT left on in video survived the flip to photo, so a Log to 709 look
        // landed on the stills live view, which is already display-referred, and the photo
        // toolbar has no LUT key to switch it off with.
        val assists =
            assists(FeedLut.LOG3G10_709, FeedSplitOrientation.VERTICAL, MonitorAssistTool.LUT, MonitorAssistTool.PEAK)

        val photo = assists.rendered(MonitorDisplayMode.LIVE, photography = true)
        assertNull(photo.lut)
        // The divider and its LOG/LUT labels ride the look, so they leave with it.
        assertNull(photo.activeSplitComparison)
        // Peaking is an exposure aid photographers do use; dropping the LUT must not take it.
        assertTrue(photo.peaking)

        // Nothing is persisted by the filter: video still renders the operator's look untouched.
        val video = assists.rendered(MonitorDisplayMode.LIVE)
        assertEquals(FeedLutSelection.BuiltIn(FeedLut.LOG3G10_709), video.lut)
        assertEquals(FeedSplitOrientation.VERTICAL, video.activeSplitComparison)
    }

    @Test
    fun `photography keeps its own aids and drops only the cinema-only ones`() {
        // One gate for every render path, so the tool table is the single source of truth.
        val state = MonitorAssistState(pinnedNames = emptySet())
        state.syncVisible(MonitorAssistTool.entries.toSet())
        for (tool in MonitorAssistTool.entries) {
            state.pinned = emptySet()
            assertEquals(
                tool.appliesToPhotography,
                state.rendersLive(tool, MonitorDisplayMode.LIVE, photography = true),
                "photography rendering disagrees with the tool table for $tool",
            )
            // A clean-view pin cannot smuggle a cinema-only tool into the photo feed either.
            state.pinned = setOf(tool)
            assertEquals(
                tool.appliesToPhotography,
                state.rendersLive(tool, MonitorDisplayMode.CLEAN, photography = true),
                "a clean pin overrode the photography filter for $tool",
            )
        }
    }

    @Test
    fun `the comparison orientation is carried even while it is switched off`() {
        // "Preserve the operator's orientation preference while the feature is enabled": the
        // record keeps the choice, and only `activeSplitComparison` gates it.
        val effects = FeedEffects(splitComparison = FeedSplitOrientation.HORIZONTAL)
        assertEquals(FeedSplitOrientation.HORIZONTAL, effects.splitComparison)
        assertNull(effects.activeSplitComparison)
    }

    @Test
    fun `the plan splits only when the base cube is the operator's lut`() {
        val lut = FeedLutSelection.BuiltIn(FeedLut.MONO)
        val split = FeedSplitOrientation.VERTICAL
        fun plan(effects: FeedEffects, cube: MonitorLUTCube? = testCube()) =
            FeedEffectsRenderPlan(
                effects = effects,
                configuration = testRenderConfiguration(),
                baseCube = cube,
                limitsPaintCube = null,
                limitsWeightCube = null,
            )

        assertEquals(
            split,
            plan(FeedEffects(lut = lut, splitComparison = split)).splitComparison,
        )
        // STOPS/IRE false colour REPLACES the base cube with exposure zones — that is the
        // monitoring image, and there is no ungraded half of it to compare against.
        assertNull(
            plan(
                FeedEffects(
                    lut = lut,
                    falseColor = FeedFalseColorScale.STOPS,
                    splitComparison = split,
                ),
            ).splitComparison,
        )
        // LIMITS keeps the LUT as its base and paints crush/clip over it, so it still splits.
        assertEquals(
            split,
            plan(
                FeedEffects(
                    lut = lut,
                    falseColor = FeedFalseColorScale.LIMITS,
                    splitComparison = split,
                ),
            ).splitComparison,
        )
        // No cube resolved (core refused, or a stored file went missing): nothing to split.
        assertNull(plan(FeedEffects(lut = lut, splitComparison = split), cube = null).splitComparison)
    }

    private fun testCube(): MonitorLUTCube = MonitorLUTCube(2, ByteArray(2 * 2 * 2 * 4))

    private fun testRenderConfiguration(): FeedEffectsRenderConfiguration =
        FeedEffectsRenderConfiguration(
            curveOrdinal = 0,
            clipNative = 255f,
            deLogCurve = floatArrayOf(0f, 0.25f, 0.5f, 0.75f, 1f),
            peakingRatioThreshold = 1.35f,
            peakingNoiseGate = 0.008f,
            peakingColor = floatArrayOf(1f, 0f, 0f),
            highlightEnabled = false,
            highlightCode = 1f,
            highlightColor = floatArrayOf(1f, 1f, 1f),
            midtoneEnabled = false,
            midtoneCode = 0.5f,
            midtoneColor = floatArrayOf(1f, 1f, 1f),
        )

    @Test
    fun `wire ordinals stay pinned to the Swift facade contract`() {
        // FeedEffectsWire.look / .curve / .bakedFalseColor in the Swift facade.
        assertEquals(0, FeedLut.LOG3G10_709.wireOrdinal)
        assertEquals(1, FeedLut.NLOG_709.wireOrdinal)
        assertEquals(2, FeedLut.MONO.wireOrdinal)
        assertEquals(3, FeedLut.R3D_NE_MONITOR.wireOrdinal)
        assertEquals(0, FeedFalseColorScale.STOPS.wireOrdinal)
        assertEquals(1, FeedFalseColorScale.IRE.wireOrdinal)
        assertEquals(2, FeedFalseColorScale.LIMITS.wireOrdinal)
        // Peaking.Sensitivity / Peaking.Color / Zebra.StripeColor / zebra unit: the shared enum ordinal is the wire value.
        assertEquals(listOf("LOW", "MED", "HIGH"), MonitorPeakingSense.entries.map { it.name })
        assertEquals(listOf("WHITE", "BLUE", "RED", "GREEN"), MonitorPeakingColor.entries.map { it.name })
        assertEquals(listOf("WHITE", "AMBER", "RED", "CYAN", "GREEN"), MonitorZebraPaint.entries.map { it.name })
        assertEquals(listOf("NATIVE", "IRE"), MonitorZebraUnit.entries.map { it.name })
    }

    @Test
    fun `stop ruler end labels stay inside the shared false colour panel`() {
        val reference = FeedFalseColorReference(0, emptyList(), floatArrayOf(0f, 0.3f, 0.5f, 0.6f, 0.75f, 1f))
        val copy = FalseColorReferenceCopy("Stops", listOf("Min", "-3", "18%", "Skin", "+2", "Max"), emptyList(), emptyList())
        val fractions =
            FalseColorReferencePresentation(FeedFalseColorScale.STOPS, reference).referenceValues(copy).markers.map { it.fraction }
        // The shared ruler starts a label 10 dp before its fraction of the 264 dp panel.
        assertEquals(16.0 / 264, fractions.first(), absoluteTolerance = 1e-9)
        assertEquals(1 - 16.0 / 264, fractions.last(), absoluteTolerance = 1e-9)
        assertEquals(listOf(0.3, 0.5, 0.6, 0.75), fractions.subList(1, 5).map { Math.round(it * 100) / 100.0 })
    }
}
