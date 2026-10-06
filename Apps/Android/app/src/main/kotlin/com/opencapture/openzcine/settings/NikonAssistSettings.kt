package com.opencapture.openzcine.settings

import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.produceState
import androidx.compose.runtime.remember
import androidx.compose.ui.res.stringResource
import com.opencapture.monitorui.MonitorAssistTool
import com.opencapture.monitorui.MonitorFalseColorReferenceMarker
import com.opencapture.monitorui.MonitorFalseColorReferenceSegment
import com.opencapture.monitorui.MonitorFalseColorReferenceValues
import com.opencapture.monitorui.MonitorFalseColorSelection
import com.opencapture.monitorui.MonitorParadeMode
import com.opencapture.monitorui.MonitorWaveformMode
import com.opencapture.monitorui.MonitorZebraNumberEntry
import com.opencapture.monitorui.MonitorZebraNumberZone
import com.opencapture.monitorui.MonitorZebraUnit
import com.opencapture.monitorui.settings.MonitorAssistSettingsSection
import com.opencapture.monitorui.settings.MonitorViewAssistSettings
import android.os.Build
import com.opencapture.opencine.appkit.MonitorAssistState
import com.opencapture.openzcine.R
import com.opencapture.openzcine.bridge.SwiftCore
import com.opencapture.openzcine.ExposureAssistCameraInput
import com.opencapture.openzcine.ExposureCurveOrdinals
import com.opencapture.openzcine.FeedFalseColorScale
import com.opencapture.openzcine.feedScale
import com.opencapture.openzcine.nikonFalseColorScales
import com.opencapture.openzcine.resolveFalseColorReference
import com.opencapture.openzcine.zebraEditorValue
import com.opencapture.openzcine.zebraMonitorPercent
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import kotlin.math.roundToInt

/** Whether this phone can render the image assists (API 33 settings floor and the Swift core). */
internal val nikonImageProcessingAvailable: Boolean
    get() = Build.VERSION.SDK_INT >= 33 && SwiftCore.isAvailable

/** The settings cards: the shared cards over the shared state, with this camera's calibration. */
@Composable
internal fun NikonViewAssistSettings(
    state: MonitorAssistState,
    cameraInput: ExposureAssistCameraInput,
    onInteraction: () -> Unit,
) {
    val unavailable = stringResource(R.string.settings_image_processing_unavailable)
    MonitorViewAssistSettings(
        listOf(MonitorAssistTool.FALSE, MonitorAssistTool.ZEBRA, MonitorAssistTool.WAVE, MonitorAssistTool.PARADE,
            MonitorAssistTool.HISTO, MonitorAssistTool.VECTOR, MonitorAssistTool.PEAK, MonitorAssistTool.LIGHTS)
            .mapNotNull { tool ->
                if (tool == MonitorAssistTool.FALSE && !nikonImageProcessingAvailable) {
                    MonitorAssistSettingsSection.Unavailable(tool, unavailable)
                } else {
                    nikonAssistSection(tool, state, cameraInput, onInteraction)
                }
            },
    )
}

/**
 * One shared settings card for [tool], or null when this phone cannot render it or the shared
 * catalog has no card. The inspector draws the same card's menu, so settings and inspector agree.
 */
@Composable
internal fun nikonAssistSection(
    tool: MonitorAssistTool,
    state: MonitorAssistState,
    cameraInput: ExposureAssistCameraInput,
    onInteraction: () -> Unit,
): MonitorAssistSettingsSection? {
    return when (tool) {
        MonitorAssistTool.FALSE -> if (nikonImageProcessingAvailable) falseColor(state, cameraInput, onInteraction) else null
        MonitorAssistTool.ZEBRA -> if (nikonImageProcessingAvailable) zebra(state, cameraInput, onInteraction) else null
        MonitorAssistTool.PEAK -> if (!nikonImageProcessingAvailable) null else MonitorAssistSettingsSection.Peaking(
            state.peakingSensitivity, state.peakingColor, SettingsPalette.peaking,
            "Higher sensitivity catches finer edges but can get noisy on detailed scenes.",
            "Choose the edge color that stays readable over your typical scene.",
            onSensitivity = { state.setPeaking(sense = it); onInteraction() }, onColor = { state.setPeaking(color = it); onInteraction() },
            reset = { state.resetSettings(tool); onInteraction() })
        MonitorAssistTool.WAVE -> MonitorAssistSettingsSection.Trace.waveform(
            MonitorWaveformMode.entries, state.waveMode, { state.setWaveform(mode = it); onInteraction() }, { it.label },
            state.waveBrightness, { state.setWaveform(brightness = it); onInteraction() }, state.waveGuides,
            { state.setWaveform(guides = it); onInteraction() },
            reset = { state.resetSettings(tool); onInteraction() })
        MonitorAssistTool.PARADE -> MonitorAssistSettingsSection.Trace.parade(
            MonitorParadeMode.entries, state.paradeMode, { state.setParade(mode = it); onInteraction() }, { it.label },
            state.paradeBrightness, { state.setParade(brightness = it); onInteraction() }, state.paradeGuides,
            { state.setParade(guides = it); onInteraction() },
            reset = { state.resetSettings(tool); onInteraction() })
        MonitorAssistTool.HISTO -> MonitorAssistSettingsSection.Histogram(
            state.histoTrafficLights, { state.setHistogram(traffic = !state.histoTrafficLights); onInteraction() },
            state.crushClipCompensation, { state.setHistogram(compensation = it); onInteraction() },
            "Show small RGB edge blocks for crushed and clipped channels.",
            "Stops of crush/clip tolerance before a traffic light glows. Shared with the goal-post meter.",
            reset = { state.resetSettings(tool); onInteraction() })
        MonitorAssistTool.VECTOR -> MonitorAssistSettingsSection.Vectorscope(
            state.vectorZoom, { state.setVectorscope(zoom = it); onInteraction() },
            state.vectorBrightness, { state.setVectorscope(brightness = it); onInteraction() },
            reset = { state.resetSettings(tool); onInteraction() })
        MonitorAssistTool.LIGHTS -> MonitorAssistSettingsSection.TrafficLights(
            state.crushClipCompensation, { state.setCompensation(it); onInteraction() },
            "Stops of crush/clip tolerance before a channel indicator glows. Shared with histogram traffic lights.",
            reset = { state.resetSettings(tool); onInteraction() })
        else -> null
    }
}

