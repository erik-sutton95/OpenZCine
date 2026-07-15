package com.opencapture.openzcine

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
    fun `false colour replaces the lut like iOS`() {
        val effects = FeedEffects.parse("lut,falsecolor", "mono", "ire")
        assertNull(effects.lut)
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
    fun `wire ordinals stay pinned to the Swift facade contract`() {
        // FeedEffectsWire.look / .curve / .bakedFalseColor in the Swift facade.
        assertEquals(0, FeedLut.LOG3G10_709.wireOrdinal)
        assertEquals(1, FeedLut.NLOG_709.wireOrdinal)
        assertEquals(2, FeedLut.MONO.wireOrdinal)
        assertEquals(0, FeedFalseColorScale.STOPS.wireOrdinal)
        assertEquals(1, FeedFalseColorScale.IRE.wireOrdinal)
    }
}
