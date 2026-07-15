package com.opencapture.openzcine.media

import androidx.compose.animation.core.animateDpAsState
import androidx.compose.animation.core.tween
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.gestures.detectTapGestures
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.offset
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.selection.selectable
import androidx.compose.foundation.selection.selectableGroup
import androidx.compose.foundation.selection.toggleable
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.Slider
import androidx.compose.material3.SliderDefaults
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.geometry.Rect
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.role
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import com.opencapture.openzcine.AssistState
import com.opencapture.openzcine.AssistTool
import com.opencapture.openzcine.ChromeShape
import com.opencapture.openzcine.ExposureAssistCameraInput
import com.opencapture.openzcine.FeedFalseColorScale
import com.opencapture.openzcine.FeedLut
import com.opencapture.openzcine.FeedLutSelection
import com.opencapture.openzcine.FeedPeakingColor
import com.opencapture.openzcine.FeedPeakingSensitivity
import com.opencapture.openzcine.FeedZebraStripeColor
import com.opencapture.openzcine.FeedZebraUnit
import com.opencapture.openzcine.LiveDesign
import com.opencapture.openzcine.chromeClickable
import com.opencapture.openzcine.chromeStyle
import com.opencapture.openzcine.glass
import com.opencapture.openzcine.lut.AndroidLutLibrary
import com.opencapture.openzcine.settings.LocalDesqueezeOrientation
import com.opencapture.openzcine.settings.LocalDesqueezeRatio
import com.opencapture.openzcine.settings.LocalFramingAspectRatio
import com.opencapture.openzcine.settings.LocalFramingGuideFamily
import com.opencapture.openzcine.settings.OperatorSettings
import com.opencapture.openzcine.settings.PanelCloseButton
import com.opencapture.openzcine.settings.ScopeAssistConfiguration
import com.opencapture.openzcine.settings.ScopeCrushClipCompensation
import com.opencapture.openzcine.settings.ScopeGuideLines
import com.opencapture.openzcine.settings.ScopeParadeMode
import com.opencapture.openzcine.settings.ScopeVectorscopeZoom
import com.opencapture.openzcine.settings.ScopeWaveformMode
import com.opencapture.openzcine.settings.SettingsQuietLink
import com.opencapture.openzcine.settings.SettingsSwitchRow
import com.opencapture.openzcine.zebraEditorValue
import com.opencapture.openzcine.zebraMonitorPercent
import kotlin.math.roundToInt
import kotlinx.coroutines.launch

/** Pure parity seam used by playback and JVM tests. Audio remains the only tap-only iOS tool. */
internal fun hasPlaybackAssistOptions(tool: AssistTool): Boolean =
    tool.hasConfiguration

/**
 * Backdrop-dismissible quick settings anchored above the measured playback assist toolbar.
 * Configuration writes through the live/shared models while visibility remains in [playbackState].
 */
