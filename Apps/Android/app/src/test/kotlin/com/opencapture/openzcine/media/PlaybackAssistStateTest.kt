package com.opencapture.openzcine.media

import com.opencapture.openzcine.AssistTool
import com.opencapture.openzcine.AssistState
import com.opencapture.openzcine.FeedEffects
import com.opencapture.openzcine.FeedEffectsState
import com.opencapture.openzcine.FeedFalseColorScale
import com.opencapture.openzcine.FeedLut
import com.opencapture.openzcine.FeedLutSelection
import com.opencapture.openzcine.TestSharedPreferences
import com.opencapture.openzcine.settings.LocalDesqueezeOrientation
import com.opencapture.openzcine.settings.LocalDesqueezeRatio
import com.opencapture.openzcine.settings.LocalFramingAspectRatio
import com.opencapture.openzcine.settings.LocalFramingAssistConfiguration
import com.opencapture.openzcine.settings.LocalFramingGuideFamily
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertTrue

class PlaybackAssistStateTest {
    @Test
    fun `playback visibility persists without replacing live effect state`() {
        val preferences = TestSharedPreferences()
        FeedEffectsState.current = FeedEffects(peaking = true)

        val state = PlaybackAssistState.restore(preferences)
        assertFalse(state.hasAnyVisibleAssist)
        state.toggle(AssistTool.LUT)
        state.toggle(AssistTool.WAVE)
        state.toggle(AssistTool.AUDIO)
        state.toggle(AssistTool.GUIDES)

        assertEquals(FeedEffects(peaking = true), FeedEffectsState.current)
        val restored = PlaybackAssistState.restore(preferences)
        assertTrue(restored.isOn(AssistTool.LUT))
        assertTrue(restored.isOn(AssistTool.WAVE))
        assertTrue(restored.isOn(AssistTool.AUDIO))
        assertTrue(restored.isOn(AssistTool.GUIDES))
        assertTrue(restored.hasAnyVisibleAssist)
    }

    @Test
    fun `playback framing changes visibility but retains configured values`() {
        val preferences = TestSharedPreferences()
        val state = PlaybackAssistState.restore(preferences)
        state.toggle(AssistTool.GRID)
        state.toggle(AssistTool.DESQ)

        val playback = state.framingConfiguration(configuredFraming())

        assertFalse(playback.guidesVisible)
        assertTrue(playback.gridVisible)
        assertFalse(playback.centerCrosshairEnabled)
        assertTrue(playback.desqueezeEnabled)
        assertEquals(setOf(LocalFramingAspectRatio.RATIO_239), playback.selectedGuideRatios)
        assertEquals(LocalDesqueezeRatio.X165, playback.desqueezeRatio)
        assertEquals(LocalDesqueezeOrientation.VERTICAL, playback.desqueezeOrientation)
    }

    @Test
    fun `playback visibility uses live operator LUT and false color configuration`() {
        val preferences = TestSharedPreferences()
        preferences.edit()
            .putString("tokens", "lut,falsecolor")
            .putString("lut", FeedLut.LOG3G10_709.id)
            .putString("fcScale", FeedFalseColorScale.STOPS.id)
            .apply()
        val liveConfiguration =
            AssistState(
                initialEffects =
                    FeedEffects(
                        lut = FeedLutSelection.BuiltIn(FeedLut.NLOG_709),
                        falseColor = FeedFalseColorScale.IRE,
                    ),
                initialScope = null,
                initialLut = FeedLutSelection.BuiltIn(FeedLut.NLOG_709),
                initialFalseColorScale = FeedFalseColorScale.IRE,
            )

        val playback = PlaybackAssistState.restore(preferences, liveConfiguration)

        assertEquals(FeedLutSelection.BuiltIn(FeedLut.NLOG_709), playback.assists.effects.lut)
        assertEquals(FeedFalseColorScale.IRE, playback.assists.effects.falseColor)
        assertEquals(FeedLut.LOG3G10_709.id, preferences.getString("lut", null))
        assertEquals(FeedFalseColorScale.STOPS.id, preferences.getString("fcScale", null))
    }

    @Test
    fun `playback option tools match iOS long press contract`() {
        val configurable = AssistTool.entries.filter(::hasPlaybackAssistOptions).toSet()

        assertEquals(AssistTool.entries.toSet() - AssistTool.AUDIO, configurable)
        assertFalse(hasPlaybackAssistOptions(AssistTool.AUDIO))
        assertTrue(hasPlaybackAssistOptions(AssistTool.CROSS))
    }

    @Test
    fun `playback selections persist once in shared configuration and keep visibility separate`() {
        val sharedPreferences = TestSharedPreferences()
        val playbackPreferences = TestSharedPreferences()
        val shared = AssistState.restore(sharedPreferences, null, null)
        val playback = PlaybackAssistState.restore(playbackPreferences, shared)

        playback.setVisible(AssistTool.LUT, true)
        playback.selectSharedLut(shared, FeedLut.MONO)
        playback.selectSharedFalseColorScale(shared, FeedFalseColorScale.LIMITS)

        assertTrue(playback.isOn(AssistTool.LUT))
        assertFalse(shared.isOn(AssistTool.LUT))
        assertEquals(FeedLutSelection.BuiltIn(FeedLut.MONO), playback.assists.effects.lut)
        assertEquals(FeedLutSelection.BuiltIn(FeedLut.MONO), shared.selectedLut)
        assertEquals(FeedFalseColorScale.LIMITS, playback.assists.selectedFalseColorScale)
        assertEquals(FeedFalseColorScale.LIMITS, shared.selectedFalseColorScale)
        assertEquals(FeedLut.MONO.id, sharedPreferences.getString("lut", null))
        assertEquals(FeedFalseColorScale.LIMITS.id, sharedPreferences.getString("fcScale", null))
        assertFalse(playbackPreferences.contains("lut"))
        assertFalse(playbackPreferences.contains("fcScale"))
    }

    private fun configuredFraming(): LocalFramingAssistConfiguration =
        LocalFramingAssistConfiguration(
            guidesVisible = true,
            guideFamily = LocalFramingGuideFamily.FILM,
            selectedGuideRatios = setOf(LocalFramingAspectRatio.RATIO_239),
            guideMaskEnabled = true,
            gridVisible = false,
            ruleOfThirdsEnabled = true,
            phiGridEnabled = false,
            diagonalGridEnabled = false,
            centerCrosshairEnabled = true,
            desqueezeEnabled = false,
            desqueezeRatio = LocalDesqueezeRatio.X165,
            desqueezeOrientation = LocalDesqueezeOrientation.VERTICAL,
        )
}
