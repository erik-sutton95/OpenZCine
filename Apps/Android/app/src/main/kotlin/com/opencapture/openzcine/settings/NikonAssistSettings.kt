package com.opencapture.openzcine.settings

import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.produceState
import androidx.compose.runtime.remember
import com.opencapture.monitorui.MonitorFalseColorReferenceMarker
import com.opencapture.monitorui.MonitorFalseColorReferenceSegment
import com.opencapture.monitorui.MonitorFalseColorReferenceValues
import com.opencapture.monitorui.MonitorScopeGuides
import com.opencapture.monitorui.MonitorVectorscopeZoom
import com.opencapture.monitorui.MonitorZebraNumberEntry
import com.opencapture.monitorui.MonitorZebraNumberZone
import com.opencapture.monitorui.settings.MonitorSettingsColorDot
import com.opencapture.monitorui.settings.MonitorAssistSettingsSection
import com.opencapture.monitorui.settings.MonitorViewAssistSettings
import android.os.Build
import com.opencapture.openzcine.bridge.SwiftCore
import com.opencapture.opencine.media.MonitorCrushClipCompensation
import com.opencapture.opencine.media.MonitorPeakingColor
import com.opencapture.opencine.media.MonitorPeakingSense
import com.opencapture.opencine.media.MonitorZebraPaint
import com.opencapture.openzcine.AssistState
import com.opencapture.openzcine.AssistTool
import com.opencapture.openzcine.ExposureAssistCameraInput
import com.opencapture.openzcine.ExposureCurveOrdinals
import com.opencapture.openzcine.FeedFalseColorScale
import com.opencapture.openzcine.FeedPeakingColor
import com.opencapture.openzcine.FeedPeakingSensitivity
import com.opencapture.openzcine.FeedZebraStripeColor
import com.opencapture.openzcine.FeedZebraUnit
import com.opencapture.openzcine.resolveFalseColorReference
import com.opencapture.openzcine.zebraEditorValue
import com.opencapture.openzcine.zebraMonitorPercent
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import kotlin.math.roundToInt

/** Actual stores/actions supply finite tool inputs; the common owner assembles all cards. */
@Composable
internal fun NikonViewAssistSettings(settings: OperatorSettings, assistState: AssistState,
    cameraInput: ExposureAssistCameraInput, onAssistToggle: (AssistTool) -> Unit, onInteraction: () -> Unit) {
    val processingAvailable = Build.VERSION.SDK_INT >= 33 && SwiftCore.isAvailable
    MonitorViewAssistSettings(listOfNotNull(
        if (processingAvailable) NikonFalseColorSettings(settings, assistState, cameraInput, onAssistToggle, onInteraction)
        else MonitorAssistSettingsSection.Unavailable(com.opencapture.monitorui.MonitorAssistTool.FALSE,
            androidx.compose.ui.res.stringResource(com.opencapture.openzcine.R.string.settings_image_processing_unavailable)),
        if (processingAvailable) NikonZebraSettings(settings, cameraInput, onInteraction) else null,
        NikonScopeTraceSettings(settings, parade = false, onInteraction),
        NikonScopeTraceSettings(settings, parade = true, onInteraction),
        NikonHistogramSettings(settings, onInteraction),
        NikonVectorscopeSettings(settings, onInteraction),
        if (processingAvailable) NikonPeakingSettings(settings, onInteraction) else null,
        NikonCrushClipSettings(settings, onInteraction),
    ))
}