@Composable
internal fun PlaybackAssistOptionsOverlay(
    tool: AssistTool,
    toolbarBounds: Rect?,
    playbackState: PlaybackAssistState,
    sharedAssistState: AssistState,
    settings: OperatorSettings,
    cameraInput: ExposureAssistCameraInput,
    lutLibrary: AndroidLutLibrary?,
    onDismiss: () -> Unit,
) {
    BoxWithConstraints(Modifier.fillMaxSize()) {
        val density = LocalDensity.current
        val toolbarTop =
            toolbarBounds?.top?.let { with(density) { it.toDp() } }
                ?: (maxHeight - 90.dp)
        val toolbarRight =
            toolbarBounds?.right?.let { with(density) { it.toDp() } }
                ?: (maxWidth - 82.dp)
        val preferredWidth = if (tool == AssistTool.GUIDES) 472.dp else 400.dp
        val panelWidth = minOf(preferredWidth, (maxWidth - 24.dp).coerceAtLeast(0.dp))
        val maxPanelHeight = (toolbarTop - 16.dp).coerceAtLeast(120.dp)
        val bottomClearance = (maxHeight - toolbarTop + 10.dp).coerceAtLeast(70.dp)
        val maximumLeading = (maxWidth - panelWidth - 12.dp).coerceAtLeast(12.dp)
        val panelLeading = (toolbarRight - panelWidth).coerceIn(12.dp, maximumLeading)
        var revealed by remember(tool) { mutableStateOf(false) }
        val revealOffset by
            animateDpAsState(
                targetValue = if (revealed) 0.dp else 24.dp,
                animationSpec = tween(durationMillis = 180),
                label = "playback assist panel reveal",
            )
        LaunchedEffect(tool) { revealed = true }

        Box(
            Modifier.fillMaxSize()
                .semantics {
                    contentDescription = "Dismiss ${tool.settingsTitle} options"
                    role = Role.Button
                }.chromeClickable(onDismiss),
        )
        Column(
            Modifier.align(Alignment.BottomStart)
                .offset(x = panelLeading, y = -bottomClearance + revealOffset)
                .width(panelWidth)
                .heightIn(max = maxPanelHeight)
                .alpha(if (revealed) 1f else 0f)
                .glass(ChromeShape)
                .border(1.dp, LiveDesign.hairlineStrong, ChromeShape)
                // The panel is a sibling above the backdrop. This no-op detector keeps blank panel
                // chrome from dismissing while child controls retain their own gestures.
                .pointerInput(Unit) { detectTapGestures(onTap = {}) }
                .padding(14.dp),
            verticalArrangement = Arrangement.spacedBy(10.dp),
        ) {
            Row(
                Modifier.fillMaxWidth(),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                Text(
                    tool.settingsTitle.uppercase(),
                    modifier = Modifier.weight(1f),
                    style = chromeStyle(14f, FontWeight.Bold),
                    color = LiveDesign.text,
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis,
                )
                PanelCloseButton(onDismiss)
            }
            Column(
                Modifier.fillMaxWidth()
                    .weight(1f, fill = false)
                    .verticalScroll(rememberScrollState()),
                verticalArrangement = Arrangement.spacedBy(10.dp),
            ) {
                PlaybackAssistOptionsContent(
                    tool = tool,
                    playbackState = playbackState,
                    sharedAssistState = sharedAssistState,
                    settings = settings,
                    cameraInput = cameraInput,
                    lutLibrary = lutLibrary,
                )
            }
        }
    }
}

@Composable
private fun PlaybackAssistOptionsContent(
    tool: AssistTool,
    playbackState: PlaybackAssistState,
    sharedAssistState: AssistState,
    settings: OperatorSettings,
    cameraInput: ExposureAssistCameraInput,
    lutLibrary: AndroidLutLibrary?,
) {
    when (tool) {
        AssistTool.LUT -> LutOptions(playbackState, sharedAssistState, lutLibrary)
        AssistTool.FALSE -> FalseColorOptions(playbackState, sharedAssistState, settings)
        AssistTool.PEAK -> PeakingOptions(settings)
        AssistTool.ZEBRA -> ZebraOptions(settings, cameraInput)
        AssistTool.WAVE -> WaveformOptions(settings)
        AssistTool.PARADE -> ParadeOptions(settings)
        AssistTool.HISTO -> HistogramOptions(settings)
        AssistTool.VECTOR -> VectorscopeOptions(settings)
        AssistTool.LIGHTS -> TrafficLightsOptions(settings)
        AssistTool.GUIDES -> GuideOptions(playbackState, settings)
        AssistTool.GRID -> GridOptions(settings)
        AssistTool.CROSS ->
            OptionCopy("Tap the toolbar button to show or hide the centre crosshair in playback.")
        AssistTool.DESQ -> DesqueezeOptions(playbackState, settings)
        AssistTool.AUDIO ->
            OptionCopy("Meters the playing clip's audio. iOS exposes this as a tap-only tool.")
    }
}

