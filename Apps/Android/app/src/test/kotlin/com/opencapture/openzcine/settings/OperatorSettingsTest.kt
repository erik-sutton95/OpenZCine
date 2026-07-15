package com.opencapture.openzcine.settings

import com.opencapture.openzcine.AssistTool
import com.opencapture.openzcine.FeedPeakingColor
import com.opencapture.openzcine.FeedPeakingSensitivity
import com.opencapture.openzcine.FeedZebraStripeColor
import com.opencapture.openzcine.FeedZebraUnit
import com.opencapture.openzcine.TestSharedPreferences
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertTrue

class OperatorSettingsTest {
    private val store = TestSharedPreferences()

    @Test
    fun `readouts default visible`() {
        val settings = OperatorSettings(store)
        assertTrue(settings.statusBarVisible.value)
        assertTrue(settings.assistToolbarVisible.value)
        assertTrue(settings.cameraValuesVisible.value)
        assertTrue(settings.recReadoutVisible.value)
        assertTrue(settings.codecReadoutVisible.value)
        assertTrue(settings.mediaReadoutVisible.value)
        assertTrue(settings.fpsReadoutVisible.value)
        assertTrue(settings.recordConfirmationEnabled.value)
        assertFalse(settings.mediaRemoteShutterEnabled.value)
        assertTrue(settings.hapticsEnabled.value)
        assertTrue(settings.keepScreenAwake.value)
        assertFalse(settings.ruleOfThirdsEnabled.value)
        assertFalse(settings.centerCrosshairEnabled.value)
        assertFalse(settings.levelAssistEnabled.value)
        assertEquals(LocalFramingGuide.OFF, settings.framingGuide)
        assertEquals(LocalDesqueezePresentation.OFF, settings.desqueezePresentation)
        assertEquals(LocalLevelStyle.HORIZON, settings.levelStyle)
        assertTrue(settings.feedEffectsConfiguration.falseColorReferenceEnabled)
        assertEquals(FeedPeakingSensitivity.MEDIUM, settings.feedEffectsConfiguration.peakingSensitivity)
        assertEquals(FeedPeakingColor.RED, settings.feedEffectsConfiguration.peakingColor)
        assertEquals(FeedZebraUnit.IRE, settings.feedEffectsConfiguration.zebraUnit)
        assertEquals(100f, settings.feedEffectsConfiguration.zebraHighlightIre)
        assertEquals(55f, settings.feedEffectsConfiguration.zebraMidtoneIre)
        assertEquals(ScopeWaveformMode.LUMA, settings.scopeAssistConfiguration.waveformMode)
        assertEquals(ScopeParadeMode.RGB, settings.scopeAssistConfiguration.paradeMode)
        assertEquals(ScopeVectorscopeZoom.X1, settings.scopeAssistConfiguration.vectorscopeZoom)
    }

    @Test
    fun `toggle writes through and survives a reload`() {
        OperatorSettings(store).apply {
            fpsReadoutVisible.toggle()
        }
        val reloaded = OperatorSettings(store)
        assertEquals(false, reloaded.fpsReadoutVisible.value)
    }

    @Test
    fun `storage keys never collide`() {
        val keys = OperatorSettings(store).all.map { it.key }
        assertEquals(keys.size, keys.toSet().size)
    }

    @Test
    fun `local monitor controls persist and drive the screen awake policy`() {
        OperatorSettings(store).apply {
            statusBarVisible.toggle()
            assistToolbarVisible.toggle()
            cameraValuesVisible.toggle()
            recordConfirmationEnabled.toggle()
            mediaRemoteShutterEnabled.toggle()
            keepScreenAwake.toggle()
        }

        val restored = OperatorSettings(store)
        assertFalse(restored.statusBarVisible.value)
        assertFalse(restored.assistToolbarVisible.value)
        assertFalse(restored.cameraValuesVisible.value)
        assertFalse(restored.recordConfirmationEnabled.value)
        assertTrue(restored.mediaRemoteShutterEnabled.value)
        assertFalse(restored.shouldKeepScreenAwake(monitorPresented = true))
        assertFalse(restored.shouldKeepScreenAwake(monitorPresented = false))
    }

    @Test
    fun `assist toolbar visibility retains LUT and survives a reload`() {
        val settings = OperatorSettings(store)
        settings.toggleAssistToolbarToolVisibility(AssistTool.LUT)
        settings.toggleAssistToolbarToolVisibility(AssistTool.PEAK)

        assertTrue(settings.isAssistToolbarToolVisible(AssistTool.LUT))
        assertFalse(settings.isAssistToolbarToolVisible(AssistTool.PEAK))
        assertFalse(OperatorSettings(store).isAssistToolbarToolVisible(AssistTool.PEAK))
    }

