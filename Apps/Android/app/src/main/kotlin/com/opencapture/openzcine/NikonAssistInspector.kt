package com.opencapture.openzcine

import android.content.Context
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.gestures.detectTapGestures
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.offset
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.key
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import com.opencapture.monitorui.LocalMonitorInspectorHelp
import com.opencapture.monitorui.MonitorAssistHelp
import com.opencapture.monitorui.MonitorAssistPalette
import com.opencapture.monitorui.MonitorAssistTool
import com.opencapture.monitorui.MonitorAssistToolGlyph
import com.opencapture.monitorui.MonitorDesqueezeMenu
import com.opencapture.monitorui.MonitorGridMenu
import com.opencapture.monitorui.MonitorGuidesMenu
import com.opencapture.monitorui.MonitorIcon
import com.opencapture.monitorui.MonitorInspector
import com.opencapture.monitorui.MonitorOptionGroup
import com.opencapture.monitorui.MonitorTab
import com.opencapture.monitorui.monitorScrollFade
import com.opencapture.monitorui.monitorTabStrip
import com.opencapture.monitorui.settings.MonitorSettingsChoices
import com.opencapture.monitorui.settings.MonitorSettingsInlineRow
import com.opencapture.monitorui.settings.MonitorSettingsSwitchInlineRow
import com.opencapture.opencine.appkit.MonitorToolUsagePreferences
import com.opencapture.openzcine.lut.AndroidLutLibrary
import com.opencapture.openzcine.lut.StoredLutCategory
import com.opencapture.openzcine.settings.LocalLevelStyle
import com.opencapture.openzcine.settings.OperatorSettings
import com.opencapture.openzcine.settings.nikonAssistSection
import kotlinx.coroutines.launch

/** A palette chip: a shared assist, or PLAY (photography's instant review, this camera's own). */
internal sealed interface NikonAssistChip {
    val id: String

    data class Tool(val tool: MonitorAssistTool) : NikonAssistChip {
        override val id: String get() = tool.name
    }

    data object InstantReview : NikonAssistChip {
        override val id: String get() = "PLAY"
    }
}

/** The live palette for this camera's capabilities: the cinema set, or PLAY plus the photo toolset. */
internal fun nikonLiveAssistChips(photography: Boolean, imageEffects: Boolean): List<NikonAssistChip> {
    val tools =
        MonitorAssistTool.settingsCases.filter {
            it != MonitorAssistTool.ND && (imageEffects || !it.isImageEffect) &&
                if (photography) it.appliesToPhotography else !it.isPhotographyOnly
        }.map(NikonAssistChip::Tool)
    return if (photography) listOf(NikonAssistChip.InstantReview) + tools else tools
}

/** The shared playback set (no camera level or EV needle); this camera has no ND source. */
internal fun nikonPlaybackAssistTools(imageEffects: Boolean): List<MonitorAssistTool> =
    MonitorAssistTool.playbackToolbarCases.filter {
        it != MonitorAssistTool.ND && (imageEffects || !it.isImageEffect)
    }

/** Whether an open live inspector still belongs to the visible, unlocked, resumed live monitor. */
internal fun retainLiveAssistOptions(
    tool: MonitorAssistTool?,
    tools: List<MonitorAssistTool>,
    liveMode: Boolean,
    locked: Boolean,
    resumed: Boolean,
): Boolean = tool != null && tool.nikonHasOptions && tool in tools && liveMode && !locked && resumed

/** The camera level has a style; the camera meters and the one-axis mirror have nothing to tune. */
internal val MonitorAssistTool.nikonHasOptions: Boolean
    get() = this !in setOf(MonitorAssistTool.EV, MonitorAssistTool.AUDIO, MonitorAssistTool.MIRROR, MonitorAssistTool.ND)

/** The approved palette defaults, with the between-shots PLAY and EV leading the photo toolset. */
internal val nikonUsageSeed =
    mapOf(
        "PLAY" to 8, "EV" to 7, "PEAK" to 6, "FALSE" to 5, "ZEBRA" to 4, "LUT" to 4, "WAVE" to 3,
        "GUIDES" to 2, "GRID" to 2, "HISTO" to 2, "VECTOR" to 1, "PARADE" to 1, "LIGHTS" to 1,
        "CROSS" to 1, "MIRROR" to 1, "AUDIO" to 1,
    )

