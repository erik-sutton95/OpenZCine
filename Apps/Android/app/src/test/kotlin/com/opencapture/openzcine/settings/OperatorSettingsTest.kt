package com.opencapture.openzcine.settings

import com.opencapture.openzcine.AssistTool
import com.opencapture.openzcine.FeedPeakingColor
import com.opencapture.openzcine.FeedPeakingSensitivity
import com.opencapture.openzcine.FeedEffectsConfiguration
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
        assertFalse(settings.guidesVisible.value)
        assertFalse(settings.localGridVisible.value)
        assertFalse(settings.ruleOfThirdsEnabled.value)
        assertFalse(settings.phiGridEnabled.value)
        assertFalse(settings.diagonalGridEnabled.value)
        assertFalse(settings.centerCrosshairEnabled.value)
        assertFalse(settings.levelAssistEnabled.value)
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
        assertTrue(settings.selectedGuideRatios.isEmpty())
        assertFalse(settings.desqueezeEnabled.value)
        assertEquals(LocalDesqueezeRatio.X100, settings.desqueezeRatio)
        assertEquals(LocalDesqueezeOrientation.HORIZONTAL, settings.desqueezeOrientation)
        assertEquals(LiveViewStreamPreset.FAST, settings.streamPreset)
        assertEquals(LiveViewQualityBias.LATENCY, settings.qualityBias)
        assertEquals(PortraitFeedAspect.FIT_16_9, settings.portraitFeedAspect)
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
    fun `link preview choices persist separately from camera settings`() {
        OperatorSettings(store).apply {
            streamPreset = LiveViewStreamPreset.QUALITY
            qualityBias = LiveViewQualityBias.DETAIL
        }

        val restored = OperatorSettings(store)
        assertEquals(LiveViewStreamPreset.QUALITY, restored.streamPreset)
        assertEquals(LiveViewQualityBias.DETAIL, restored.qualityBias)
        assertEquals("QUALITY", store.getString("link.streamPreset.v1", null))
        assertEquals("DETAIL", store.getString("link.qualityBias.v1", null))
    }

    @Test
    fun `portrait feed aspect defaults to fit and persists fill`() {
        val settings = OperatorSettings(store)
        assertEquals(PortraitFeedAspect.FIT_16_9, settings.portraitFeedAspect)

        settings.portraitFeedAspect = PortraitFeedAspect.FILL

        assertEquals(PortraitFeedAspect.FILL, OperatorSettings(store).portraitFeedAspect)
        assertEquals("FILL", store.getString("display.portraitFeedAspect.v1", null))
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
        assertTrue(migrated.isAssistToolbarToolVisible(AssistTool.GUIDES))
        assertTrue(migrated.isAssistToolbarToolVisible(AssistTool.GRID))
        assertTrue(migrated.isAssistToolbarToolVisible(AssistTool.CROSS))
        assertTrue(migrated.isAssistToolbarToolVisible(AssistTool.DESQ))
        assertTrue(migrated.isAssistToolbarToolVisible(AssistTool.PEAK))
        assertFalse(migrated.isAssistToolbarToolVisible(AssistTool.WAVE))

        migrated.toggleAssistToolbarToolVisibility(AssistTool.LIGHTS)
        migrated.toggleAssistToolbarToolVisibility(AssistTool.AUDIO)
        migrated.toggleAssistToolbarToolVisibility(AssistTool.GUIDES)
        assertFalse(OperatorSettings(store).isAssistToolbarToolVisible(AssistTool.LIGHTS))
        assertFalse(OperatorSettings(store).isAssistToolbarToolVisible(AssistTool.AUDIO))
        assertFalse(OperatorSettings(store).isAssistToolbarToolVisible(AssistTool.GUIDES))
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

        settings.moveAssistToolbarTool(AssistTool.LUT, targetIndex = 0)
        assertEquals(AssistTool.LUT, OperatorSettings(store).assistToolbarOrder.first())

        settings.moveAssistToolbarTool(AssistTool.VECTOR, targetIndex = AssistTool.entries.lastIndex)
        assertEquals(AssistTool.VECTOR, OperatorSettings(store).assistToolbarOrder.last())
    }

    @Test
    fun `settings reorder geometry accepts only the handle and clamps direct destinations`() {
        assertFalse(settingsReorderGripHit(pointerX = 250f, containerWidth = 320f, gripWidth = 48f))
        assertTrue(settingsReorderGripHit(pointerX = 280f, containerWidth = 320f, gripWidth = 48f))
        assertEquals(0, settingsReorderIndex(pointerY = -40f, rowHeight = 50f, itemCount = 14))
        assertEquals(6, settingsReorderIndex(pointerY = 349f, rowHeight = 50f, itemCount = 14))
        assertEquals(13, settingsReorderIndex(pointerY = 900f, rowHeight = 50f, itemCount = 14))
    }

    @Test
    fun `settings reorder auto scroll follows viewport edges and stops in the middle`() {
        assertEquals(
            -12f,
            settingsReorderAutoScrollDelta(
                pointerRootY = 90f,
                viewportTop = 100f,
                viewportBottom = 500f,
                edgeThreshold = 40f,
                maximumStep = 12f,
            ),
        )
        assertEquals(
            6f,
            settingsReorderAutoScrollDelta(
                pointerRootY = 480f,
                viewportTop = 100f,
                viewportBottom = 500f,
                edgeThreshold = 40f,
                maximumStep = 12f,
            ),
        )
        assertEquals(
            0f,
            settingsReorderAutoScrollDelta(
                pointerRootY = 300f,
                viewportTop = 100f,
                viewportBottom = 500f,
                edgeThreshold = 40f,
                maximumStep = 12f,
            ),
        )
    }

    @Test
    fun `toolbar reset restores every currently supported tool`() {
        val settings = OperatorSettings(store)
        settings.toggleAssistToolbarToolVisibility(AssistTool.WAVE)
        settings.moveAssistToolbarTool(AssistTool.VECTOR, targetIndex = 0)
        settings.resetAssistToolbarPreferences()

        assertEquals(AssistTool.entries.toList(), settings.assistToolbarOrder)
        assertEquals(AssistTool.entries.toList(), settings.visibleAssistToolbarTools)
    }

    @Test
    fun `audio remains in the trailing toolbar section when its stored order moves`() {
        val settings = OperatorSettings(store)
        settings.moveAssistToolbarTool(AssistTool.AUDIO, targetIndex = 0)

        assertEquals(AssistTool.AUDIO, settings.assistToolbarOrder.first())
        assertEquals(AssistTool.AUDIO, settings.visibleAssistToolbarTools.last())
    }

    @Test
    fun `local framing selections persist and remain separate from camera grid state`() {
        OperatorSettings(store).apply {
            guideFamily = LocalFramingGuideFamily.SOCIAL
            toggleGuideRatio(LocalFramingAspectRatio.RATIO_9_16)
            toggleGuideRatio(LocalFramingAspectRatio.RATIO_1_1)
            guideMaskEnabled.value = true
            localGridVisible.value = true
            ruleOfThirdsEnabled.value = true
            phiGridEnabled.value = true
            diagonalGridEnabled.value = true
            centerCrosshairEnabled.value = true
            levelAssistEnabled.value = true
            levelStyle = LocalLevelStyle.GAUGE
            desqueezeEnabled.value = true
            desqueezeRatio = LocalDesqueezeRatio.X165
            desqueezeOrientation = LocalDesqueezeOrientation.VERTICAL
        }

        val restored = OperatorSettings(store)
        assertEquals(LocalFramingGuideFamily.SOCIAL, restored.guideFamily)
        assertEquals(
            setOf(LocalFramingAspectRatio.RATIO_9_16, LocalFramingAspectRatio.RATIO_1_1),
            restored.selectedGuideRatios,
        )
        assertTrue(restored.guidesVisible.value)
        assertTrue(restored.guideMaskEnabled.value)
        assertTrue(restored.localGridVisible.value)
        assertTrue(restored.ruleOfThirdsEnabled.value)
        assertTrue(restored.phiGridEnabled.value)
        assertTrue(restored.diagonalGridEnabled.value)
        assertTrue(restored.centerCrosshairEnabled.value)
        assertTrue(restored.levelAssistEnabled.value)
        assertEquals(LocalLevelStyle.GAUGE, restored.levelStyle)
        assertTrue(restored.desqueezeEnabled.value)
        assertEquals(LocalDesqueezeRatio.X165, restored.desqueezeRatio)
        assertEquals(LocalDesqueezeOrientation.VERTICAL, restored.desqueezeOrientation)
        assertTrue(restored.localFramingAssistConfiguration.accessibilitySummary.contains("unchanged"))
    }

    @Test
    fun `framing toolbar actions seed and toggle only local presentation controls`() {
        val settings = OperatorSettings(store)

        settings.toggleLocalFramingTool(AssistTool.GUIDES)
        assertTrue(settings.localFramingAssistConfiguration.drawsGuides)
        assertEquals(setOf(LocalFramingAspectRatio.RATIO_239), settings.selectedGuideRatios)

        settings.toggleLocalFramingTool(AssistTool.GRID)
        assertTrue(settings.localFramingAssistConfiguration.drawsGrid)
        assertTrue(settings.ruleOfThirdsEnabled.value)

        settings.toggleLocalFramingTool(AssistTool.CROSS)
        settings.toggleLocalFramingTool(AssistTool.DESQ)
        assertTrue(settings.centerCrosshairEnabled.value)
        assertTrue(settings.desqueezeEnabled.value)

        settings.toggleLocalFramingTool(AssistTool.GUIDES)
        assertFalse(settings.localFramingAssistConfiguration.drawsGuides)
        assertEquals(setOf(LocalFramingAspectRatio.RATIO_239), settings.selectedGuideRatios)
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
    fun `nonfinite exposure and scope preferences recover to operator defaults`() {
        val settings = OperatorSettings(store)
        settings.feedEffectsConfiguration =
            settings.feedEffectsConfiguration.copy(
                zebraHighlightIre = Float.NaN,
                zebraMidtoneIre = Float.POSITIVE_INFINITY,
            )
        settings.scopeAssistConfiguration =
            settings.scopeAssistConfiguration.copy(
                waveformScale = Float.NaN,
                vectorscopeScale = Float.NEGATIVE_INFINITY,
            )

        val restored = OperatorSettings(store)
        assertEquals(100f, restored.feedEffectsConfiguration.zebraHighlightIre)
        assertEquals(55f, restored.feedEffectsConfiguration.zebraMidtoneIre)
        assertEquals(ScopeAssistConfiguration.DEFAULT_SCALE, restored.scopeAssistConfiguration.waveformScale)
        assertEquals(ScopeAssistConfiguration.DEFAULT_SCALE, restored.scopeAssistConfiguration.vectorscopeScale)
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
    fun `legacy single framing selections migrate without changing camera grid state`() {
        store.edit()
            .putBoolean("assist.local.ruleOfThirds", true)
            .putString("assist.local.framingGuide.v1", "CINEMA_239")
            .putString("assist.local.desqueezePresentation.v1", "X165")
            .apply()

        val restored = OperatorSettings(store)
        assertTrue(restored.localGridVisible.value)
        assertTrue(restored.guidesVisible.value)
        assertEquals(setOf(LocalFramingAspectRatio.RATIO_239), restored.selectedGuideRatios)
        assertTrue(restored.desqueezeEnabled.value)
        assertEquals(LocalDesqueezeRatio.X165, restored.desqueezeRatio)
        assertEquals(LocalDesqueezeOrientation.HORIZONTAL, restored.desqueezeOrientation)

        val widescreenStore = TestSharedPreferences()
        widescreenStore.edit()
            .putString("assist.local.framingGuide.v1", "WIDESCREEN_16_9")
            .apply()
        assertEquals(
            setOf(LocalFramingAspectRatio.RATIO_16_9),
            OperatorSettings(widescreenStore).selectedGuideRatios,
        )
    }

    @Test
    fun `playback guide configuration does not change live visibility`() {
        val settings = OperatorSettings(store)

        val selected =
            settings.toggleGuideRatioConfiguration(LocalFramingAspectRatio.RATIO_239)

        assertEquals(setOf(LocalFramingAspectRatio.RATIO_239), selected)
        assertFalse(settings.guidesVisible.value)
        assertEquals(selected, OperatorSettings(store).selectedGuideRatios)
    }

    @Test
    fun `malformed local framing selections safely fall back to inactive defaults`() {
        store.edit()
            .putStringSet("assist.local.guides.ratios.v2", linkedSetOf("NOT_A_GUIDE"))
            .putString("assist.local.desqueeze.ratio.v2", "NOT_A_PRESENTATION")
            .putString("assist.local.desqueeze.orientation.v2", "NOT_AN_AXIS")
            .putString("assist.local.levelStyle.v1", "NOT_A_LEVEL_STYLE")
            .apply()

        val restored = OperatorSettings(store)
        assertTrue(restored.selectedGuideRatios.isEmpty())
        assertEquals(LocalDesqueezeRatio.X100, restored.desqueezeRatio)
        assertEquals(LocalDesqueezeOrientation.HORIZONTAL, restored.desqueezeOrientation)
        assertEquals(LocalLevelStyle.HORIZON, restored.levelStyle)
    }

    @Test
    fun `per tool exposure resets persist iOS defaults without moving unrelated scope panels`() {
        val settings = OperatorSettings(store)
        settings.feedEffectsConfiguration =
            FeedEffectsConfiguration(
                falseColorReferenceEnabled = false,
                peakingSensitivity = FeedPeakingSensitivity.HIGH,
                peakingColor = FeedPeakingColor.BLUE,
                zebraUnit = FeedZebraUnit.NATIVE,
                zebraHighlightEnabled = false,
                zebraHighlightIre = 42f,
                zebraHighlightColor = FeedZebraStripeColor.CYAN,
                zebraMidtoneEnabled = false,
                zebraMidtoneIre = 12f,
                zebraMidtoneColor = FeedZebraStripeColor.GREEN,
            )
        settings.scopeAssistConfiguration =
            ScopeAssistConfiguration(
                waveformScale = 1.4f,
                waveformMode = ScopeWaveformMode.RGB,
                waveformGuides = ScopeGuideLines(false, false, false),
                waveformBrightness = 180,
                paradeScale = 1.3f,
                paradeMode = ScopeParadeMode.YRGB,
                paradeGuides = ScopeGuideLines(false, false, false),
                paradeBrightness = 170,
                vectorscopeScale = 1.2f,
                vectorscopeZoom = ScopeVectorscopeZoom.X4,
                vectorscopeBrightness = 160,
                histogramScale = 0.8f,
                trafficLightsScale = 1.6f,
            )
        settings.histogramTrafficLightsEnabled.value = false
        settings.scopeCrushClipCompensation = ScopeCrushClipCompensation.ONE

        settings.resetFalseColorConfiguration()
        settings.resetPeakingConfiguration()
        settings.resetZebraConfiguration()
        settings.resetWaveformConfiguration()
        settings.resetParadeConfiguration()
        settings.resetHistogramConfiguration()
        settings.resetVectorscopeConfiguration()
        settings.resetTrafficLightsConfiguration()
        val restored = OperatorSettings(store)

        assertEquals(FeedEffectsConfiguration(), restored.feedEffectsConfiguration)
        assertEquals(1.4f, restored.scopeAssistConfiguration.waveformScale)
        assertEquals(ScopeWaveformMode.LUMA, restored.scopeAssistConfiguration.waveformMode)
        assertEquals(ScopeGuideLines(), restored.scopeAssistConfiguration.waveformGuides)
        assertEquals(100, restored.scopeAssistConfiguration.waveformBrightness)
        assertEquals(1.3f, restored.scopeAssistConfiguration.paradeScale)
        assertEquals(ScopeParadeMode.RGB, restored.scopeAssistConfiguration.paradeMode)
        assertEquals(1.2f, restored.scopeAssistConfiguration.vectorscopeScale)
        assertEquals(ScopeVectorscopeZoom.X1, restored.scopeAssistConfiguration.vectorscopeZoom)
        assertEquals(0.8f, restored.scopeAssistConfiguration.histogramScale)
        assertEquals(1f, restored.scopeAssistConfiguration.trafficLightsScale)
        assertTrue(restored.histogramTrafficLightsEnabled.value)
        assertEquals(ScopeCrushClipCompensation.QUARTER, restored.scopeCrushClipCompensation)
    }

    @Test
    fun `version text matches the iOS format`() {
        assertEquals("0.1.117 (42)", appVersionText("0.1.117", 42))
    }
}