@Composable
private fun LutOptions(
    playbackState: PlaybackAssistState,
    sharedAssistState: AssistState,
    lutLibrary: AndroidLutLibrary?,
) {
    val storedEntries = lutLibrary?.entries?.collectAsState()?.value.orEmpty()
    val scope = rememberCoroutineScope()
    var feedback by remember { mutableStateOf<String?>(null) }
    OptionSection("Built-in look") {
        ChoiceRow(
            options = FeedLut.entries.toList(),
            label = FeedLut::label,
            selected = { sharedAssistState.selectedLut == FeedLutSelection.BuiltIn(it) },
        ) { lut ->
            playbackState.selectSharedLut(sharedAssistState, lut)
            playbackState.setVisible(AssistTool.LUT, true)
            feedback = null
        }
    }
    if (storedEntries.isNotEmpty()) {
        OptionSection("Stored looks") {
            Column(verticalArrangement = Arrangement.spacedBy(6.dp)) {
                storedEntries.forEach { entry ->
                    OptionChoice(
                        label = "${entry.selection.category.label}: ${entry.displayName}",
                        selected = sharedAssistState.selectedLut == FeedLutSelection.Stored(entry.selection),
                        modifier = Modifier.fillMaxWidth(),
                    ) {
                        val library = lutLibrary ?: return@OptionChoice
                        scope.launch {
                            if (library.prepare(entry.selection)) {
                                playbackState.selectSharedStoredLut(sharedAssistState, entry.selection)
                                playbackState.setVisible(AssistTool.LUT, true)
                                feedback = "${entry.displayName} selected."
                            } else {
                                feedback =
                                    library.failures.value[entry.selection]?.operatorMessage
                                        ?: "This LUT could not be prepared."
                            }
                        }
                    }
                }
            }
        }
    } else {
        OptionCopy("Custom and authorized RED looks added in Operator Setup will appear here.")
    }
    feedback?.let { message -> OptionCopy(message) }
}

@Composable
private fun FalseColorOptions(
    playbackState: PlaybackAssistState,
    sharedAssistState: AssistState,
    settings: OperatorSettings,
) {
    val configuration = settings.feedEffectsConfiguration
    ResetRow {
        playbackState.resetSharedFalseColorScale(sharedAssistState)
        settings.resetFalseColorConfiguration()
    }
    OptionSection("Scale") {
        ChoiceRow(
            options = FeedFalseColorScale.entries.toList(),
            label = FeedFalseColorScale::label,
            selected = { sharedAssistState.selectedFalseColorScale == it },
        ) { scale -> playbackState.selectSharedFalseColorScale(sharedAssistState, scale) }
    }
    SettingsSwitchRow(
        title = "Reference Display",
        isOn = configuration.falseColorReferenceEnabled,
        showTopDivider = false,
    ) {
        val enabled = !settings.feedEffectsConfiguration.falseColorReferenceEnabled
        settings.feedEffectsConfiguration =
            settings.feedEffectsConfiguration.copy(falseColorReferenceEnabled = enabled)
        if (enabled) playbackState.setVisible(AssistTool.FALSE, true)
    }
}

@Composable
private fun PeakingOptions(settings: OperatorSettings) {
    val configuration = settings.feedEffectsConfiguration
    ResetRow(settings::resetPeakingConfiguration)
    OptionSection("Sensitivity") {
        ChoiceRow(
            options = FeedPeakingSensitivity.entries.toList(),
            label = FeedPeakingSensitivity::label,
            selected = { configuration.peakingSensitivity == it },
        ) { settings.feedEffectsConfiguration = configuration.copy(peakingSensitivity = it) }
    }
    OptionSection("Color") {
        ChoiceRow(
            options = FeedPeakingColor.entries.toList(),
            label = FeedPeakingColor::label,
            selected = { configuration.peakingColor == it },
        ) { settings.feedEffectsConfiguration = configuration.copy(peakingColor = it) }
    }
}