/** The shared assist palette over the shared state; long press opens the shared inspector. */
@Composable
internal fun NikonAssistPalette(
    chips: List<NikonAssistChip>,
    assists: NikonAssists,
    playback: Boolean,
    portrait: Boolean,
    locked: Boolean,
    modifier: Modifier = Modifier,
    requestExpand: Boolean = false,
    onExpansionHandled: () -> Unit = {},
) {
    val context = LocalContext.current
    val haptics = LocalOperatorHaptics.current
    val usageStore =
        remember(context) {
            MonitorToolUsagePreferences(
                context.getSharedPreferences("assist", Context.MODE_PRIVATE), "assistToolUsage.v1",
            )
        }
    var usage by remember(usageStore) { mutableStateOf(usageStore.value) }
    val shared = assists.shared
    MonitorAssistPalette(
        tools = chips, portrait = portrait, locked = locked,
        isOn = { chip ->
            when (chip) {
                is NikonAssistChip.Tool ->
                    if (playback) shared.isPlaybackVisible(chip.tool) else shared.isOn(chip.tool)
                NikonAssistChip.InstantReview -> assists.instantReview
            }
        },
        title = { chip -> (chip as? NikonAssistChip.Tool)?.tool?.title ?: "Instant Playback" },
        label = { chip -> (chip as? NikonAssistChip.Tool)?.tool?.chipLabel ?: "PLAY" },
        hasOptions = { chip -> chip is NikonAssistChip.Tool && chip.tool.nikonHasOptions },
        onToggle = { chip ->
            haptics.selection()
            when (chip) {
                is NikonAssistChip.Tool ->
                    if (playback) shared.togglePlayback(chip.tool) else shared.toggle(chip.tool)
                NikonAssistChip.InstantReview -> assists.instantReview = !assists.instantReview
            }
        },
        onOptions = { chip ->
            if (chip is NikonAssistChip.Tool) {
                haptics.longPress()
                shared.configureTool = chip.tool
            }
        },
        glyph = { chip, tint, glyphModifier ->
            when (chip) {
                is NikonAssistChip.Tool -> MonitorAssistToolGlyph(chip.tool, tint, glyphModifier, evFontSize = 17f)
                NikonAssistChip.InstantReview -> MonitorIcon(MonitorIcon.IMAGE, null, glyphModifier, tint)
            }
        },
        chevron = { expanded, vertical ->
            val icon =
                if (vertical) {
                    if (expanded) MonitorIcon.CHEVRON_DOWN else MonitorIcon.CHEVRON_UP
                } else {
                    if (expanded) MonitorIcon.CHEVRON_LEFT else MonitorIcon.CHEVRON_RIGHT
                }
            MonitorIcon(icon, null, Modifier.size(14.dp), LiveDesign.muted)
        },
        modifier = modifier, requestExpand = requestExpand, onExpansionHandled = onExpansionHandled,
        usageSeed = nikonUsageSeed, idOf = { it.id }, usage = usage,
        onUsageChange = { next -> usage = next; usageStore.value = next },
    )
}

/**
 * The shared assist inspector: its frame and tab strip, the shared settings card for each tool,
 * and this camera's typed extensions (its LUT catalog and the camera level style).
 */
@Composable
internal fun NikonAssistInspector(
    tool: MonitorAssistTool,
    tools: List<MonitorAssistTool>,
    assists: NikonAssists,
    settings: OperatorSettings,
    cameraInput: ExposureAssistCameraInput,
    lutLibrary: AndroidLutLibrary?,
    viewportWidth: Float,
    viewportHeight: Float,
    safeLeading: Float = 0f,
    safeTop: Float = 0f,
    safeBottom: Float = 0f,
    safeTrailing: Float = 0f,
    onOpenRedDownload: () -> Unit = {},
    onRequestLutImport: (() -> Unit)? = null,
    onDismiss: () -> Unit,
) {
    var helpVisible by remember { mutableStateOf(false) }
    MonitorInspector(
        title = tool.title, helpVisible = helpVisible, onToggleHelp = { helpVisible = !helpVisible },
        viewportWidth = viewportWidth, viewportHeight = viewportHeight, onDismiss = onDismiss,
        safeLeading = safeLeading, safeTrailing = safeTrailing, safeTop = safeTop, safeBottom = safeBottom,
        navigation = { portrait ->
            val scroll = rememberScrollState()
            if (portrait) {
                Row(Modifier.fillMaxWidth().monitorScrollFade(scroll, vertical = false).horizontalScroll(scroll)
                    .monitorTabStrip()) {
                    tools.forEach { InspectorTab(it, tool, assists, portrait = true) }
                }
            } else {
                Column(Modifier.fillMaxHeight().monitorScrollFade(scroll).verticalScroll(scroll).monitorTabStrip()) {
                    tools.forEach { InspectorTab(it, tool, assists, portrait = false) }
                }
            }
        },
    ) {
        key(tool) {
            CompositionLocalProvider(LocalMonitorInspectorHelp provides helpVisible) {
                val scroll = rememberScrollState()
                Column(
                    Modifier.fillMaxWidth().then(
                        if (tool == MonitorAssistTool.LUT) Modifier
                        else Modifier.monitorScrollFade(scroll).verticalScroll(scroll),
                    ),
                    verticalArrangement = Arrangement.spacedBy(10.dp),
                ) {
                    AssistOptions(tool, assists, settings, cameraInput, lutLibrary, onOpenRedDownload, onRequestLutImport)
                }
            }
        }
    }
}