/** Settings keep their existing stores; common menus receive only current values and actions. */
@Composable
internal fun NikonFalseColorSettings(settings: OperatorSettings, assistState: AssistState,
    cameraInput: ExposureAssistCameraInput, onAssistToggle: (AssistTool) -> Unit, onInteraction: () -> Unit): MonitorAssistSettingsSection {
    val scale = assistState.selectedFalseColorScale
    val reference by produceState<MonitorFalseColorReferenceValues?>(null, scale, cameraInput) {
        value = null
        value = withContext(Dispatchers.Default) { nikonFalseColorReference(scale, cameraInput) }
    }
    return MonitorAssistSettingsSection.FalseColor(scales = FeedFalseColorScale.entries, scale = scale,
        onScale = { assistState.selectFalseColorScale(it); onInteraction() }, title = { it.label },
        readChoice = null, reference = reference,
        referenceEnabled = settings.feedEffectsConfiguration.falseColorReferenceEnabled,
        onReferenceEnabled = {
            settings.feedEffectsConfiguration = settings.feedEffectsConfiguration.copy(falseColorReferenceEnabled = it)
            if (it && !assistState.isOn(AssistTool.FALSE)) onAssistToggle(AssistTool.FALSE) else onInteraction()
        }, scaleHelp = "The camera signal supplies the curve and reference calibration.", readHelp = "",
        referenceHelp = "Show a compact color key over live view while False Color is active.",
        reset = { assistState.resetFalseColorSelection(); settings.resetFalseColorConfiguration(); onInteraction() })
}

internal fun nikonFalseColorReference(scale: FeedFalseColorScale,
    input: ExposureAssistCameraInput): MonitorFalseColorReferenceValues? {
    val reference = resolveFalseColorReference(scale, input) ?: return null
    val curve = when (reference.curveOrdinal) {
        ExposureCurveOrdinals.SRGB -> "sRGB"
        ExposureCurveOrdinals.HLG -> "HLG"
        ExposureCurveOrdinals.NIKON_NLOG -> "N-Log"
        ExposureCurveOrdinals.RED_LOG3G10 -> "L3G10"
        else -> return null
    }
    val labels = listOf("Min", "−3", "18%", "Skin", "+2", "Max")
    return MonitorFalseColorReferenceValues(subtitle = "${scale.label} · $curve",
        segments = reference.segments.mapIndexed { index, segment ->
            MonitorFalseColorReferenceSegment(index, segment.lowerFraction.toDouble(), segment.upperFraction.toDouble(),
                segment.color[0].toDouble(), segment.color[1].toDouble(), segment.color[2].toDouble())
        }, markers = if (scale == FeedFalseColorScale.STOPS) {
            reference.stopMarkerFractions.mapIndexed { index, fraction ->
                MonitorFalseColorReferenceMarker(index, labels[index], fraction.toDouble())
            }
        } else emptyList(), axisLabels = when (scale) {
            FeedFalseColorScale.STOPS -> emptyList()
            FeedFalseColorScale.IRE -> listOf("clip / shadows", "18%", "skin hi", "highlights → clip")
            FeedFalseColorScale.LIMITS -> listOf("crushed", "midtones untouched", "clipped")
        })
}

@Composable
internal fun NikonPeakingSettings(settings: OperatorSettings, onInteraction: () -> Unit): MonitorAssistSettingsSection {
    val configuration = settings.feedEffectsConfiguration
    return MonitorAssistSettingsSection.Peaking(sensitivity = when (configuration.peakingSensitivity) {
        FeedPeakingSensitivity.LOW -> MonitorPeakingSense.LOW
        FeedPeakingSensitivity.MEDIUM -> MonitorPeakingSense.MED
        FeedPeakingSensitivity.HIGH -> MonitorPeakingSense.HIGH
    }, color = MonitorPeakingColor.valueOf(configuration.peakingColor.name),
        colors = commonColors(SettingsPalette.peaking),
        sensitivityHelp = "Higher sensitivity catches finer edges but can get noisy on detailed scenes.",
        colorHelp = "Choose the edge color that stays readable over your typical scene.",
        onSensitivity = {
            val sense = when (it) {
                MonitorPeakingSense.LOW -> FeedPeakingSensitivity.LOW
                MonitorPeakingSense.MED -> FeedPeakingSensitivity.MEDIUM
                MonitorPeakingSense.HIGH -> FeedPeakingSensitivity.HIGH
            }
            settings.feedEffectsConfiguration = settings.feedEffectsConfiguration.copy(peakingSensitivity = sense)
            onInteraction()
        }, onColor = {
            settings.feedEffectsConfiguration = settings.feedEffectsConfiguration.copy(peakingColor = FeedPeakingColor.valueOf(it.name))
            onInteraction()
        }, reset = { settings.resetPeakingConfiguration(); onInteraction() })
}