@Composable
private fun ZebraOptions(settings: OperatorSettings, cameraInput: ExposureAssistCameraInput) {
    val configuration = settings.feedEffectsConfiguration
    ResetRow(settings::resetZebraConfiguration)
    OptionSection("Units") {
        ChoiceRow(
            options = FeedZebraUnit.entries.toList(),
            label = FeedZebraUnit::label,
            selected = { configuration.zebraUnit == it },
        ) { settings.feedEffectsConfiguration = configuration.copy(zebraUnit = it) }
    }
    SettingsSwitchRow("Highlight", configuration.zebraHighlightEnabled, showTopDivider = false) {
        settings.feedEffectsConfiguration =
            configuration.copy(zebraHighlightEnabled = !configuration.zebraHighlightEnabled)
    }
    ZebraThresholdSlider(
        title = "Highlight threshold",
        cameraInput = cameraInput,
        unit = configuration.zebraUnit,
        monitorPercent = configuration.zebraHighlightIre,
    ) { settings.feedEffectsConfiguration = configuration.copy(zebraHighlightIre = it) }
    OptionSection("Highlight color") {
        ChoiceRow(
            options = FeedZebraStripeColor.entries.toList(),
            label = FeedZebraStripeColor::label,
            selected = { configuration.zebraHighlightColor == it },
        ) { settings.feedEffectsConfiguration = configuration.copy(zebraHighlightColor = it) }
    }
    SettingsSwitchRow("Midtone", configuration.zebraMidtoneEnabled, showTopDivider = false) {
        settings.feedEffectsConfiguration =
            configuration.copy(zebraMidtoneEnabled = !configuration.zebraMidtoneEnabled)
    }
    ZebraThresholdSlider(
        title = "Midtone threshold",
        cameraInput = cameraInput,
        unit = configuration.zebraUnit,
        monitorPercent = configuration.zebraMidtoneIre,
    ) { settings.feedEffectsConfiguration = configuration.copy(zebraMidtoneIre = it) }
    OptionSection("Midtone color") {
        ChoiceRow(
            options = FeedZebraStripeColor.entries.toList(),
            label = FeedZebraStripeColor::label,
            selected = { configuration.zebraMidtoneColor == it },
        ) { settings.feedEffectsConfiguration = configuration.copy(zebraMidtoneColor = it) }
    }
}

@Composable
private fun WaveformOptions(settings: OperatorSettings) {
    val configuration = settings.scopeAssistConfiguration
    ResetRow(settings::resetWaveformConfiguration)
    OptionSection("Mode") {
        ChoiceRow(
            ScopeWaveformMode.entries.toList(),
            ScopeWaveformMode::label,
            selected = { configuration.waveformMode == it },
        ) { settings.scopeAssistConfiguration = configuration.copy(waveformMode = it) }
    }
    BrightnessSlider("Brightness", configuration.waveformBrightness) {
        settings.scopeAssistConfiguration = configuration.copy(waveformBrightness = it)
    }
    ScaleSlider("Panel scale", configuration.waveformScale) {
        settings.scopeAssistConfiguration = configuration.copy(waveformScale = it)
    }
    ScopeGuides(configuration.waveformGuides) {
        settings.scopeAssistConfiguration = configuration.copy(waveformGuides = it)
    }
}

@Composable
private fun ParadeOptions(settings: OperatorSettings) {
    val configuration = settings.scopeAssistConfiguration
    ResetRow(settings::resetParadeConfiguration)
    OptionSection("Mode") {
        ChoiceRow(
            ScopeParadeMode.entries.toList(),
            ScopeParadeMode::label,
            selected = { configuration.paradeMode == it },
        ) { settings.scopeAssistConfiguration = configuration.copy(paradeMode = it) }
    }
    BrightnessSlider("Brightness", configuration.paradeBrightness) {
        settings.scopeAssistConfiguration = configuration.copy(paradeBrightness = it)
    }
    ScaleSlider("Panel scale", configuration.paradeScale) {
        settings.scopeAssistConfiguration = configuration.copy(paradeScale = it)
    }
    ScopeGuides(configuration.paradeGuides) {
        settings.scopeAssistConfiguration = configuration.copy(paradeGuides = it)
    }
}