@Composable
private fun InspectorTab(tool: MonitorAssistTool, selected: MonitorAssistTool, assists: NikonAssists, portrait: Boolean) {
    val haptics = LocalOperatorHaptics.current
    val active = tool == selected
    val tint = if (active) LiveDesign.accent else LiveDesign.muted
    MonitorTab(active, { haptics.selection(); assists.shared.configureTool = tool },
        Modifier.then(if (portrait) Modifier.width(94.dp) else Modifier.fillMaxWidth()).height(44.dp),
        vertical = !portrait, separator = true, accessibilityLabel = tool.title) {
        Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(6.dp)) {
            MonitorAssistToolGlyph(tool, tint, Modifier.size(15.dp))
            Text(tool.chipLabel, color = tint, style = chromeStyle(9f, FontWeight.SemiBold), maxLines = 1)
        }
    }
}

/** One tool's options: the shared card, or this camera's own LUT catalog and level style. */
@Composable
private fun AssistOptions(
    tool: MonitorAssistTool,
    assists: NikonAssists,
    settings: OperatorSettings,
    cameraInput: ExposureAssistCameraInput,
    lutLibrary: AndroidLutLibrary?,
    onOpenRedDownload: () -> Unit,
    onRequestLutImport: (() -> Unit)?,
) {
    val state = assists.shared
    val haptics = LocalOperatorHaptics.current
    when (tool) {
        MonitorAssistTool.LUT -> LutOptions(assists, lutLibrary, onOpenRedDownload, onRequestLutImport)
        MonitorAssistTool.WAVE, MonitorAssistTool.PARADE ->
            nikonAssistSection(tool, state, cameraInput, haptics::selection)?.Menu()
        else -> MonitorOptionGroup {
            when (tool) {
                MonitorAssistTool.LEVEL ->
                    MonitorSettingsChoices(LocalLevelStyle.entries, settings.levelStyle, accentSelection = true,
                        title = LocalLevelStyle::label) { haptics.selection(); settings.levelStyle = it }
                MonitorAssistTool.GUIDES ->
                    MonitorGuidesMenu(state.guideFamily, state.selectedGuides, state.guideMask,
                        { haptics.selection(); state.updateGuideFamily(it) },
                        { haptics.selection(); state.toggleGuide(it) },
                        { haptics.selection(); state.updateGuideMask(it) })
                MonitorAssistTool.GRID ->
                    MonitorGridMenu(state.gridThirds, { state.setGridOption(thirds = it) }, state.gridPhi,
                        { state.setGridOption(phi = it) }, state.gridDiagonal, { state.setGridOption(diagonal = it) })
                MonitorAssistTool.DESQ ->
                    MonitorDesqueezeMenu(state.desqueezePreset, state.desqueezeCustom, state.desqueezeCustomFactor,
                        state.desqueezeDirection,
                        "Monitor only: the recording and the camera stay untouched. Horizontal widens a " +
                            "horizontally squeezed picture; vertical narrows it.",
                        onSelect = { if (it == null) state.selectCustomDesqueeze() else state.selectDesqueezePreset(it) },
                        onFactor = state::updateDesqueezeFactor, onDirection = state::updateDesqueezeDirection)
                MonitorAssistTool.CROSS -> MonitorAssistHelp("Tap the toolbar button to show or hide the centre crosshair.")
                else -> {
                    val section = nikonAssistSection(tool, state, cameraInput, haptics::selection)
                    if (section != null) section.Menu()
                    else MonitorAssistHelp(stringResource(R.string.settings_image_processing_unavailable))
                }
            }
        }
    }
}

