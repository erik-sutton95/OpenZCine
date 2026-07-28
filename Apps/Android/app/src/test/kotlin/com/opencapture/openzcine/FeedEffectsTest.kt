package com.opencapture.openzcine

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

    @Test
    fun `clean view drops the comparison with the lut it belongs to`() {
        val effects =
            FeedEffects(
                lut = FeedLutSelection.BuiltIn(FeedLut.MONO),
                splitComparison = FeedSplitOrientation.HORIZONTAL,
            )
        assertEquals(
            FeedSplitOrientation.HORIZONTAL,
            renderedFeedEffects(effects, MonitorDisplayMode.LIVE, emptySet()).activeSplitComparison,
        )
        // Clean drops an unpinned LUT, and the divider and labels have to leave with it.
        assertNull(
            renderedFeedEffects(effects, MonitorDisplayMode.CLEAN, emptySet())
                .activeSplitComparison,
        )
        assertEquals(
            FeedSplitOrientation.HORIZONTAL,
            renderedFeedEffects(effects, MonitorDisplayMode.CLEAN, setOf(AssistTool.LUT))
                .activeSplitComparison,
        )
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
        fun plan(effects: FeedEffects, cube: FeedEffectsCube? = testCube()) =
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

    private fun testCube(): FeedEffectsCube = FeedEffectsCube(2, ByteArray(2 * 2 * 2 * 4))

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
    }
}