@Composable
private fun VectorscopeOptions(settings: OperatorSettings) {
    val configuration = settings.scopeAssistConfiguration
    ResetRow(settings::resetVectorscopeConfiguration)
    OptionSection("Trace zoom") {
        ChoiceRow(
            ScopeVectorscopeZoom.entries.toList(),
            ScopeVectorscopeZoom::label,
            selected = { configuration.vectorscopeZoom == it },
        ) { settings.scopeAssistConfiguration = configuration.copy(vectorscopeZoom = it) }
    }
    BrightnessSlider("Brightness", configuration.vectorscopeBrightness) {
        settings.scopeAssistConfiguration = configuration.copy(vectorscopeBrightness = it)
    }
    ScaleSlider("Panel scale", configuration.vectorscopeScale) {
        settings.scopeAssistConfiguration = configuration.copy(vectorscopeScale = it)
    }
}

@Composable
private fun HistogramOptions(settings: OperatorSettings) {
    val configuration = settings.scopeAssistConfiguration
    ResetRow(settings::resetHistogramConfiguration)
    ScaleSlider("Panel scale", configuration.histogramScale) {
        settings.scopeAssistConfiguration = configuration.copy(histogramScale = it)
    }
    SettingsSwitchRow(
        "Traffic Lights",
        settings.histogramTrafficLightsEnabled.value,
        showTopDivider = false,
    ) { settings.histogramTrafficLightsEnabled.toggle() }
    CompensationChoices(settings)
}

@Composable
private fun TrafficLightsOptions(settings: OperatorSettings) {
    val configuration = settings.scopeAssistConfiguration
    ResetRow(settings::resetTrafficLightsConfiguration)
    ScaleSlider("Panel scale", configuration.trafficLightsScale) {
        settings.scopeAssistConfiguration = configuration.copy(trafficLightsScale = it)
    }
    CompensationChoices(settings)
}

@Composable
private fun CompensationChoices(settings: OperatorSettings) {
    OptionSection("Crush/clip compensation") {
        ChoiceRow(
            ScopeCrushClipCompensation.entries.toList(),
            ScopeCrushClipCompensation::compactLabel,
            selected = { settings.scopeCrushClipCompensation == it },
        ) { settings.scopeCrushClipCompensation = it }
    }
}

@Composable
private fun GuideOptions(playbackState: PlaybackAssistState, settings: OperatorSettings) {
    OptionSection("Family") {
        ChoiceRow(
            LocalFramingGuideFamily.entries.toList(),
            LocalFramingGuideFamily::label,
            selected = { settings.guideFamily == it },
        ) { settings.guideFamily = it }
    }
    OptionSection("Delivery ratios") {
        val ratios = LocalFramingAspectRatio.forFamily(settings.guideFamily)
        Column(verticalArrangement = Arrangement.spacedBy(6.dp)) {
            ratios.chunked(3).forEach { row ->
                Row(
                    Modifier.fillMaxWidth(),
                    horizontalArrangement = Arrangement.spacedBy(6.dp),
                ) {
                    row.forEach { ratio ->
                        OptionToggleChoice(
                            label = ratio.label,
                            checked = ratio in settings.selectedGuideRatios,
                            modifier = Modifier.weight(1f),
                        ) {
                            val next = settings.toggleGuideRatioConfiguration(ratio)
                            playbackState.setVisible(AssistTool.GUIDES, next.isNotEmpty())
                        }
                    }
                    repeat(3 - row.size) { Spacer(Modifier.weight(1f)) }
                }
            }
        }
    }
    SettingsSwitchRow(
        "Mask outside frame",
        settings.guideMaskEnabled.value,
        showTopDivider = false,
    ) { settings.guideMaskEnabled.toggle() }
}

@Composable
private fun GridOptions(settings: OperatorSettings) {
    OptionSection("Grid patterns") {
        Row(
            Modifier.fillMaxWidth(),
            horizontalArrangement = Arrangement.spacedBy(6.dp),
        ) {
            OptionToggleChoice(
                "Thirds",
                settings.ruleOfThirdsEnabled.value,
                Modifier.weight(1f),
            ) { settings.ruleOfThirdsEnabled.toggle() }
            OptionToggleChoice(
                "Phi Grid",
                settings.phiGridEnabled.value,
                Modifier.weight(1f),
            ) { settings.phiGridEnabled.toggle() }
            OptionToggleChoice(
                "Diagonal",
                settings.diagonalGridEnabled.value,
                Modifier.weight(1f),
            ) { settings.diagonalGridEnabled.toggle() }
        }
    }
}