@Composable
private fun OptionLabel(title: String) {
    Text(title, style = chromeStyle(11.5f, FontWeight.SemiBold), color = LiveDesign.text, maxLines = 1)
}

@Composable
private fun OptionCopy(message: String) {
    Text(message, style = chromeStyle(11f, FontWeight.Normal), color = LiveDesign.muted, maxLines = 3,
        overflow = TextOverflow.Ellipsis)
}

/** iOS `LUTPickerContent` category tabs. */
private enum class LutPopupCategory(val label: String) {
    BUILT_IN("Built-in"),
    RED("RED"),
    CUSTOM("Custom"),
}

/** iOS `RedOutputFilter` output-space filter over the RED list (raw file tokens). */
private enum class RedOutputSpaceFilter(val label: String, val needle: String?) {
    ALL("All", null),
    REC709("Rec.709", "REC709"),
    REC2020("Rec.2020", "REC2020"),
}

/** One row the LUT drum can land on. */
private data class LutWheelEntry(
    val label: String,
    val selected: Boolean,
    val apply: () -> Unit,
    val stored: com.opencapture.openzcine.lut.StoredLutEntry? = null,
)

@Composable
private fun LutOptions(
    assists: NikonAssists,
    lutLibrary: AndroidLutLibrary?,
    onOpenRedDownload: () -> Unit,
    onRequestLutImport: (() -> Unit)?,
) {
    val shared = assists.shared
    val storedEntries = lutLibrary?.entries?.collectAsState()?.value.orEmpty()
    val scope = rememberCoroutineScope()
    var feedback by remember { mutableStateOf<String?>(null) }
    // iOS opens on the tab of the currently applied LUT.
    var category by
        remember {
            mutableStateOf(
                when (val applied = assists.lut) {
                    is FeedLutSelection.Stored ->
                        if (applied.value.category == StoredLutCategory.RED) {
                            LutPopupCategory.RED
                        } else {
                            LutPopupCategory.CUSTOM
                        }
                    else -> LutPopupCategory.BUILT_IN
                },
            )
        }
    var redFilter by remember { mutableStateOf(RedOutputSpaceFilter.ALL) }
    var pendingDelete by
        remember { mutableStateOf<com.opencapture.openzcine.lut.StoredLutEntry?>(null) }

    val applyStored: (com.opencapture.openzcine.lut.StoredLutEntry) -> Unit = { entry ->
        val library = lutLibrary
        if (library != null) {
            scope.launch {
                if (library.prepare(entry.selection)) {
                    assists.selectLut(FeedLutSelection.Stored(entry.selection))
                    feedback = null
                } else {
                    feedback =
                        library.failures.value[entry.selection]?.operatorMessage
                            ?: "This LUT could not be prepared."
                }
            }
        }
    }
    MonitorSettingsChoices(LutPopupCategory.entries, category, accentSelection = true,
        title = LutPopupCategory::label) { next ->
        category = next
        pendingDelete = null
        // iOS `applyRepresentativeLUT`: switching tabs immediately applies that
        // tab's current (or first) look and switches the LUT tool on.
        when (next) {
            LutPopupCategory.BUILT_IN -> {
                val current =
                    (assists.lut as? FeedLutSelection.BuiltIn)?.value
                        ?: FeedLut.entries.first()
                assists.selectLut(FeedLutSelection.BuiltIn(current))
            }
            LutPopupCategory.RED, LutPopupCategory.CUSTOM -> {
                val storedCategory =
                    if (next == LutPopupCategory.RED) {
                        StoredLutCategory.RED
                    } else {
                        StoredLutCategory.CUSTOM
                    }
                val current =
                    (assists.lut as? FeedLutSelection.Stored)
                        ?.value
                        ?.takeIf { it.category == storedCategory }
                val target =
                    current?.let { active ->
                        storedEntries.firstOrNull { it.selection == active }
                    } ?: storedEntries.firstOrNull { it.selection.category == storedCategory }
                target?.let(applyStored)
            }
        }
    }

    when (category) {
        LutPopupCategory.BUILT_IN -> {
            LutDrumWheel(
                entries =
                    FeedLut.entries.map { lut ->
                        LutWheelEntry(
                            label = lut.label,
                            selected =
                                assists.lut ==
                                    FeedLutSelection.BuiltIn(lut),
                            apply = {
                                assists.selectLut(FeedLutSelection.BuiltIn(lut))
                                feedback = null
                            },
                        )
                    },
                onDeleteRequest = null,
            )
            // iOS `LUTPickerContent`: community-contributed looks are credited under the drum, not
            // inside the label: the drum row is one narrow monospaced line and a name would push
            // the look's own name out of it. The drum's height is fixed, so nothing shifts when the
            // credit appears and disappears with the selection.
            (assists.lut as? FeedLutSelection.BuiltIn)
                ?.value
                ?.credit
                ?.let { credit ->
                    Text(
                        credit,
                        style = chromeStyle(10.5f, FontWeight.Medium),
                        color = LiveDesign.muted,
                        maxLines = 1,
                        overflow = TextOverflow.Ellipsis,
                        modifier = Modifier.fillMaxWidth(),
                        textAlign = androidx.compose.ui.text.style.TextAlign.Center,
                    )
                }
        }
        LutPopupCategory.RED -> {
            // iOS filters on raw file name tokens (REC709 / REC2020), not display text.
            val redEntries =
                storedEntries
                    .filter { entry ->
                        entry.selection.category == StoredLutCategory.RED &&
                            (redFilter.needle == null ||
                                entry.selection.fileName.uppercase().contains(redFilter.needle!!))
                    }
                    .let { list ->
                        // Float the recommended default to the top (iOS LUTLibraryIndex.defaultRedLUT).
                        val default = defaultRedLutEntry(list)
                        if (default == null) list
                        else listOf(default) + list.filterNot { it.selection == default.selection }
                    }
            if (redEntries.isEmpty() && redFilter == RedOutputSpaceFilter.ALL) {
                // iOS empty RED tab: title + terms subtitle + Download CTA (always tappable).
                OptionLabel("RED IPP2 LUTs")
                OptionCopy("Download RED's official looks. You'll accept RED's terms.")
                CapsuleActionButton("Download from RED", enabled = true) {
                    onOpenRedDownload()
                }
            } else {
                MonitorSettingsChoices(RedOutputSpaceFilter.entries, redFilter,
                    title = RedOutputSpaceFilter::label) { redFilter = it }
                LutDrumWheel(
                    entries =
                        redEntries.map { entry ->
                            val isDefault =
                                defaultRedLutEntry(redEntries)?.selection == entry.selection
                            LutWheelEntry(
                                label =
                                    shortRedPresetName(entry.selection.fileName).let { short ->
                                        if (isDefault) "★ $short" else short
                                    },
                                selected =
                                    assists.lut ==
                                        FeedLutSelection.Stored(entry.selection),
                                apply = { applyStored(entry) },
                                stored = entry,
                            )
                        },
                    onDeleteRequest = { pendingDelete = it },
                )
            }
        }
        LutPopupCategory.CUSTOM -> {
            val customEntries =
                storedEntries.filter { it.selection.category == StoredLutCategory.CUSTOM }
            if (customEntries.isEmpty()) {
                OptionLabel("No custom LUTs yet")
                OptionCopy("Import a .cube file to add your own look.")
            } else {
                LutDrumWheel(
                    entries =
                        customEntries.map { entry ->
                            LutWheelEntry(
                                label = entry.displayName,
                                selected =
                                    assists.lut ==
                                        FeedLutSelection.Stored(entry.selection),
                                apply = { applyStored(entry) },
                                stored = entry,
                            )
                        },
                    onDeleteRequest = { pendingDelete = it },
                )
            }
            LutImportButton(onRequestLutImport)
        }
    }
    // 50/50 Log-vs-LUT comparison. The orientation row only appears while it is on; the stored
    // orientation itself survives either way, so switching back on returns to the operator's
    // choice rather than the default.
    // Comparison is meaningless with the grade off, so switching it on arms the LUT.
    MonitorSettingsSwitchInlineRow("50/50 Comparison", isOn = shared.splitComparison) {
        shared.setSplitComparison(!shared.splitComparison)
    }
    if (shared.splitComparison) {
        MonitorSettingsInlineRow("Split",
            help = "Log on one half, the selected LUT on the other, divided at the centre of the " +
                "image. Monitor only: nothing is written to the camera or the recording.") {
            MonitorSettingsChoices(listOf(true, false), shared.splitVertical,
                title = { if (it) "Left / Right" else "Top / Bottom" }) {
                shared.setSplitComparison(true, it)
            }
        }
    }
    pendingDelete?.let { entry ->
        LutDeleteConfirmRow(
            entry = entry,
            onCancel = { pendingDelete = null },
        ) {
            val library = lutLibrary ?: return@LutDeleteConfirmRow
            scope.launch {
                if (library.delete(entry.selection)) {
                    if (
                        assists.lut ==
                        FeedLutSelection.Stored(entry.selection)
                    ) {
                        // iOS: keep LUT tool on; same-category replacement else Log3G10→709.
                        val replacement = library.firstPreparedReplacement(entry.selection)
                        assists.selectLut(
                            replacement?.let(FeedLutSelection::Stored)
                                ?: FeedLutSelection.BuiltIn(FeedLut.LOG3G10_709),
                        )
                    }
                    feedback = "${entry.displayName} deleted."
                } else {
                    feedback = "This LUT could not be deleted."
                }
                pendingDelete = null
            }
        }
    }
    feedback?.let { message -> OptionCopy(message) }
}

