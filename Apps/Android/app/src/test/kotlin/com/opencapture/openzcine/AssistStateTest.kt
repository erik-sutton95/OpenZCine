package com.opencapture.openzcine

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNull
import kotlin.test.assertTrue

class AssistStateTest {
    @Test
    fun `lut toggles on with the default look and off again`() {
        val state = AssistState(FeedEffects.NONE, null)
        state.toggle(AssistTool.LUT)
        assertEquals(FeedLut.LOG3G10_709, state.effects.lut)
        assertTrue(state.isOn(AssistTool.LUT))
        state.toggle(AssistTool.LUT)
        assertNull(state.effects.lut)
        assertTrue(state.effects.isIdentity)
    }

    @Test
    fun `false colour replaces the lut and restores the selected look`() {
        val state = AssistState(FeedEffects(lut = FeedLut.MONO), null)
        state.toggle(AssistTool.FALSE)
        assertNull(state.effects.lut)
        assertEquals(FeedFalseColorScale.STOPS, state.effects.falseColor)
        state.toggle(AssistTool.LUT)
        assertNull(state.effects.falseColor)
        assertEquals(FeedLut.MONO, state.effects.lut)
    }

    @Test
    fun `scopes are independently active and reactivation updates recency`() {
        val state = AssistState(FeedEffects.NONE, null)
        state.toggle(AssistTool.WAVE)
        assertEquals(ScopeKind.WAVEFORM, state.scope)
        state.toggle(AssistTool.VECTOR)
        assertEquals(ScopeKind.VECTORSCOPE, state.scope)
        assertTrue(state.isOn(AssistTool.WAVE))
        assertTrue(state.isOn(AssistTool.VECTOR))
        assertEquals(
            listOf(ScopeKind.WAVEFORM, ScopeKind.VECTORSCOPE),
            state.scopeActivationOrder,
        )
        state.toggle(AssistTool.WAVE)
        assertFalse(state.isOn(AssistTool.WAVE))
        state.toggle(AssistTool.WAVE)
        assertTrue(state.isOn(AssistTool.WAVE))
        assertEquals(ScopeKind.WAVEFORM, state.scope)
        assertEquals(
            listOf(ScopeKind.VECTORSCOPE, ScopeKind.WAVEFORM),
            state.scopeActivationOrder,
        )
        assertEquals(
            listOf(ScopeKind.WAVEFORM, ScopeKind.VECTORSCOPE),
            state.displayedPortraitScopes,
        )
    }

    @Test
    fun `effects state feeds the engine input`() {
        val state = AssistState(FeedEffects.NONE, null)
        state.toggle(AssistTool.PEAK)
        state.toggle(AssistTool.ZEBRA)
        assertEquals(state.effects, FeedEffectsState.current)
        assertTrue(FeedEffectsState.current.peaking)
        assertTrue(FeedEffectsState.current.zebra)
    }

    @Test
    fun `every toggle persists, and the token grammar round-trips`() {
        var savedEffects: FeedEffects? = null
        var savedScope: ScopeKind? = null
        val state =
            AssistState(FeedEffects.NONE, null) { effects, scope ->
                savedEffects = effects
                savedScope = scope
            }
        state.toggle(AssistTool.LUT)
        state.toggle(AssistTool.PEAK)
        state.toggle(AssistTool.HISTO)
        assertEquals(state.effects, savedEffects)
        assertEquals(ScopeKind.HISTOGRAM, savedScope)

        // The persisted form is the zc.assist token grammar — parse restores it.
        val effects = savedEffects!!
        val restored = AssistState.tokens(effects).let { FeedEffects.parse(it, effects.lut?.id, effects.falseColor?.id) }
        assertEquals(effects, restored)
    }

    @Test
    fun `inactive image-assist selections restore and become active choices`() {
        val preferences = TestSharedPreferences()
        preferences.edit()
            .putString("tokens", "zebra")
            .putString("lut", FeedLut.MONO.id)
            .putString("fcScale", FeedFalseColorScale.IRE.id)
            .apply()

        val state = AssistState.restore(preferences, FeedEffects.NONE, null)
        assertTrue(state.effects.zebra)
        assertEquals(FeedLut.MONO, state.selectedLut)
        assertEquals(FeedFalseColorScale.IRE, state.selectedFalseColorScale)

        state.toggle(AssistTool.LUT)
        assertEquals(FeedLut.MONO, state.effects.lut)
        state.toggle(AssistTool.FALSE)
        assertEquals(FeedFalseColorScale.IRE, state.effects.falseColor)
    }

    @Test
    fun `changing a stored look persists even while that assist is off`() {
        val preferences = TestSharedPreferences()
        val state = AssistState.restore(preferences, FeedEffects.NONE, null)

        state.selectLut(FeedLut.NLOG_709)
        state.selectFalseColorScale(FeedFalseColorScale.IRE)

        val restored = AssistState.restore(preferences, FeedEffects.NONE, null)
        assertEquals(FeedLut.NLOG_709, restored.selectedLut)
        assertEquals(FeedFalseColorScale.IRE, restored.selectedFalseColorScale)
        restored.toggle(AssistTool.LUT)
        assertEquals(FeedLut.NLOG_709, restored.effects.lut)
    }

    @Test
    fun `legacy single scope migrates without inventing portrait recency`() {
        val preferences = TestSharedPreferences()
        preferences.edit().putString("scope", "vector").apply()

        val state = AssistState.restore(preferences, FeedEffects.NONE, null)

        assertEquals(setOf(ScopeKind.VECTORSCOPE), state.selectedScopes)
        assertEquals(emptyList(), state.scopeActivationOrder)
        assertEquals(listOf(ScopeKind.VECTORSCOPE), state.displayedPortraitScopes)
    }

    @Test
    fun `multi scope persistence keeps canonical selection and portrait recency`() {
        val preferences = TestSharedPreferences()
        preferences.edit()
            .putString("scopes", "wave,parade,histo,lights")
            .putString("scopeActivationOrder", "wave,parade,histo,lights")
            .apply()

        val state = AssistState.restore(preferences, FeedEffects.NONE, null)

        assertEquals(
            setOf(
                ScopeKind.WAVEFORM,
                ScopeKind.PARADE,
                ScopeKind.HISTOGRAM,
                ScopeKind.TRAFFIC_LIGHTS,
            ),
            state.selectedScopes,
        )
        assertEquals(
            listOf(ScopeKind.HISTOGRAM, ScopeKind.TRAFFIC_LIGHTS),
            state.displayedPortraitScopes,
        )

        state.toggle(AssistTool.WAVE)
        assertEquals("parade,histo,lights", preferences.getString("scopes", null))
        assertEquals("parade,histo,lights", preferences.getString("scopeActivationOrder", null))
        assertEquals("lights", preferences.getString("scope", null))
    }
}
