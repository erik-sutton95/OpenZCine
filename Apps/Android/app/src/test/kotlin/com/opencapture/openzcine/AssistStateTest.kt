package com.opencapture.openzcine

import com.opencapture.openzcine.lut.StoredLutCategory
import com.opencapture.openzcine.lut.StoredLutSelection
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
        assertEquals(FeedLutSelection.BuiltIn(FeedLut.LOG3G10_709), state.effects.lut)
        assertTrue(state.isOn(AssistTool.LUT))
        state.toggle(AssistTool.LUT)
        assertNull(state.effects.lut)
        assertTrue(state.effects.isIdentity)
    }

    @Test
    fun `stops false colour takes render precedence but preserves lut activation`() {
        val state = AssistState(FeedEffects(lut = FeedLutSelection.BuiltIn(FeedLut.MONO)), null)
        state.toggle(AssistTool.FALSE)
        assertEquals(FeedLutSelection.BuiltIn(FeedLut.MONO), state.effects.lut)
        assertEquals(FeedFalseColorScale.STOPS, state.effects.falseColor)
        state.toggle(AssistTool.FALSE)
        assertNull(state.effects.falseColor)
        assertEquals(FeedLutSelection.BuiltIn(FeedLut.MONO), state.effects.lut)
    }

    @Test
    fun `limits to stops keeps the active lut and false off resumes it`() {
        val mono = FeedLutSelection.BuiltIn(FeedLut.MONO)
        val state = AssistState(FeedEffects(lut = mono), null)

        state.selectFalseColorScale(FeedFalseColorScale.LIMITS)
        state.toggle(AssistTool.FALSE)

        assertEquals(FeedFalseColorScale.LIMITS, state.effects.falseColor)
        assertEquals(mono, state.effects.lut)

        state.selectFalseColorScale(FeedFalseColorScale.STOPS)
        assertEquals(FeedFalseColorScale.STOPS, state.effects.falseColor)
        assertEquals(mono, state.effects.lut)

        state.toggle(AssistTool.FALSE)
        assertNull(state.effects.falseColor)
        assertEquals(mono, state.effects.lut)
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
    fun `portrait fit refuses a third scope but still allows deactivation`() {
        val state = AssistState(FeedEffects.NONE, null)
        assertTrue(state.toggle(AssistTool.WAVE, maximumActiveScopes = 2))
        assertTrue(state.toggle(AssistTool.VECTOR, maximumActiveScopes = 2))

        assertFalse(state.toggle(AssistTool.HISTO, maximumActiveScopes = 2))
        assertEquals(setOf(ScopeKind.WAVEFORM, ScopeKind.VECTORSCOPE), state.selectedScopes)
        assertTrue(state.toggle(AssistTool.WAVE, maximumActiveScopes = 2))
        assertEquals(setOf(ScopeKind.VECTORSCOPE), state.selectedScopes)
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
    fun `initial effects mirror activates explicitly after construction`() {
        FeedEffectsState.current = FeedEffects.NONE
        val expected = FeedEffects(peaking = true, zebra = true)
        val state = AssistState(expected, null)

        assertEquals(FeedEffects.NONE, FeedEffectsState.current)
        state.activateEffectsMirror()

        assertEquals(expected, FeedEffectsState.current)
    }

    @Test
    fun `audio meter toggle persists independently of image assists and scopes`() {
        val preferences = TestSharedPreferences()
        val state = AssistState.restore(preferences, null, null)

        assertFalse(state.isOn(AssistTool.AUDIO))
        state.toggle(AssistTool.AUDIO)

        assertTrue(state.isOn(AssistTool.AUDIO))
        assertTrue(preferences.getBoolean("audioMeters", false))
        assertTrue(AssistState.restore(preferences, null, null).isOn(AssistTool.AUDIO))

        state.toggle(AssistTool.AUDIO)
        assertFalse(preferences.getBoolean("audioMeters", true))
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
        val selectedBuiltIn = (effects.lut as? FeedLutSelection.BuiltIn)?.value
        val restored =
            AssistState.tokens(effects).let {
                FeedEffects.parse(it, selectedBuiltIn?.id, effects.falseColor?.id)
            }
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

        val state = AssistState.restore(preferences, null, null)
        assertTrue(state.effects.zebra)
        assertEquals(FeedLutSelection.BuiltIn(FeedLut.MONO), state.selectedLut)
        assertEquals(FeedFalseColorScale.IRE, state.selectedFalseColorScale)

        state.toggle(AssistTool.LUT)
        assertEquals(FeedLutSelection.BuiltIn(FeedLut.MONO), state.effects.lut)
        state.toggle(AssistTool.FALSE)
        assertEquals(FeedFalseColorScale.IRE, state.effects.falseColor)
    }

    @Test
    fun `changing a stored look persists even while that assist is off`() {
        val preferences = TestSharedPreferences()
        val state = AssistState.restore(preferences, null, null)

        state.selectLut(FeedLut.NLOG_709)
        state.selectFalseColorScale(FeedFalseColorScale.IRE)

        val restored = AssistState.restore(preferences, null, null)
        assertEquals(FeedLutSelection.BuiltIn(FeedLut.NLOG_709), restored.selectedLut)
        assertEquals(FeedFalseColorScale.IRE, restored.selectedFalseColorScale)
        restored.toggle(AssistTool.LUT)
        assertEquals(FeedLutSelection.BuiltIn(FeedLut.NLOG_709), restored.effects.lut)
    }

    @Test
    fun `validated app private stored selection survives restart and missing files fall back safely`() {
        val preferences = TestSharedPreferences()
        val selection =
            requireNotNull(
                StoredLutSelection.fromPersisted(
                    StoredLutCategory.CUSTOM.name,
                    "operator-look-a1b2c3d4e5f6.cube",
                ),
            )
        val state = AssistState.restore(preferences, null, null)

        state.selectStoredLut(selection)
        state.toggle(AssistTool.LUT)

        val restored =
            AssistState.restore(
                preferences,
                null,
                null,
                availableStoredLut = { it == selection },
            )
        assertEquals(FeedLutSelection.Stored(selection), restored.selectedLut)
        assertEquals(FeedLutSelection.Stored(selection), restored.effects.lut)
        assertEquals(StoredLutCategory.CUSTOM.name, preferences.getString("lut.selection.category.v1", null))
        assertEquals(selection.fileName, preferences.getString("lut.selection.file.v1", null))
        assertFalse(
            preferences.all.keys.any { key ->
                key.contains("uri", ignoreCase = true) || key.contains("path", ignoreCase = true)
            },
        )

        val unavailable =
            AssistState.restore(
                preferences,
                null,
                null,
                availableStoredLut = { false },
            )
        assertEquals(FeedLutSelection.BuiltIn(FeedLut.LOG3G10_709), unavailable.selectedLut)
        assertEquals(FeedLutSelection.BuiltIn(FeedLut.LOG3G10_709), unavailable.effects.lut)
    }

    @Test
    fun `legacy single scope migrates without inventing portrait recency`() {
        val preferences = TestSharedPreferences()
        preferences.edit().putString("scope", "vector").apply()

        val state = AssistState.restore(preferences, null, null)

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

        val state = AssistState.restore(preferences, null, null)

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

    @Test
    fun `reconnecting after a runtime effect toggle restores scopes instead of treating state as an intent`() {
        val preferences = TestSharedPreferences()
        preferences.edit()
            .putString("tokens", "zebra")
            .putString("scopes", "wave,vector")
            .putString("scopeActivationOrder", "wave,vector")
            .apply()
        val firstSession = AssistState.restore(preferences, null, null)
        firstSession.toggle(AssistTool.PEAK)
        assertTrue(FeedEffectsState.current.peaking)

        val reconnected = AssistState.restore(preferences, null, null)

        assertTrue(reconnected.effects.peaking)
        assertTrue(reconnected.effects.zebra)
        assertEquals(setOf(ScopeKind.WAVEFORM, ScopeKind.VECTORSCOPE), reconnected.selectedScopes)
        assertEquals(listOf(ScopeKind.WAVEFORM, ScopeKind.VECTORSCOPE), reconnected.scopeActivationOrder)
    }

    @Test
    fun `explicit empty debug effect override stays distinct from a normal restore`() {
        val preferences = TestSharedPreferences()
        preferences.edit()
            .putString("tokens", "zebra")
            .putString("scopes", "wave")
            .apply()

        val overridden = AssistState.restore(preferences, FeedEffects.NONE, null)

        assertTrue(overridden.effects.isIdentity)
        assertTrue(overridden.selectedScopes.isEmpty())
    }

    @Test
    fun `front pinning leads photography with EV and seats it second for video`() {
        val order =
            listOf(
                AssistTool.PEAK,
                AssistTool.FALSE,
                AssistTool.HISTO,
                AssistTool.GRID,
                AssistTool.EV,
                AssistTool.LEVEL,
            )

        // Photography: EV takes the lead slot (Android has no instant playback).
        assertEquals(
            listOf(
                AssistTool.EV,
                AssistTool.PEAK,
                AssistTool.FALSE,
                AssistTool.HISTO,
                AssistTool.GRID,
                AssistTool.LEVEL,
            ),
            frontPinnedAssistTools(order, photography = true),
        )

        // Video: the leading tool keeps its slot and EV seats second.
        assertEquals(
            listOf(
                AssistTool.PEAK,
                AssistTool.EV,
                AssistTool.FALSE,
                AssistTool.HISTO,
                AssistTool.GRID,
                AssistTool.LEVEL,
            ),
            frontPinnedAssistTools(order, photography = false),
        )

        // Already at or before slot 1: untouched. Hidden EV: untouched.
        val evSecond = listOf(AssistTool.PEAK, AssistTool.EV, AssistTool.FALSE)
        assertEquals(evSecond, frontPinnedAssistTools(evSecond, photography = false))
        val noEv = listOf(AssistTool.PEAK, AssistTool.FALSE)
        assertEquals(noEv, frontPinnedAssistTools(noEv, photography = true))
        assertEquals(noEv, frontPinnedAssistTools(noEv, photography = false))
    }
}