/** iOS `LUTLibraryIndex.defaultRedLUT` preference order (file-name heuristics). */
private fun defaultRedLutEntry(
    entries: List<com.opencapture.openzcine.lut.StoredLutEntry>,
): com.opencapture.openzcine.lut.StoredLutEntry? {
    if (entries.isEmpty()) return null
    fun score(fileName: String): Int {
        val upper = fileName.uppercase()
        var s = 0
        if (upper.contains("REC709") || upper.contains("REC_709")) s += 4
        if (upper.contains("MEDIUM")) s += 2
        if (upper.contains("SOFT") || upper.contains("ROLLOFF")) s += 1
        if (upper.contains("CONTRAST")) s += 1
        return s
    }
    return entries.maxByOrNull { score(it.selection.fileName) }
}

/** iOS `RedPresetName.short`: strip N-Log/IPP2 noise for the drum. */
private fun shortRedPresetName(fileName: String): String {
    var name = fileName.removeSuffix(".cube").removeSuffix(".CUBE")
    name =
        name
            .replace(Regex("(?i)N[-_]?Log[_-]?"), "")
            .replace(Regex("(?i)IPP2[_-]?"), "")
            .replace('_', ' ')
            .replace(Regex("\\s+"), " ")
            .trim()
    return name.ifBlank { fileName }
}

