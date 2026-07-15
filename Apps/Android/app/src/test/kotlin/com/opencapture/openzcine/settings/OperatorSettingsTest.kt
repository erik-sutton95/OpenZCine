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
        assertTrue(settings.sideRailsVisible.value)
        assertTrue(settings.assistToolbarVisible.value)
        assertTrue(settings.cameraValuesVisible.value)
        assertTrue(settings.recReadoutVisible.value)
        assertTrue(settings.codecReadoutVisible.value)
        assertTrue(settings.mediaReadoutVisible.value)
        assertTrue(settings.fpsReadoutVisible.value)
        assertTrue(settings.recordConfirmationEnabled.value)
        assertTrue(settings.mediaRemoteShutterEnabled.value)
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
        assertEquals(MonitorDisplayMode.entries.toList(), settings.displayModeOrder)
        assertEquals(MonitorDisplayMode.entries.toSet(), settings.enabledDisplayModes)
    }

    @Test
    fun `toggle writes through and survives a reload`() {
        OperatorSettings(store).apply {
            fpsReadoutVisible.toggle()
            sideRailsVisible.toggle()
        }
        val reloaded = OperatorSettings(store)
        assertEquals(false, reloaded.fpsReadoutVisible.value)
        assertEquals(false, reloaded.sideRailsVisible.value)
    }

    @Test
    fun `DISP order enablement and cycling persist`() {
        val settings = OperatorSettings(store)
        settings.moveDisplayMode(MonitorDisplayMode.COMMAND, targetIndex = 0)
        assertTrue(settings.toggleDisplayMode(MonitorDisplayMode.CLEAN))

        val restored = OperatorSettings(store)
        assertEquals(
            listOf(
                MonitorDisplayMode.COMMAND,
                MonitorDisplayMode.LIVE,
                MonitorDisplayMode.CLEAN,
            ),
            restored.displayModeOrder,
        )
        assertEquals(
            setOf(MonitorDisplayMode.LIVE, MonitorDisplayMode.COMMAND),
            restored.enabledDisplayModes,
        )
        assertEquals(
            MonitorDisplayMode.COMMAND,
            restored.nextDisplayMode(MonitorDisplayMode.LIVE),
        )
        assertEquals(
            MonitorDisplayMode.LIVE,
            restored.nextDisplayMode(MonitorDisplayMode.COMMAND),
        )
        assertEquals(
            MonitorDisplayMode.COMMAND,
            restored.nextDisplayMode(MonitorDisplayMode.CLEAN),
        )
        assertEquals(
            MonitorDisplayMode.LIVE,
            restored.displayModeForExplicitRequest(MonitorDisplayMode.LIVE),
        )
        assertEquals(
            null,
            restored.displayModeForExplicitRequest(MonitorDisplayMode.CLEAN),
        )
    }

    @Test
    fun `DISP persistence reconciles unknown duplicate and missing values deterministically`() {
        store.edit()
            .putString("display.disp.order.v1", "command,UNKNOWN,command,live")
            .putStringSet("display.disp.enabled.v1", linkedSetOf("UNKNOWN", "clean"))
            .apply()

        val settings = OperatorSettings(store)

        assertEquals(
            listOf(
                MonitorDisplayMode.COMMAND,
                MonitorDisplayMode.LIVE,
                MonitorDisplayMode.CLEAN,
            ),
            settings.displayModeOrder,
        )
        assertEquals(setOf(MonitorDisplayMode.CLEAN), settings.enabledDisplayModes)
        assertEquals(
            "COMMAND,LIVE,CLEAN",
            store.getString("display.disp.order.v1", null),
        )
        assertEquals(
            mutableSetOf("CLEAN"),
            store.getStringSet("display.disp.enabled.v1", mutableSetOf()),
        )
        assertEquals(
            MonitorDisplayMode.CLEAN,
            settings.reconciledDisplayMode(MonitorDisplayMode.LIVE),
        )
        assertFalse(settings.toggleDisplayMode(MonitorDisplayMode.CLEAN))
        assertEquals(setOf(MonitorDisplayMode.CLEAN), settings.enabledDisplayModes)
    }

    @Test
    fun `corrupt empty enabled DISP set recovers all safe defaults`() {
        store.edit()
            .putStringSet("display.disp.enabled.v1", linkedSetOf("UNKNOWN"))
            .apply()

        val settings = OperatorSettings(store)

        assertEquals(MonitorDisplayMode.entries.toSet(), settings.enabledDisplayModes)
        assertEquals(
            MonitorDisplayMode.entries.mapTo(linkedSetOf<String>()) { it.name },
            store.getStringSet("display.disp.enabled.v1", mutableSetOf()),
        )
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
            sideRailsVisible.toggle()
            assistToolbarVisible.toggle()
            cameraValuesVisible.toggle()
            recordConfirmationEnabled.toggle()
            mediaRemoteShutterEnabled.toggle()
            keepScreenAwake.toggle()
        }

        val restored = OperatorSettings(store)
        assertFalse(restored.statusBarVisible.value)
        assertFalse(restored.sideRailsVisible.value)
        assertFalse(restored.assistToolbarVisible.value)
        assertFalse(restored.cameraValuesVisible.value)
        assertFalse(restored.recordConfirmationEnabled.value)
        assertFalse(restored.mediaRemoteShutterEnabled.value)
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
        assertTrue(migrated.isAssistToolbarToolVisible(AssistTool.LEVEL))
        assertTrue(migrated.isAssistToolbarToolVisible(AssistTool.DESQ))
        assertTrue(migrated.isAssistToolbarToolVisible(AssistTool.PEAK))
        assertFalse(migrated.isAssistToolbarToolVisible(AssistTool.WAVE))

        migrated.toggleAssistToolbarToolVisibility(AssistTool.LIGHTS)
        migrated.toggleAssistToolbarToolVisibility(AssistTool.AUDIO)
        migrated.toggleAssistToolbarToolVisibility(AssistTool.GUIDES)
        migrated.toggleAssistToolbarToolVisibility(AssistTool.LEVEL)
        assertFalse(OperatorSettings(store).isAssistToolbarToolVisible(AssistTool.LIGHTS))
        assertFalse(OperatorSettings(store).isAssistToolbarToolVisible(AssistTool.AUDIO))
        assertFalse(OperatorSettings(store).isAssistToolbarToolVisible(AssistTool.GUIDES))
        assertFalse(OperatorSettings(store).isAssistToolbarToolVisible(AssistTool.LEVEL))
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
        assertTrue(store.getString("display.assistToolbar.order.v1", null).orEmpty().contains("LEVEL"))

        settings.moveAssistToolbarTool(AssistTool.LUT, targetIndex = 0)
        assertEquals(AssistTool.LUT, OperatorSettings(store).assistToolbarOrder.first())

        settings.moveAssistToolbarTool(AssistTool.VECTOR, targetIndex = AssistTool.entries.lastIndex)
        assertEquals(AssistTool.VECTOR, OperatorSettings(store).assistToolbarOrder.last())
    }

    @Test
    fun `settings reorder geometry accepts only the handle and clamps direct destinations`() {
        assertFalse(settingsReorderGripHit(pointerX = 250f, containerWidth = 320f, gripWidth = 48f))
        assertTrue(settingsReorderGripHit(pointerX = 280f, containerWidth = 320f, gripWidth = 48f))
        val toolCount = AssistTool.entries.size
        assertEquals(0, settingsReorderIndex(pointerY = -40f, rowHeight = 50f, itemCount = toolCount))
        assertEquals(6, settingsReorderIndex(pointerY = 349f, rowHeight = 50f, itemCount = toolCount))
        assertEquals(
            toolCount - 1,
            settingsReorderIndex(pointerY = 900f, rowHeight = 50f, itemCount = toolCount),
        )
    }

    @Test
    fun `display toggle grids wrap in a narrow landscape content pane`() {
        assertEquals(
            2,
            displayToggleGridColumnCount(compact = false, availableWidthDp = 366f),
            "A 600dp shell leaves roughly 366dp after the tab rail and card padding",
        )
        assertEquals(2, displayToggleGridColumnCount(compact = false, availableWidthDp = 479.9f))
        assertEquals(4, displayToggleGridColumnCount(compact = false, availableWidthDp = 480f))
        assertEquals(2, displayToggleGridColumnCount(compact = true, availableWidthDp = 600f))
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
        settings.toggleLocalFramingTool(AssistTool.LEVEL)
        settings.toggleLocalFramingTool(AssistTool.DESQ)
        assertTrue(settings.centerCrosshairEnabled.value)
        assertTrue(settings.levelAssistEnabled.value)
        assertTrue(settings.desqueezeEnabled.value)

        val restored = OperatorSettings(store)
        assertTrue(restored.isLocalFramingToolVisible(AssistTool.LEVEL))
        assertTrue(restored.localFramingAssistConfiguration.levelEnabled)

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
    fun `waveform and parade use calibrated quarter strength while vectorscope stays unchanged`() {
        assertEquals(0f, ScopeAssistConfiguration.waveformParadeBrightnessMultiplier(0))
        assertEquals(0.25f, ScopeAssistConfiguration.waveformParadeBrightnessMultiplier(100))
        assertEquals(0.5f, ScopeAssistConfiguration.waveformParadeBrightnessMultiplier(200))
        assertEquals(0.5f, ScopeAssistConfiguration.waveformParadeBrightnessMultiplier(Int.MAX_VALUE))
        assertEquals(100, ScopeAssistConfiguration().vectorscopeBrightness)
    }

    @Test
    fun `waveform parade brightness decoder covers absent current corrupt legacy and overflow`() {
        val version = ScopeAssistConfiguration.WAVEFORM_PARADE_BRIGHTNESS_CALIBRATION_VERSION
        assertEquals(
            100,
            ScopeAssistConfiguration.decodedWaveformParadeBrightness(null, null),
        )
        assertEquals(
            25,
            ScopeAssistConfiguration.decodedWaveformParadeBrightness(25, version),
        )
        assertEquals(
            200,
            ScopeAssistConfiguration.decodedWaveformParadeBrightness(Int.MAX_VALUE, version),
        )
        assertEquals(
            100,
            ScopeAssistConfiguration.decodedWaveformParadeBrightness(25, null),
        )
        assertEquals(
            200,
            ScopeAssistConfiguration.decodedWaveformParadeBrightness(50, -1),
        )
        assertEquals(
            200,
            ScopeAssistConfiguration.decodedWaveformParadeBrightness(Int.MAX_VALUE, null),
        )
        assertEquals(
            0,
            ScopeAssistConfiguration.decodedWaveformParadeBrightness(Int.MIN_VALUE, null),
        )
    }

    @Test
    fun `waveform parade brightness persistence migrates once and repairs wrong typed values`() {
        val versionKey = "assist.scopes.waveformParade.brightnessCalibrationVersion.v1"
        val waveformKey = "assist.scopes.waveform.brightness.v1"
        val paradeKey = "assist.scopes.parade.brightness.v1"
        val vectorKey = "assist.scopes.vector.brightness.v1"
        val version = ScopeAssistConfiguration.WAVEFORM_PARADE_BRIGHTNESS_CALIBRATION_VERSION

        val absent = TestSharedPreferences()
        val absentSettings = OperatorSettings(absent)
        assertEquals(100, absentSettings.scopeAssistConfiguration.waveformBrightness)
        assertEquals(100, absentSettings.scopeAssistConfiguration.paradeBrightness)
        assertEquals(version, absent.getInt(versionKey, -1))

        val legacy = TestSharedPreferences()
        legacy.edit()
            .putInt(waveformKey, 25)
            .putInt(paradeKey, 50)
            .putInt(vectorKey, 25)
            .apply()
        val migrated = OperatorSettings(legacy).scopeAssistConfiguration
        assertEquals(100, migrated.waveformBrightness)
        assertEquals(200, migrated.paradeBrightness)
        assertEquals(25, migrated.vectorscopeBrightness)
        assertEquals(version, legacy.getInt(versionKey, -1))

        val current = TestSharedPreferences()
        current.edit()
            .putInt(versionKey, version)
            .putInt(waveformKey, 25)
            .putInt(paradeKey, 50)
            .apply()
        val currentSettings = OperatorSettings(current).scopeAssistConfiguration
        assertEquals(25, currentSettings.waveformBrightness)
        assertEquals(50, currentSettings.paradeBrightness)

        val corrupt = TestSharedPreferences()
        corrupt.edit()
            .putString(versionKey, "not-a-version")
            .putString(waveformKey, "not-a-brightness")
            .putInt(paradeKey, Int.MAX_VALUE)
            .apply()
        val repaired = OperatorSettings(corrupt).scopeAssistConfiguration
        assertEquals(100, repaired.waveformBrightness)
        assertEquals(200, repaired.paradeBrightness)
        assertEquals(version, corrupt.getInt(versionKey, -1))
        assertEquals(100, corrupt.getInt(waveformKey, -1))

        val overflow = TestSharedPreferences()
        overflow.edit()
            .putInt(waveformKey, Int.MAX_VALUE)
            .putInt(paradeKey, Int.MIN_VALUE)
            .apply()
        val overflowSettings = OperatorSettings(overflow).scopeAssistConfiguration
        assertEquals(200, overflowSettings.waveformBrightness)
        assertEquals(0, overflowSettings.paradeBrightness)
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