    @Test
    fun `legacy visible assist set adds new tools once without undoing a later hide`() {
        store.edit()
            .putStringSet("display.assistToolbar.visible.v1", linkedSetOf("LUT", "PEAK"))
            .apply()

        val migrated = OperatorSettings(store)
        assertTrue(migrated.isAssistToolbarToolVisible(AssistTool.LIGHTS))
        assertTrue(migrated.isAssistToolbarToolVisible(AssistTool.AUDIO))
        assertTrue(migrated.isAssistToolbarToolVisible(AssistTool.PEAK))
        assertFalse(migrated.isAssistToolbarToolVisible(AssistTool.WAVE))

        migrated.toggleAssistToolbarToolVisibility(AssistTool.LIGHTS)
        migrated.toggleAssistToolbarToolVisibility(AssistTool.AUDIO)
        assertFalse(OperatorSettings(store).isAssistToolbarToolVisible(AssistTool.LIGHTS))
        assertFalse(OperatorSettings(store).isAssistToolbarToolVisible(AssistTool.AUDIO))
    }

    @Test
    fun `toolbar order reconciles malformed stored data and retains moves`() {
        store.edit()
            .putString("display.assistToolbar.order.v1", "VECTOR,UNKNOWN,VECTOR,LUT")
            .apply()

        val settings = OperatorSettings(store)
        assertEquals(AssistTool.VECTOR, settings.assistToolbarOrder.first())
        assertEquals(AssistTool.LUT, settings.assistToolbarOrder[1])
        assertEquals(AssistTool.entries.toSet(), settings.assistToolbarOrder.toSet())

        settings.moveAssistToolbarTool(AssistTool.LUT, direction = -1)
        assertEquals(AssistTool.LUT, OperatorSettings(store).assistToolbarOrder.first())
    }

    @Test
    fun `toolbar reset restores every currently supported tool`() {
        val settings = OperatorSettings(store)
        settings.toggleAssistToolbarToolVisibility(AssistTool.WAVE)
        settings.moveAssistToolbarTool(AssistTool.VECTOR, direction = -1)
        settings.resetAssistToolbarPreferences()

        assertEquals(AssistTool.entries.toList(), settings.assistToolbarOrder)
        assertEquals(AssistTool.entries.toList(), settings.visibleAssistToolbarTools)
    }

    @Test
    fun `audio remains in the trailing toolbar section when its stored order moves`() {
        val settings = OperatorSettings(store)
        while (settings.assistToolbarOrder.indexOf(AssistTool.AUDIO) > 0) {
            settings.moveAssistToolbarTool(AssistTool.AUDIO, direction = -1)
        }

        assertEquals(AssistTool.AUDIO, settings.assistToolbarOrder.first())
        assertEquals(AssistTool.AUDIO, settings.visibleAssistToolbarTools.last())
    }

    @Test
    fun `local framing selection persists and remains separate from camera grid state`() {
        OperatorSettings(store).apply {
            ruleOfThirdsEnabled.value = true
            centerCrosshairEnabled.value = true
            levelAssistEnabled.value = true
            framingGuide = LocalFramingGuide.CINEMA_239
            desqueezePresentation = LocalDesqueezePresentation.X165
            levelStyle = LocalLevelStyle.GAUGE
        }

        val restored = OperatorSettings(store)
        assertTrue(restored.ruleOfThirdsEnabled.value)
        assertTrue(restored.centerCrosshairEnabled.value)
        assertTrue(restored.levelAssistEnabled.value)
        assertEquals(LocalFramingGuide.CINEMA_239, restored.framingGuide)
        assertEquals(LocalDesqueezePresentation.X165, restored.desqueezePresentation)
        assertEquals(LocalLevelStyle.GAUGE, restored.levelStyle)
        assertTrue(restored.localFramingAssistConfiguration.accessibilitySummary.contains("unchanged"))
    }

    @Test
    fun `scope compensation defaults to quarter and round trips its Swift raw value`() {
        val settings = OperatorSettings(store)
        assertEquals(ScopeCrushClipCompensation.QUARTER, settings.scopeCrushClipCompensation)
        assertTrue(settings.histogramTrafficLightsEnabled.value)

        ScopeCrushClipCompensation.entries.forEach { compensation ->
            settings.scopeCrushClipCompensation = compensation
            assertEquals(compensation.wireValue, store.getInt("scope-meter-v1", -1))
            assertEquals(compensation, OperatorSettings(store).scopeCrushClipCompensation)
        }
        settings.histogramTrafficLightsEnabled.value = false

        assertFalse(store.getBoolean("assist.scopes.histogramTrafficLights.v1", true))
        assertEquals(
            ScopeCrushClipCompensation.ONE,
            OperatorSettings(store).scopeCrushClipCompensation,
        )
        assertFalse(OperatorSettings(store).histogramTrafficLightsEnabled.value)
    }