/** iOS "Import .cube" capsule: opens the document picker straight from the popup. */
@Composable
private fun LutImportButton(
    onRequestImport: (() -> Unit)?,
) {
    // The document picker pauses the activity and this transient popup dismisses with it, so a
    // result launcher remembered HERE is disposed exactly when its result arrives, which
    // silently dropped every picked cube (#295). The monitor owns the launcher and the import;
    // this button only asks for the picker.
    CapsuleActionButton("Import .cube", enabled = onRequestImport != null) {
        onRequestImport?.invoke()
    }
}

/** iOS delete confirmation, inlined as a destructive row instead of a system dialog. */
@Composable
private fun LutDeleteConfirmRow(
    entry: com.opencapture.openzcine.lut.StoredLutEntry,
    onCancel: () -> Unit,
    onDelete: () -> Unit,
) {
    Row(
        Modifier.fillMaxWidth().heightIn(min = 38.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(8.dp),
    ) {
        Text(
            "Delete ${entry.displayName}?",
            style = chromeStyle(11.5f, FontWeight.SemiBold),
            color = LiveDesign.text,
            maxLines = 1,
            overflow = TextOverflow.Ellipsis,
            modifier = Modifier.weight(1f),
        )
        CapsuleActionButton("Cancel", enabled = true, onClick = onCancel)
        CapsuleActionButton(
            "Delete LUT",
            enabled = true,
            destructive = true,
            onClick = onDelete,
        )
    }
}

@Composable
private fun CapsuleActionButton(
    label: String,
    enabled: Boolean,
    destructive: Boolean = false,
    onClick: () -> Unit,
) {
    val tint = if (destructive) LiveDesign.rec else LiveDesign.accent
    Box(
        Modifier.height(32.dp)
            .background(LiveDesign.background.copy(alpha = 0.38f), ChromeShape)
            .border(1.dp, if (enabled) tint.copy(alpha = 0.6f) else LiveDesign.hairline, ChromeShape)
            .alpha(if (enabled) 1f else 0.45f)
            .chromeClickable(enabled, onClick)
            .padding(horizontal = 14.dp),
        contentAlignment = Alignment.Center,
    ) {
        Text(
            label,
            style = chromeStyle(11.5f, FontWeight.SemiBold),
            color = if (enabled) tint else LiveDesign.muted,
            maxLines = 1,
        )
    }
}

/**
 * iOS `AccentDrumWheel`: a snapping wheel. The settled row renders large in
 * accent between two hairlines; neighbours dim above and below. Settling on a
 * row applies it; long-press requests deletion for stored looks.
 */
@Composable
private fun LutDrumWheel(
    entries: List<LutWheelEntry>,
    onDeleteRequest: ((com.opencapture.openzcine.lut.StoredLutEntry) -> Unit)?,
) {
    if (entries.isEmpty()) return
    val rowHeightDp = 44.dp
    val wheelHeight = rowHeightDp * 3
    val listState =
        androidx.compose.foundation.lazy.rememberLazyListState(
            initialFirstVisibleItemIndex =
                entries.indexOfFirst(LutWheelEntry::selected).coerceAtLeast(0),
        )
    val fling =
        androidx.compose.foundation.gestures.snapping.rememberSnapFlingBehavior(
            lazyListState = listState,
            snapPosition = androidx.compose.foundation.gestures.snapping.SnapPosition.Center,
        )
    val centeredIndex by remember {
        androidx.compose.runtime.derivedStateOf {
            val layout = listState.layoutInfo
            val center = (layout.viewportStartOffset + layout.viewportEndOffset) / 2
            layout.visibleItemsInfo
                .minByOrNull { kotlin.math.abs(it.offset + it.size / 2 - center) }
                ?.index ?: 0
        }
    }
    LaunchedEffect(entries) {
        val index = entries.indexOfFirst(LutWheelEntry::selected).coerceAtLeast(0)
        listState.scrollToItem(index)
    }
    // Apply the row the wheel settles on, as iOS does on drum settle.
    LaunchedEffect(listState, entries) {
        androidx.compose.runtime.snapshotFlow { listState.isScrollInProgress to centeredIndex }
            .collect { (scrolling, index) ->
                if (!scrolling) {
                    entries.getOrNull(index)?.takeIf { !it.selected }?.apply?.invoke()
                }
            }
    }
    Box(Modifier.fillMaxWidth().height(wheelHeight)) {
        androidx.compose.foundation.lazy.LazyColumn(
            state = listState,
            flingBehavior = fling,
            contentPadding = androidx.compose.foundation.layout.PaddingValues(vertical = rowHeightDp),
            modifier = Modifier.fillMaxWidth().height(wheelHeight),
        ) {
            items(entries.size) { index ->
                val entry = entries[index]
                val isCentered = index == centeredIndex
                Box(
                    Modifier.fillMaxWidth()
                        .height(rowHeightDp)
                        .pointerInput(entry) {
                            detectTapGestures(
                                onTap = { entry.apply() },
                                onLongPress = {
                                    entry.stored?.let { onDeleteRequest?.invoke(it) }
                                },
                            )
                        },
                    contentAlignment = Alignment.Center,
                ) {
                    Text(
                        entry.label,
                        style =
                            chromeStyle(
                                if (isCentered) 20f else 14f,
                                if (isCentered) FontWeight.Bold else FontWeight.Medium,
                                mono = true,
                            ),
                        color = if (isCentered) LiveDesign.accent else LiveDesign.muted,
                        maxLines = 1,
                        overflow = TextOverflow.Ellipsis,
                    )
                }
            }
        }
        // Hairlines bracketing the settled row, like the iOS drum.
        Box(
            Modifier.fillMaxWidth()
                .height(1.dp)
                .align(Alignment.TopCenter)
                .offset(y = rowHeightDp)
                .background(LiveDesign.hairlineStrong),
        )
        Box(
            Modifier.fillMaxWidth()
                .height(1.dp)
                .align(Alignment.TopCenter)
                .offset(y = rowHeightDp * 2)
                .background(LiveDesign.hairlineStrong),
        )
    }
}