@Composable
internal fun NikonZebraSettings(settings: OperatorSettings, cameraInput: ExposureAssistCameraInput,
    onInteraction: () -> Unit): MonitorAssistSettingsSection {
    val unit = settings.feedEffectsConfiguration.zebraUnit
    return MonitorAssistSettingsSection.ZebraNumbers(units = FeedZebraUnit.entries, unit = unit, title = { it.label },
        onUnit = {
            settings.feedEffectsConfiguration = settings.feedEffectsConfiguration.copy(zebraUnit = it); onInteraction()
        }, unitsHelp = "Switch between native 0-255 codes and the normalized 0-100 monitoring IRE scale.",
        highlightHelp = "High zebra warns when bright detail approaches clipping after curve compensation.",
        midtoneHelp = "Midtone zebra marks the chosen monitoring level after curve compensation.",
        highlight = zebraNumberZone(settings, cameraInput, highlight = true, onInteraction),
        midtone = zebraNumberZone(settings, cameraInput, highlight = false, onInteraction),
        reset = { settings.resetZebraConfiguration(); onInteraction() })
}

@Composable
private fun zebraNumberZone(settings: OperatorSettings, input: ExposureAssistCameraInput,
    highlight: Boolean, onInteraction: () -> Unit): MonitorZebraNumberZone {
    val configuration = settings.feedEffectsConfiguration
    val unit = configuration.zebraUnit
    val percent = if (highlight) configuration.zebraHighlightIre else configuration.zebraMidtoneIre
    val editorValue = remember(input, unit, percent) { zebraEditorValue(input, unit, percent) }
    val maximum = if (unit == FeedZebraUnit.NATIVE) 255 else 100
    val entry = editorValue?.let {
        MonitorZebraNumberEntry(it.roundToInt().coerceIn(0, maximum), maximum, onChange = { value ->
            // A retired unit must not reinterpret an entry captured under another calibration.
            if (settings.feedEffectsConfiguration.zebraUnit == unit) zebraMonitorPercent(input, unit, value.toFloat())?.let { converted ->
                val current = settings.feedEffectsConfiguration
                settings.feedEffectsConfiguration = if (highlight) current.copy(zebraHighlightIre = converted)
                    else current.copy(zebraMidtoneIre = converted)
                onInteraction()
            }
        }, identifier = "settings.zebra.threshold.${if (highlight) "Highlight" else "Midtone"}")
    }
    val color = if (highlight) configuration.zebraHighlightColor else configuration.zebraMidtoneColor
    return MonitorZebraNumberZone(enabled = if (highlight) configuration.zebraHighlightEnabled else configuration.zebraMidtoneEnabled,
        entry = entry, paint = MonitorZebraPaint.valueOf(color.name),
        colors = commonColors(if (highlight) SettingsPalette.highlight else SettingsPalette.midtone),
        onEnabled = {
            val current = settings.feedEffectsConfiguration
            settings.feedEffectsConfiguration = if (highlight) current.copy(zebraHighlightEnabled = !current.zebraHighlightEnabled)
                else current.copy(zebraMidtoneEnabled = !current.zebraMidtoneEnabled)
            onInteraction()
        }, onPaint = {
            val current = settings.feedEffectsConfiguration
            val paint = FeedZebraStripeColor.valueOf(it.name)
            settings.feedEffectsConfiguration = if (highlight) current.copy(zebraHighlightColor = paint)
                else current.copy(zebraMidtoneColor = paint)
            onInteraction()
        })
}