    @Test
    fun `advanced exposure assists persist canonical settings and clamp stale scope values`() {
        val settings = OperatorSettings(store)
        settings.feedEffectsConfiguration =
            settings.feedEffectsConfiguration.copy(
                falseColorReferenceEnabled = false,
                peakingSensitivity = FeedPeakingSensitivity.HIGH,
                peakingColor = FeedPeakingColor.BLUE,
                zebraUnit = FeedZebraUnit.NATIVE,
                zebraHighlightEnabled = false,
                zebraHighlightIre = 101f,
                zebraHighlightColor = FeedZebraStripeColor.CYAN,
                zebraMidtoneEnabled = false,
                zebraMidtoneIre = -5f,
                zebraMidtoneColor = FeedZebraStripeColor.GREEN,
            )
        settings.scopeAssistConfiguration =
            settings.scopeAssistConfiguration.copy(
                waveformScale = 2f,
                waveformMode = ScopeWaveformMode.RGB,
                waveformGuides = ScopeGuideLines(clip = false, crush = true, middle = false),
                waveformBrightness = 250,
                paradeScale = 0f,
                paradeMode = ScopeParadeMode.YRGB,
                paradeGuides = ScopeGuideLines(clip = true, crush = false, middle = false),
                paradeBrightness = -1,
                vectorscopeScale = 1.2f,
                vectorscopeZoom = ScopeVectorscopeZoom.X4,
                vectorscopeBrightness = 150,
                histogramScale = 0.8f,
                trafficLightsScale = 1.6f,
            )

        val restored = OperatorSettings(store)
        assertFalse(restored.feedEffectsConfiguration.falseColorReferenceEnabled)
        assertEquals(FeedPeakingSensitivity.HIGH, restored.feedEffectsConfiguration.peakingSensitivity)
        assertEquals(FeedPeakingColor.BLUE, restored.feedEffectsConfiguration.peakingColor)
        assertEquals(FeedZebraUnit.NATIVE, restored.feedEffectsConfiguration.zebraUnit)
        assertFalse(restored.feedEffectsConfiguration.zebraHighlightEnabled)
        assertEquals(100f, restored.feedEffectsConfiguration.zebraHighlightIre)
        assertEquals(FeedZebraStripeColor.CYAN, restored.feedEffectsConfiguration.zebraHighlightColor)
        assertFalse(restored.feedEffectsConfiguration.zebraMidtoneEnabled)
        assertEquals(0f, restored.feedEffectsConfiguration.zebraMidtoneIre)
        assertEquals(FeedZebraStripeColor.GREEN, restored.feedEffectsConfiguration.zebraMidtoneColor)
        assertEquals(ScopeAssistConfiguration.MAX_SCALE, restored.scopeAssistConfiguration.waveformScale)
        assertEquals(ScopeWaveformMode.RGB, restored.scopeAssistConfiguration.waveformMode)
        assertEquals(
            ScopeGuideLines(clip = false, crush = true, middle = false),
            restored.scopeAssistConfiguration.waveformGuides,
        )
        assertEquals(ScopeAssistConfiguration.MAX_BRIGHTNESS, restored.scopeAssistConfiguration.waveformBrightness)
        assertEquals(ScopeAssistConfiguration.MIN_SCALE, restored.scopeAssistConfiguration.paradeScale)
        assertEquals(ScopeParadeMode.YRGB, restored.scopeAssistConfiguration.paradeMode)
        assertEquals(ScopeAssistConfiguration.MIN_BRIGHTNESS, restored.scopeAssistConfiguration.paradeBrightness)
        assertEquals(ScopeVectorscopeZoom.X4, restored.scopeAssistConfiguration.vectorscopeZoom)
        assertEquals(150, restored.scopeAssistConfiguration.vectorscopeBrightness)
        assertEquals(0.8f, restored.scopeAssistConfiguration.histogramScale)
        assertEquals(1.6f, restored.scopeAssistConfiguration.trafficLightsScale)
    }

    @Test
    fun `missing or legacy compensation values migrate with iOS-compatible defaults and clamps`() {
        assertEquals(ScopeCrushClipCompensation.QUARTER, OperatorSettings(store).scopeCrushClipCompensation)

        fun storeLegacy(raw: Int) {
            store.edit()
                .remove("scope-meter-v1")
                .putInt("assist.scopes.crushClipCompensation.v1", raw)
                .apply()
        }

        storeLegacy(5)
        assertEquals(ScopeCrushClipCompensation.HALF, OperatorSettings(store).scopeCrushClipCompensation)
        assertEquals(5, store.getInt("scope-meter-v1", -1))

        storeLegacy(15)
        assertEquals(ScopeCrushClipCompensation.ONE, OperatorSettings(store).scopeCrushClipCompensation)

        storeLegacy(-1)
        assertEquals(ScopeCrushClipCompensation.ZERO, OperatorSettings(store).scopeCrushClipCompensation)
    }

    @Test
    fun `malformed local framing selections safely fall back to off`() {
        store.edit()
            .putString("assist.local.framingGuide.v1", "NOT_A_GUIDE")
            .putString("assist.local.desqueezePresentation.v1", "NOT_A_PRESENTATION")
            .putString("assist.local.levelStyle.v1", "NOT_A_LEVEL_STYLE")
            .apply()

        val restored = OperatorSettings(store)
        assertEquals(LocalFramingGuide.OFF, restored.framingGuide)
        assertEquals(LocalDesqueezePresentation.OFF, restored.desqueezePresentation)
        assertEquals(LocalLevelStyle.HORIZON, restored.levelStyle)
    }

    @Test
    fun `version text matches the iOS format`() {
        assertEquals("0.1.117 (42)", appVersionText("0.1.117", 42))
    }
}