@Composable
private fun DesqueezeOptions(playbackState: PlaybackAssistState, settings: OperatorSettings) {
    SettingsSwitchRow(
        "Enable",
        playbackState.isOn(AssistTool.DESQ),
        showTopDivider = false,
    ) { playbackState.toggle(AssistTool.DESQ) }
    OptionSection("Ratio") {
        ChoiceRow(
            LocalDesqueezeRatio.entries.toList(),
            LocalDesqueezeRatio::label,
            selected = { settings.desqueezeRatio == it },
        ) { settings.desqueezeRatio = it }
    }
    OptionSection("Compressed axis") {
        ChoiceRow(
            LocalDesqueezeOrientation.entries.toList(),
            LocalDesqueezeOrientation::label,
            selected = { settings.desqueezeOrientation == it },
        ) { settings.desqueezeOrientation = it }
    }
}

@Composable
private fun ScopeGuides(guides: ScopeGuideLines, onChange: (ScopeGuideLines) -> Unit) {
    SettingsSwitchRow("Safe Border Clip", guides.clip, showTopDivider = false) {
        onChange(guides.copy(clip = !guides.clip))
    }
    SettingsSwitchRow("Safe Border Crush", guides.crush, showTopDivider = false) {
        onChange(guides.copy(crush = !guides.crush))
    }
    SettingsSwitchRow("Middle Gray", guides.middle, showTopDivider = false) {
        onChange(guides.copy(middle = !guides.middle))
    }
}

@Composable
private fun ZebraThresholdSlider(
    title: String,
    cameraInput: ExposureAssistCameraInput,
    unit: FeedZebraUnit,
    monitorPercent: Float,
    onChange: (Float) -> Unit,
) {
    val maximum = if (unit == FeedZebraUnit.NATIVE) 255f else 100f
    val editorValue = remember(cameraInput, unit, monitorPercent) {
        zebraEditorValue(cameraInput, unit, monitorPercent)
    }
    if (editorValue == null) {
        OptionCopy("$title is unavailable until the shared exposure mapping is ready.")
        return
    }
    ValueSlider(
        title = title,
        value = editorValue,
        valueRange = 0f..maximum,
        valueLabel = editorValue.roundToInt().toString(),
        steps = maximum.roundToInt() - 1,
    ) { value -> zebraMonitorPercent(cameraInput, unit, value)?.let(onChange) }
}

@Composable
private fun BrightnessSlider(title: String, value: Int, onChange: (Int) -> Unit) {
    ValueSlider(
        title = title,
        value = value.toFloat(),
        valueRange =
            ScopeAssistConfiguration.MIN_BRIGHTNESS.toFloat()..
                ScopeAssistConfiguration.MAX_BRIGHTNESS.toFloat(),
        valueLabel = "$value%",
        steps = ScopeAssistConfiguration.MAX_BRIGHTNESS - ScopeAssistConfiguration.MIN_BRIGHTNESS - 1,
    ) { onChange(it.roundToInt()) }
}

@Composable
private fun ScaleSlider(title: String, value: Float, onChange: (Float) -> Unit) {
    ValueSlider(
        title = title,
        value = value,
        valueRange = ScopeAssistConfiguration.MIN_SCALE..ScopeAssistConfiguration.MAX_SCALE,
        valueLabel = "${(value * 100).roundToInt()}%",
    ) { onChange((it * 100).roundToInt() / 100f) }
}