@Composable
internal fun NikonScopeTraceSettings(settings: OperatorSettings, parade: Boolean, onInteraction: () -> Unit): MonitorAssistSettingsSection {
    val configuration = settings.scopeAssistConfiguration
    val guides = if (parade) configuration.paradeGuides else configuration.waveformGuides
    val brightness = if (parade) configuration.paradeBrightness else configuration.waveformBrightness
    val onBrightness: (Int) -> Unit = {
        val current = settings.scopeAssistConfiguration
        settings.scopeAssistConfiguration = if (parade) current.copy(paradeBrightness = it) else current.copy(waveformBrightness = it)
        onInteraction()
    }
    val onGuides: (MonitorScopeGuides) -> Unit = {
        val current = settings.scopeAssistConfiguration
        val updated = ScopeGuideLines(it.clip, it.crush, it.middle)
        settings.scopeAssistConfiguration = if (parade) current.copy(paradeGuides = updated) else current.copy(waveformGuides = updated)
        onInteraction()
    }
    val commonGuides = MonitorScopeGuides(guides.clip, guides.crush, guides.middle)
    return if (parade) {
        MonitorAssistSettingsSection.Trace.parade(ScopeParadeMode.entries, configuration.paradeMode, onMode = {
            settings.scopeAssistConfiguration = settings.scopeAssistConfiguration.copy(paradeMode = it); onInteraction()
        }, title = { it.label }, brightness = brightness, onBrightness = onBrightness, guides = commonGuides, onGuides = onGuides,
            reset = { settings.resetParadeConfiguration(); onInteraction() })
    } else {
        MonitorAssistSettingsSection.Trace.waveform(ScopeWaveformMode.entries, configuration.waveformMode, onMode = {
            settings.scopeAssistConfiguration = settings.scopeAssistConfiguration.copy(waveformMode = it); onInteraction()
        }, title = { it.label }, brightness = brightness, onBrightness = onBrightness, guides = commonGuides, onGuides = onGuides,
            reset = { settings.resetWaveformConfiguration(); onInteraction() })
    }
}

@Composable
internal fun NikonVectorscopeSettings(settings: OperatorSettings, onInteraction: () -> Unit): MonitorAssistSettingsSection {
    val configuration = settings.scopeAssistConfiguration
    return MonitorAssistSettingsSection.Vectorscope(MonitorVectorscopeZoom.valueOf(configuration.vectorscopeZoom.name), onZoom = {
        settings.scopeAssistConfiguration = settings.scopeAssistConfiguration.copy(vectorscopeZoom = ScopeVectorscopeZoom.valueOf(it.name))
        onInteraction()
    }, brightness = configuration.vectorscopeBrightness, onBrightness = {
        settings.scopeAssistConfiguration = settings.scopeAssistConfiguration.copy(vectorscopeBrightness = it); onInteraction()
    }, reset = { settings.resetVectorscopeConfiguration(); onInteraction() })
}

@Composable
internal fun NikonHistogramSettings(settings: OperatorSettings, onInteraction: () -> Unit): MonitorAssistSettingsSection {
    return MonitorAssistSettingsSection.Histogram(trafficLights = settings.histogramTrafficLightsEnabled.value,
        onTrafficLights = { settings.histogramTrafficLightsEnabled.toggle(); onInteraction() },
        compensation = MonitorCrushClipCompensation.valueOf(settings.scopeCrushClipCompensation.name),
        onCompensation = { settings.scopeCrushClipCompensation = ScopeCrushClipCompensation.valueOf(it.name); onInteraction() },
        trafficHelp = "Show small RGB edge blocks for crushed and clipped channels.",
        compensationHelp = "Stops of crush/clip tolerance before a traffic light glows. Shared with the goal-post meter.",
        reset = { settings.resetHistogramConfiguration(); onInteraction() })
}

@Composable
internal fun NikonCrushClipSettings(settings: OperatorSettings, onInteraction: () -> Unit): MonitorAssistSettingsSection {
    return MonitorAssistSettingsSection.TrafficLights(MonitorCrushClipCompensation.valueOf(settings.scopeCrushClipCompensation.name),
        onCompensation = { settings.scopeCrushClipCompensation = ScopeCrushClipCompensation.valueOf(it.name); onInteraction() },
        help = "Stops of crush/clip tolerance before a channel indicator glows. Shared with histogram traffic lights.",
        reset = { settings.resetTrafficLightsConfiguration(); onInteraction() })
}

private fun commonColors(colors: List<SettingsColorDot>): List<MonitorSettingsColorDot> =
    colors.map { MonitorSettingsColorDot(it.name, it.color) }