/** This camera's scale names: its stops scale is its own scene-referred table. */
private val MonitorFalseColorSelection.nikonLabel: String
    get() = if (this == MonitorFalseColorSelection.IRE || this == MonitorFalseColorSelection.LIMITS) menuLabel else "ZC Stops"

@Composable
private fun falseColor(state: MonitorAssistState, cameraInput: ExposureAssistCameraInput,
    onInteraction: () -> Unit): MonitorAssistSettingsSection {
    val scale = state.falseColorScale.feedScale
    val reference by produceState<MonitorFalseColorReferenceValues?>(null, scale, cameraInput) {
        value = null
        value = withContext(Dispatchers.Default) { nikonFalseColorReference(scale, cameraInput) }
    }
    return MonitorAssistSettingsSection.FalseColor(nikonFalseColorScales, state.falseColorScale,
        { state.setFalseColor(scale = it); onInteraction() }, { it.nikonLabel },
        readChoice = null, reference = reference, referenceEnabled = state.falseColorReference,
        onReferenceEnabled = { state.setFalseColor(reference = it); onInteraction() },
        scaleHelp = "The camera signal supplies the curve and reference calibration.", readHelp = "",
        referenceHelp = "Show a compact color key over live view while False Color is active.",
        reset = { state.resetSettings(MonitorAssistTool.FALSE); onInteraction() })
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
private fun zebra(state: MonitorAssistState, cameraInput: ExposureAssistCameraInput,
    onInteraction: () -> Unit): MonitorAssistSettingsSection =
    MonitorAssistSettingsSection.ZebraNumbers(MonitorZebraUnit.entries, state.zebraUnit, { it.editorLabel },
        onUnit = { state.updateZebraUnit(it); onInteraction() },
        unitsHelp = "Switch between native 0-255 codes and the normalized 0-100 monitoring IRE scale.",
        highlightHelp = "High zebra warns when bright detail approaches clipping after curve compensation.",
        midtoneHelp = "Midtone zebra marks the chosen monitoring level after curve compensation.",
        highlight = zebraZone(state, cameraInput, highlight = true, onInteraction),
        midtone = zebraZone(state, cameraInput, highlight = false, onInteraction),
        reset = { state.resetSettings(MonitorAssistTool.ZEBRA); onInteraction() })

/** Direct entry in this camera's codes: the Swift core converts against its curve and ISO. */
@Composable
private fun zebraZone(state: MonitorAssistState, input: ExposureAssistCameraInput,
    highlight: Boolean, onInteraction: () -> Unit): MonitorZebraNumberZone {
    val unit = state.zebraUnit
    val percent = (if (highlight) state.zebraHighlightIRE else state.zebraMidtoneIRE).toFloat()
    val editorValue = remember(input, unit, percent) { zebraEditorValue(input, unit, percent) }
    val maximum = if (unit == MonitorZebraUnit.NATIVE) 255 else 100
    val entry = editorValue?.let {
        MonitorZebraNumberEntry(it.roundToInt().coerceIn(0, maximum), maximum, onChange = { value ->
            // A retired unit must not reinterpret an entry captured under another calibration.
            if (state.zebraUnit == unit) zebraMonitorPercent(input, unit, value.toFloat())?.let { converted ->
                if (highlight) state.setZebraHighlight(ire = converted.toDouble())
                else state.setZebraMidtone(ire = converted.toDouble())
                onInteraction()
            }
        }, identifier = "settings.zebra.threshold.${if (highlight) "Highlight" else "Midtone"}")
    }
    return MonitorZebraNumberZone(enabled = if (highlight) state.zebraHighlight else state.zebraMidtone,
        entry = entry, paint = if (highlight) state.zebraHighlightColor else state.zebraMidtoneColor,
        colors = if (highlight) SettingsPalette.highlight else SettingsPalette.midtone,
        onEnabled = {
            if (highlight) state.setZebraHighlight(enabled = !state.zebraHighlight)
            else state.setZebraMidtone(enabled = !state.zebraMidtone)
            onInteraction()
        }, onPaint = {
            if (highlight) state.setZebraHighlight(color = it) else state.setZebraMidtone(color = it)
            onInteraction()
        })
}