@Composable
private fun ValueSlider(
    title: String,
    value: Float,
    valueRange: ClosedFloatingPointRange<Float>,
    valueLabel: String,
    steps: Int = 0,
    onChange: (Float) -> Unit,
) {
    Column(verticalArrangement = Arrangement.spacedBy(2.dp)) {
        Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
            OptionLabel(title, Modifier.weight(1f))
            Text(
                valueLabel,
                style = chromeStyle(11f, FontWeight.Medium, mono = true),
                color = LiveDesign.muted,
            )
        }
        Slider(
            value = value.coerceIn(valueRange),
            onValueChange = onChange,
            valueRange = valueRange,
            steps = steps.coerceAtLeast(0),
            colors =
                SliderDefaults.colors(
                    thumbColor = LiveDesign.accent,
                    activeTrackColor = LiveDesign.accent,
                    inactiveTrackColor = LiveDesign.hairlineStrong,
                ),
            modifier = Modifier.fillMaxWidth().height(36.dp),
        )
    }
}

@Composable
private fun ResetRow(onReset: () -> Unit) {
    Row(Modifier.fillMaxWidth()) {
        Spacer(Modifier.weight(1f))
        SettingsQuietLink("Reset", onReset)
    }
}

@Composable
private fun OptionSection(title: String, content: @Composable () -> Unit) {
    Column(verticalArrangement = Arrangement.spacedBy(6.dp)) {
        OptionLabel(title)
        content()
    }
}

@Composable
private fun OptionLabel(title: String, modifier: Modifier = Modifier) {
    Text(
        title,
        modifier = modifier,
        style = chromeStyle(11.5f, FontWeight.SemiBold),
        color = LiveDesign.text,
        maxLines = 1,
    )
}

@Composable
private fun OptionCopy(message: String) {
    Text(
        message,
        style = chromeStyle(11f, FontWeight.Normal),
        color = LiveDesign.muted,
        maxLines = 3,
        overflow = TextOverflow.Ellipsis,
    )
}

@Composable
private fun <T> ChoiceRow(
    options: List<T>,
    label: (T) -> String,
    selected: (T) -> Boolean,
    onSelect: (T) -> Unit,
) {
    Row(
        Modifier.fillMaxWidth().horizontalScroll(rememberScrollState()).selectableGroup(),
        horizontalArrangement = Arrangement.spacedBy(6.dp),
    ) {
        options.forEach { option ->
            OptionChoice(label(option), selected(option)) { onSelect(option) }
        }
    }
}

@Composable
private fun OptionChoice(
    label: String,
    selected: Boolean,
    modifier: Modifier = Modifier,
    onClick: () -> Unit,
) {
    Box(
        modifier
            .height(40.dp)
            .widthIn(min = 62.dp)
            .background(
                if (selected) LiveDesign.accentDim else LiveDesign.background.copy(alpha = 0.38f),
                ChromeShape,
            ).border(1.dp, if (selected) LiveDesign.accentDim else LiveDesign.hairline, ChromeShape)
            .selectable(selected = selected, role = Role.RadioButton, onClick = onClick)
            .padding(horizontal = 9.dp),
        contentAlignment = Alignment.Center,
    ) {
        Text(
            label,
            style = chromeStyle(10f, FontWeight.SemiBold, mono = true),
            color = if (selected) LiveDesign.accent else LiveDesign.muted,
            maxLines = 1,
            overflow = TextOverflow.Ellipsis,
        )
    }
}

@Composable
private fun OptionToggleChoice(
    label: String,
    checked: Boolean,
    modifier: Modifier = Modifier,
    onClick: () -> Unit,
) {
    Box(
        modifier
            .height(40.dp)
            .background(
                if (checked) LiveDesign.accentDim else LiveDesign.background.copy(alpha = 0.38f),
                ChromeShape,
            ).border(1.dp, if (checked) LiveDesign.accentDim else LiveDesign.hairline, ChromeShape)
            .toggleable(value = checked, role = Role.Checkbox, onValueChange = { onClick() })
            .padding(horizontal = 6.dp),
        contentAlignment = Alignment.Center,
    ) {
        Text(
            label,
            style = chromeStyle(9.5f, FontWeight.SemiBold, mono = true),
            color = if (checked) LiveDesign.accent else LiveDesign.muted,
            maxLines = 1,
            overflow = TextOverflow.Ellipsis,
        )
    }
}
