package com.opencapture.openzcine.media

import androidx.compose.animation.core.animateDpAsState
import androidx.compose.animation.core.tween
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.gestures.detectTapGestures
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
import androidx.compose.foundation.layout.size
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
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.focus.onFocusChanged
import androidx.compose.ui.geometry.Rect
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.layout.onSizeChanged
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.role
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.IntOffset
import androidx.compose.ui.unit.IntSize
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.opencapture.openzcine.AssistState
import com.opencapture.openzcine.AssistToolGlyph
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
import com.opencapture.openzcine.IosPanelRevealSpec
import com.opencapture.openzcine.LiveDesign
import com.opencapture.openzcine.chromeClickable
import com.opencapture.openzcine.chromeStyle
import com.opencapture.openzcine.glass
import com.opencapture.openzcine.overlayGlass
import com.opencapture.openzcine.lut.AndroidLutLibrary
import com.opencapture.openzcine.lut.StoredLutCategory
import com.opencapture.openzcine.lut.StoredLutSelection
import com.opencapture.openzcine.settings.LocalDesqueezeOrientation
import com.opencapture.openzcine.settings.LocalDesqueezeRatio
import com.opencapture.openzcine.settings.LocalFramingAspectRatio
import com.opencapture.openzcine.settings.LocalFramingGuideFamily
import com.opencapture.openzcine.settings.LocalLevelStyle
import com.opencapture.openzcine.settings.OperatorSettings
import com.opencapture.openzcine.settings.PanelCloseButton
import com.opencapture.openzcine.settings.ScopeAssistConfiguration
import com.opencapture.openzcine.settings.ScopeCrushClipCompensation
import com.opencapture.openzcine.settings.ScopeGuideLines
import com.opencapture.openzcine.settings.ScopeParadeMode
import com.opencapture.openzcine.settings.ScopeVectorscopeZoom
import com.opencapture.openzcine.settings.ScopeWaveformMode
import com.opencapture.openzcine.zebraEditorValue
import com.opencapture.openzcine.zebraMonitorPercent
import kotlin.math.roundToInt
import kotlinx.coroutines.launch

/** Pure parity seam used by playback and JVM tests. Playback has no live camera horizon. */
internal fun hasPlaybackAssistOptions(tool: AssistTool): Boolean =
    tool.hasConfiguration && tool != AssistTool.LEVEL

/** Mirrors iOS by keeping the live-only camera horizon out of playback's assist toolbar. */
internal fun playbackAssistToolbarTools(tools: List<AssistTool>): List<AssistTool> =
    tools.filterNot { it == AssistTool.LEVEL }

/** Returns whether a live quick-settings panel still belongs to the visible monitor lifecycle. */
internal fun retainLiveAssistOptions(
    tool: AssistTool?,
    visibleTools: List<AssistTool>,
    liveMode: Boolean,
    locked: Boolean,
    resumed: Boolean,
): Boolean =
    tool != null && tool.hasConfiguration && tool in visibleTools && liveMode && !locked && resumed

/**
 * Pixel-space panel placement shared by live and playback overlays.
 * The popup prefers the space above its measured tool, falls below when that
 * is the only complete fit, and clamps every edge into [margin].
 */
internal fun assistOptionsPanelOffset(
    viewportWidth: Float,
    viewportHeight: Float,
    anchorBounds: Rect?,
    panelWidth: Float,
    panelHeight: Float,
    margin: Float = 12f,
    gap: Float = 10f,
): androidx.compose.ui.geometry.Offset {
    require(viewportWidth >= 0f && viewportHeight >= 0f) {
        "assist options viewport must be non-negative"
    }
    require(panelWidth >= 0f && panelHeight >= 0f) {
        "assist options panel must be non-negative"
    }
    val anchor = anchorBounds?.takeIf { it.width > 1f && it.height > 1f }
    val maximumX = (viewportWidth - panelWidth - margin).coerceAtLeast(margin)
    val maximumY = (viewportHeight - panelHeight - margin).coerceAtLeast(margin)
    val desiredX = anchor?.right?.minus(panelWidth) ?: margin
    val x = desiredX.coerceIn(margin, maximumX)
    if (anchor == null) {
        return androidx.compose.ui.geometry.Offset(x, maximumY)
    }

    val above = anchor.top - gap - panelHeight
    val below = anchor.bottom + gap
    val y =
        when {
            above >= margin -> above
            below <= maximumY -> below
            anchor.top >= viewportHeight - anchor.bottom -> above.coerceIn(margin, maximumY)
            else -> below.coerceIn(margin, maximumY)
        }
    return androidx.compose.ui.geometry.Offset(x, y)
}

private data class AssistOptionsActions(
    val sharedAssistState: AssistState,
    val isOn: (AssistTool) -> Boolean,
    val setVisible: (AssistTool, Boolean) -> Unit,
    val selectLut: (FeedLut) -> Unit,
    val selectStoredLut: (StoredLutSelection) -> Unit,
    val selectFalseColorScale: (FeedFalseColorScale) -> Unit,
    val resetFalseColorScale: () -> Unit,
    val recenterPanel: (() -> Unit)?,
    val contextLabel: String,
)

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
    AssistOptionsOverlay(
        tool = tool,
        anchorBounds = toolbarBounds,
        actions =
            AssistOptionsActions(
                sharedAssistState = sharedAssistState,
                isOn = playbackState::isOn,
                setVisible = playbackState::setVisible,
                selectLut = { playbackState.selectSharedLut(sharedAssistState, it) },
                selectStoredLut = {
                    playbackState.selectSharedStoredLut(sharedAssistState, it)
                },
                selectFalseColorScale = {
                    playbackState.selectSharedFalseColorScale(sharedAssistState, it)
                },
                resetFalseColorScale = {
                    playbackState.resetSharedFalseColorScale(sharedAssistState)
                },
                recenterPanel = null,
                contextLabel = "playback",
            ),
        settings = settings,
        cameraInput = cameraInput,
        lutLibrary = lutLibrary,
        onDismiss = onDismiss,
    )
}

/** Live-monitor counterpart using the same real persisted configuration surface. */
@Composable
internal fun LiveAssistOptionsOverlay(
    tool: AssistTool,
    anchorBounds: Rect?,
    assistState: AssistState,
    settings: OperatorSettings,
    cameraInput: ExposureAssistCameraInput,
    lutLibrary: AndroidLutLibrary?,
    onRecenterPanel: (() -> Unit)? = null,
    onDismiss: () -> Unit,
) {
    val isOn: (AssistTool) -> Boolean = { candidate ->
        if (candidate in AssistTool.framingTools) {
            settings.isLocalFramingToolVisible(candidate)
        } else {
            assistState.isOn(candidate)
        }
    }
    val setVisible: (AssistTool, Boolean) -> Unit = { candidate, visible ->
        if (candidate in AssistTool.framingTools) {
            settings.setLocalFramingToolVisible(candidate, visible)
        } else if (assistState.isOn(candidate) != visible) {
            assistState.toggle(candidate)
        }
    }
    AssistOptionsOverlay(
        tool = tool,
        anchorBounds = anchorBounds,
        actions =
            AssistOptionsActions(
                sharedAssistState = assistState,
                isOn = isOn,
                setVisible = setVisible,
                selectLut = assistState::selectLut,
                selectStoredLut = assistState::selectStoredLut,
                selectFalseColorScale = assistState::selectFalseColorScale,
                resetFalseColorScale = assistState::resetFalseColorSelection,
                recenterPanel = onRecenterPanel,
                contextLabel = "live monitor",
            ),
        settings = settings,
        cameraInput = cameraInput,
        lutLibrary = lutLibrary,
        onDismiss = onDismiss,
    )
}

@Composable
private fun AssistOptionsOverlay(
    tool: AssistTool,
    anchorBounds: Rect?,
    actions: AssistOptionsActions,
    settings: OperatorSettings,
    cameraInput: ExposureAssistCameraInput,
    lutLibrary: AndroidLutLibrary?,
    onDismiss: () -> Unit,
) {
    BoxWithConstraints(Modifier.fillMaxSize()) {
        val density = LocalDensity.current
        val preferredWidth = if (tool == AssistTool.GUIDES) 472.dp else 400.dp
        val panelWidth = minOf(preferredWidth, (maxWidth - 24.dp).coerceAtLeast(0.dp))
        val maxPanelHeight = (maxHeight - 24.dp).coerceAtLeast(0.dp)
        var panelSize by remember(tool) { mutableStateOf(IntSize.Zero) }
        var revealed by remember(tool) { mutableStateOf(false) }
        // iOS parks the panel fully below the screen (height + slack) then slides
        // up with panelRevealCurve — not a short 24dp nudge.
        val panelHeightDp =
            with(density) { panelSize.height.toDp() }.takeIf { panelSize.height > 0 } ?: 280.dp
        val travel = panelHeightDp + 40.dp
        val revealOffset by
            animateDpAsState(
                targetValue = if (revealed) 0.dp else travel,
                animationSpec = IosPanelRevealSpec,
                label = "assist panel reveal",
            )
        LaunchedEffect(tool) { revealed = true }
        val viewportWidthPx = with(density) { maxWidth.toPx() }
        val viewportHeightPx = with(density) { maxHeight.toPx() }
        val panelOffset =
            assistOptionsPanelOffset(
                viewportWidth = viewportWidthPx,
                viewportHeight = viewportHeightPx,
                anchorBounds = anchorBounds,
                panelWidth = panelSize.width.toFloat(),
                panelHeight = panelSize.height.toFloat(),
                margin = with(density) { 12.dp.toPx() },
                gap = with(density) { 10.dp.toPx() },
            )
        val revealOffsetPx = with(density) { revealOffset.toPx() }

        Box(
            Modifier.fillMaxSize()
                .semantics {
                    contentDescription = "Dismiss ${tool.settingsTitle} options"
                    role = Role.Button
                }.chromeClickable(onDismiss),
        )
        Column(
            Modifier.offset {
                IntOffset(
                    panelOffset.x.roundToInt(),
                    (panelOffset.y + revealOffsetPx).roundToInt(),
                )
            }
                .width(panelWidth)
                .heightIn(max = maxPanelHeight)
                .onSizeChanged { panelSize = it }
                .alpha(if (revealed) 1f else 0f)
                // Scene overlay: blur chrome + feed under assist options.
                .overlayGlass(ChromeShape)
                .border(1.dp, LiveDesign.hairlineStrong, ChromeShape)
                // The panel is a sibling above the backdrop. This no-op detector keeps blank panel
                // chrome from dismissing while child controls retain their own gestures.
                .pointerInput(Unit) { detectTapGestures(onTap = {}) }
                // iOS AssistPanel GlassPanel pad 16 all sides.
                .padding(16.dp),
            verticalArrangement = Arrangement.spacedBy(10.dp),
        ) {
            Row(
                Modifier.fillMaxWidth(),
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(8.dp),
            ) {
                AssistToolGlyph(
                    tool,
                    tint = LiveDesign.text,
                    modifier = Modifier.width(15.dp).height(15.dp),
                )
                Text(
                    tool.settingsTitle.uppercase(),
                    modifier = Modifier.weight(1f),
                    style = chromeStyle(14f, FontWeight.Bold).copy(letterSpacing = 1.2.sp),
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
                    actions = actions,
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
    actions: AssistOptionsActions,
    settings: OperatorSettings,
    cameraInput: ExposureAssistCameraInput,
    lutLibrary: AndroidLutLibrary?,
) {
    when (tool) {
        AssistTool.LUT -> LutOptions(actions, lutLibrary)
        AssistTool.FALSE -> FalseColorOptions(actions, settings)
        AssistTool.PEAK -> PeakingOptions(settings)
        AssistTool.ZEBRA -> ZebraOptions(settings, cameraInput)
        AssistTool.WAVE -> WaveformOptions(settings)
        AssistTool.PARADE -> ParadeOptions(settings)
        AssistTool.HISTO -> HistogramOptions(settings)
        AssistTool.VECTOR -> VectorscopeOptions(settings)
        AssistTool.LIGHTS -> TrafficLightsOptions(settings)
        AssistTool.GUIDES -> GuideOptions(actions, settings)
        AssistTool.GRID -> GridOptions(settings)
        AssistTool.CROSS ->
            OptionCopy("Tap the toolbar button to show or hide the centre crosshair.")
        AssistTool.LEVEL -> LevelOptions(actions, settings)
        AssistTool.DESQ -> DesqueezeOptions(actions, settings)
        AssistTool.AUDIO ->
            OptionCopy("Meters the playing clip's audio. Available during media playback.")
    }
}

/** iOS `LUTPickerContent` category tabs. */
private enum class LutPopupCategory(val label: String) {
    BUILT_IN("Built-in"),
    RED("RED"),
    CUSTOM("Custom"),
}

/** iOS `RedOutputFilter` output-space filter over the RED list. */
private enum class RedOutputSpaceFilter(val label: String, val needle: String?) {
    ALL("All", null),
    REC709("Rec.709", "709"),
    REC2020("Rec.2020", "2020"),
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
    actions: AssistOptionsActions,
    lutLibrary: AndroidLutLibrary?,
) {
    val storedEntries = lutLibrary?.entries?.collectAsState()?.value.orEmpty()
    val scope = rememberCoroutineScope()
    var feedback by remember { mutableStateOf<String?>(null) }
    // iOS opens on the tab of the currently applied LUT.
    var category by
        remember {
            mutableStateOf(
                when (val applied = actions.sharedAssistState.selectedLut) {
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
                    actions.selectStoredLut(entry.selection)
                    actions.setVisible(AssistTool.LUT, true)
                    feedback = null
                } else {
                    feedback =
                        library.failures.value[entry.selection]?.operatorMessage
                            ?: "This LUT could not be prepared."
                }
            }
        }
    }
    SegmentedChoice(
        LutPopupCategory.entries.toList(),
        LutPopupCategory::label,
        selected = { category == it },
    ) { next ->
        category = next
        pendingDelete = null
        // iOS `applyRepresentativeLUT`: switching tabs immediately applies that
        // tab's current (or first) look and switches the LUT tool on.
        when (next) {
            LutPopupCategory.BUILT_IN -> {
                val current =
                    (actions.sharedAssistState.selectedLut as? FeedLutSelection.BuiltIn)?.value
                        ?: FeedLut.entries.first()
                actions.selectLut(current)
                actions.setVisible(AssistTool.LUT, true)
            }
            LutPopupCategory.RED, LutPopupCategory.CUSTOM -> {
                val storedCategory =
                    if (next == LutPopupCategory.RED) {
                        StoredLutCategory.RED
                    } else {
                        StoredLutCategory.CUSTOM
                    }
                val current =
                    (actions.sharedAssistState.selectedLut as? FeedLutSelection.Stored)
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
        LutPopupCategory.BUILT_IN ->
            LutDrumWheel(
                entries =
                    FeedLut.entries.map { lut ->
                        LutWheelEntry(
                            label = lut.label,
                            selected =
                                actions.sharedAssistState.selectedLut ==
                                    FeedLutSelection.BuiltIn(lut),
                            apply = {
                                actions.selectLut(lut)
                                actions.setVisible(AssistTool.LUT, true)
                                feedback = null
                            },
                        )
                    },
                onDeleteRequest = null,
            )
        LutPopupCategory.RED -> {
            val redEntries =
                storedEntries.filter { entry ->
                    entry.selection.category == StoredLutCategory.RED &&
                        (redFilter.needle == null || entry.displayName.contains(redFilter.needle!!))
                }
            if (redEntries.isEmpty() && redFilter == RedOutputSpaceFilter.ALL) {
                // iOS placeholder shape: a titled empty state with the download
                // capsule; RED delivery stays fail-closed on Android for now.
                OptionLabel("RED IPP2 LUTs")
                OptionCopy("Authorized RED looks downloaded in Operator Setup appear here.")
                CapsuleActionButton("Download from RED", enabled = false) {}
            } else {
                CompactSegmented(
                    RedOutputSpaceFilter.entries.toList(),
                    RedOutputSpaceFilter::label,
                    selected = { redFilter == it },
                ) { redFilter = it }
                LutDrumWheel(
                    entries =
                        redEntries.map { entry ->
                            LutWheelEntry(
                                label = entry.displayName,
                                selected =
                                    actions.sharedAssistState.selectedLut ==
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
                OptionCopy("No custom LUTs yet.")
            } else {
                LutDrumWheel(
                    entries =
                        customEntries.map { entry ->
                            LutWheelEntry(
                                label = entry.displayName,
                                selected =
                                    actions.sharedAssistState.selectedLut ==
                                        FeedLutSelection.Stored(entry.selection),
                                apply = { applyStored(entry) },
                                stored = entry,
                            )
                        },
                    onDeleteRequest = { pendingDelete = it },
                )
            }
            LutImportButton(lutLibrary, scope) { feedback = it }
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
                        actions.sharedAssistState.selectedLut ==
                        FeedLutSelection.Stored(entry.selection)
                    ) {
                        library.firstPreparedReplacement(entry.selection)
                            ?.let(actions.selectStoredLut)
                            ?: actions.setVisible(AssistTool.LUT, false)
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

/** iOS "Import .cube" capsule: opens the document picker straight from the popup. */
@Composable
private fun LutImportButton(
    lutLibrary: AndroidLutLibrary?,
    scope: kotlinx.coroutines.CoroutineScope,
    onFeedback: (String) -> Unit,
) {
    val launcher =
        androidx.activity.compose.rememberLauncherForActivityResult(
            androidx.activity.result.contract.ActivityResultContracts.OpenDocument(),
        ) { uri ->
            val library = lutLibrary ?: return@rememberLauncherForActivityResult
            if (uri != null) {
                scope.launch {
                    when (val result = library.importFromDocument(uri)) {
                        is com.opencapture.openzcine.lut.CustomLutImportResult.Imported ->
                            onFeedback("${result.entry.displayName} imported.")
                        is com.opencapture.openzcine.lut.CustomLutImportResult.Rejected ->
                            onFeedback(result.message)
                    }
                }
            }
        }
    CapsuleActionButton("Import .cube", enabled = lutLibrary != null) {
        launcher.launch(arrayOf("*/*"))
    }
}

/** iOS delete confirmation, inlined as a destructive row instead of a system dialog. */
@Composable
private fun LutDeleteConfirmRow(
    entry: com.opencapture.openzcine.lut.StoredLutEntry,
    onCancel: () -> Unit,
    onDelete: () -> Unit,
) {
    AssistRowDivider()
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
 * iOS `AccentDrumWheel`: a snapping wheel — the settled row renders large in
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
    // Apply the row the wheel settles on — iOS applies on drum settle.
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

@Composable
private fun FalseColorOptions(
    actions: AssistOptionsActions,
    settings: OperatorSettings,
) {
    val configuration = settings.feedEffectsConfiguration
    AssistInlineRow(
        "Scale",
        help =
            "The camera signal selects Log3G10 or N-Log automatically. ZC Stops marks minimum " +
                "exposure, −3, 18% gray, skin, +2, and three clip-relative highlight levels over " +
                "luminance grayscale. IRE uses RED Video Mode-style monitor ranges after " +
                "curve-aware display mapping, with 18% gray at 42 IRE and the camera clip at " +
                "100. Limits paints only shadow and highlight warnings, leaving other colors " +
                "untouched.",
        divider = false,
    ) {
        CompactSegmented(
            options = FeedFalseColorScale.entries.toList(),
            label = FeedFalseColorScale::label,
            selected = { actions.sharedAssistState.selectedFalseColorScale == it },
        ) { scale -> actions.selectFalseColorScale(scale) }
    }
    SwitchInlineRow(
        title = "Reference Display",
        isOn = configuration.falseColorReferenceEnabled,
        help = "Show a compact color key over live view while False Color is active.",
    ) {
        val enabled = !settings.feedEffectsConfiguration.falseColorReferenceEnabled
        settings.feedEffectsConfiguration =
            settings.feedEffectsConfiguration.copy(falseColorReferenceEnabled = enabled)
        if (enabled) actions.setVisible(AssistTool.FALSE, true)
    }
}

@Composable
private fun PeakingOptions(settings: OperatorSettings) {
    val configuration = settings.feedEffectsConfiguration
    AssistInlineRow(
        "Sensitivity",
        help = "Higher sensitivity catches finer edges but can get noisy on detailed scenes.",
        divider = false,
    ) {
        CompactSegmented(
            options = FeedPeakingSensitivity.entries.toList(),
            label = FeedPeakingSensitivity::label,
            selected = { configuration.peakingSensitivity == it },
        ) { settings.feedEffectsConfiguration = configuration.copy(peakingSensitivity = it) }
    }
    AssistInlineRow(
        "Color",
        help = "Choose the edge color that stays readable over your typical scene.",
    ) {
        ColorDotsRow(
            options = FeedPeakingColor.entries.toList(),
            label = FeedPeakingColor::label,
            swatch = ::peakingSwatch,
            selected = { configuration.peakingColor == it },
        ) { settings.feedEffectsConfiguration = configuration.copy(peakingColor = it) }
    }
}

private fun peakingSwatch(color: FeedPeakingColor): androidx.compose.ui.graphics.Color =
    when (color) {
        FeedPeakingColor.WHITE -> androidx.compose.ui.graphics.Color.White
        FeedPeakingColor.BLUE -> androidx.compose.ui.graphics.Color(0xFF3E7BFF)
        FeedPeakingColor.RED -> androidx.compose.ui.graphics.Color(0xFFE5484D)
        FeedPeakingColor.GREEN -> androidx.compose.ui.graphics.Color(0xFF3DBE6B)
    }

private fun zebraSwatch(color: FeedZebraStripeColor): androidx.compose.ui.graphics.Color =
    when (color) {
        FeedZebraStripeColor.WHITE -> androidx.compose.ui.graphics.Color.White
        FeedZebraStripeColor.AMBER -> androidx.compose.ui.graphics.Color(0xFFE5A13A)
        FeedZebraStripeColor.RED -> androidx.compose.ui.graphics.Color(0xFFE5484D)
        FeedZebraStripeColor.CYAN -> androidx.compose.ui.graphics.Color(0xFF39C4D6)
        FeedZebraStripeColor.GREEN -> androidx.compose.ui.graphics.Color(0xFF3DBE6B)
    }

/** iOS zebra palettes: three stripe colors per zone, not the full enum. */
private val zebraHighlightPalette =
    listOf(FeedZebraStripeColor.WHITE, FeedZebraStripeColor.AMBER, FeedZebraStripeColor.RED)
private val zebraMidtonePalette =
    listOf(FeedZebraStripeColor.AMBER, FeedZebraStripeColor.CYAN, FeedZebraStripeColor.GREEN)

@Composable
private fun ZebraOptions(settings: OperatorSettings, cameraInput: ExposureAssistCameraInput) {
    val configuration = settings.feedEffectsConfiguration
    AssistInlineRow(
        "Units",
        help =
            "Switch between Nikon-style native 0-255 codes and OpenZCine's normalized 0-100 " +
                "monitoring IRE scale.",
        divider = false,
    ) {
        CompactSegmented(
            options = FeedZebraUnit.entries.toList(),
            label = FeedZebraUnit::label,
            selected = { configuration.zebraUnit == it },
        ) { settings.feedEffectsConfiguration = configuration.copy(zebraUnit = it) }
    }
    ZebraZoneRow(
        title = "Highlight",
        help =
            "High zebra warns when bright detail approaches clipping after the active log " +
                "curve is compensated.",
        enabled = configuration.zebraHighlightEnabled,
        onEnabledToggle = {
            settings.feedEffectsConfiguration =
                configuration.copy(zebraHighlightEnabled = !configuration.zebraHighlightEnabled)
        },
        cameraInput = cameraInput,
        unit = configuration.zebraUnit,
        monitorPercent = configuration.zebraHighlightIre,
        onThreshold = {
            settings.feedEffectsConfiguration = configuration.copy(zebraHighlightIre = it)
        },
        palette = zebraHighlightPalette,
        color = configuration.zebraHighlightColor,
        onColor = {
            settings.feedEffectsConfiguration = configuration.copy(zebraHighlightColor = it)
        },
    )
    ZebraZoneRow(
        title = "Midtone",
        help =
            "Midtone zebra gives a curve-compensated reference band for faces or key subject " +
                "exposure.",
        enabled = configuration.zebraMidtoneEnabled,
        onEnabledToggle = {
            settings.feedEffectsConfiguration =
                configuration.copy(zebraMidtoneEnabled = !configuration.zebraMidtoneEnabled)
        },
        cameraInput = cameraInput,
        unit = configuration.zebraUnit,
        monitorPercent = configuration.zebraMidtoneIre,
        onThreshold = {
            settings.feedEffectsConfiguration = configuration.copy(zebraMidtoneIre = it)
        },
        palette = zebraMidtonePalette,
        color = configuration.zebraMidtoneColor,
        onColor = {
            settings.feedEffectsConfiguration = configuration.copy(zebraMidtoneColor = it)
        },
    )
}

/**
 * iOS `zebraZoneRow`: label + help on the left, then — on the SAME row — the
 * enable switch, the tappable numeric threshold field, and the zone's three
 * stripe-color dots. Camera-gated: without the shared exposure mapping the
 * field is absent and the explanatory copy renders under the row.
 */
@Composable
private fun ZebraZoneRow(
    title: String,
    help: String,
    enabled: Boolean,
    onEnabledToggle: () -> Unit,
    cameraInput: ExposureAssistCameraInput,
    unit: FeedZebraUnit,
    monitorPercent: Float,
    onThreshold: (Float) -> Unit,
    palette: List<FeedZebraStripeColor>,
    color: FeedZebraStripeColor,
    onColor: (FeedZebraStripeColor) -> Unit,
) {
    val editorValue =
        remember(cameraInput, unit, monitorPercent) {
            zebraEditorValue(cameraInput, unit, monitorPercent)
        }
    AssistRowDivider()
    Row(
        Modifier.fillMaxWidth().heightIn(min = 44.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(6.dp),
    ) {
        OptionLabel(title)
        HelpBadge(help)
        Spacer(Modifier.weight(1f))
        androidx.compose.material3.Switch(
            checked = enabled,
            onCheckedChange = { onEnabledToggle() },
            colors =
                androidx.compose.material3.SwitchDefaults.colors(
                    checkedTrackColor = LiveDesign.accent,
                    checkedThumbColor = LiveDesign.background,
                ),
        )
        if (editorValue != null) {
            val maximum = if (unit == FeedZebraUnit.NATIVE) 255 else 100
            NumberValueField(
                value = editorValue.roundToInt(),
                range = 0..maximum,
            ) { value ->
                zebraMonitorPercent(cameraInput, unit, value.toFloat())?.let(onThreshold)
            }
        }
        ColorDotsRow(
            options = palette,
            label = FeedZebraStripeColor::label,
            swatch = ::zebraSwatch,
            selected = { color == it },
            onSelect = onColor,
        )
    }
    if (editorValue == null) {
        OptionCopy("$title threshold is unavailable until the shared exposure mapping is ready.")
    }
}

@Composable
private fun WaveformOptions(settings: OperatorSettings) {
    val configuration = settings.scopeAssistConfiguration
    AssistInlineRow("Mode", divider = false) {
        CompactSegmented(
            ScopeWaveformMode.entries.toList(),
            ScopeWaveformMode::label,
            selected = { configuration.waveformMode == it },
        ) { settings.scopeAssistConfiguration = configuration.copy(waveformMode = it) }
    }
    BrightnessSlider(
        "Brightness",
        configuration.waveformBrightness,
        help = "Raise trace intensity when the waveform is hard to read in bright light.",
    ) {
        settings.scopeAssistConfiguration = configuration.copy(waveformBrightness = it)
    }
    ScopeGuides(configuration.waveformGuides) {
        settings.scopeAssistConfiguration = configuration.copy(waveformGuides = it)
    }
}

@Composable
private fun ParadeOptions(settings: OperatorSettings) {
    val configuration = settings.scopeAssistConfiguration
    AssistInlineRow("Mode", divider = false) {
        CompactSegmented(
            ScopeParadeMode.entries.toList(),
            ScopeParadeMode::label,
            selected = { configuration.paradeMode == it },
        ) { settings.scopeAssistConfiguration = configuration.copy(paradeMode = it) }
    }
    BrightnessSlider(
        "Brightness",
        configuration.paradeBrightness,
        help = "Raise trace intensity when channel separation is hard to see.",
    ) {
        settings.scopeAssistConfiguration = configuration.copy(paradeBrightness = it)
    }
    ScopeGuides(configuration.paradeGuides) {
        settings.scopeAssistConfiguration = configuration.copy(paradeGuides = it)
    }
}

@Composable
private fun VectorscopeOptions(settings: OperatorSettings) {
    val configuration = settings.scopeAssistConfiguration
    AssistInlineRow(
        "Trace Zoom",
        help =
            "Magnifies only the chroma trace; the graticule stays at unity. The vectorscope " +
                "reads the monitor image (your active LUT, or the built-in display tone map), " +
                "where chroma is meaningful.",
        divider = false,
    ) {
        CompactSegmented(
            ScopeVectorscopeZoom.entries.toList(),
            ScopeVectorscopeZoom::label,
            selected = { configuration.vectorscopeZoom == it },
        ) { settings.scopeAssistConfiguration = configuration.copy(vectorscopeZoom = it) }
    }
    BrightnessSlider(
        "Brightness",
        configuration.vectorscopeBrightness,
        help = "Raise trace intensity when the chroma plot is hard to read.",
    ) {
        settings.scopeAssistConfiguration = configuration.copy(vectorscopeBrightness = it)
    }
}

@Composable
private fun HistogramOptions(settings: OperatorSettings) {
    SwitchInlineRow(
        "Traffic Lights",
        settings.histogramTrafficLightsEnabled.value,
        help = "Show small RGB edge blocks for crushed and clipped channels.",
        divider = false,
    ) { settings.histogramTrafficLightsEnabled.toggle() }
    CompensationChoices(
        settings,
        help =
            "Stops of crush/clip tolerance before a traffic light glows. Shared with the " +
                "goal-post meter.",
    )
}

@Composable
private fun TrafficLightsOptions(settings: OperatorSettings) {
    CompensationChoices(
        settings,
        help =
            "Stops of crush/clip tolerance before a channel indicator glows. Shared with the " +
                "histogram traffic lights.",
        divider = false,
    )
}

@Composable
private fun CompensationChoices(
    settings: OperatorSettings,
    help: String? = null,
    divider: Boolean = true,
) {
    AssistInlineRow("Crush/Clip Compensation", help = help, divider = divider) {
        CompactSegmented(
            ScopeCrushClipCompensation.entries.toList(),
            // iOS renders the fraction glyphs (0 · ¼ · ½ · ¾ · 1).
            ScopeCrushClipCompensation::compactLabel,
            selected = { settings.scopeCrushClipCompensation == it },
        ) { settings.scopeCrushClipCompensation = it }
    }
}

@Composable
private fun GuideOptions(actions: AssistOptionsActions, settings: OperatorSettings) {
    SegmentedChoice(
        LocalFramingGuideFamily.entries.toList(),
        LocalFramingGuideFamily::label,
        selected = { settings.guideFamily == it },
    ) { settings.guideFamily = it }
    run {
        val ratios = LocalFramingAspectRatio.forFamily(settings.guideFamily)
        Column(verticalArrangement = Arrangement.spacedBy(6.dp)) {
            ratios.chunked(5).forEach { row ->
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
                            actions.setVisible(AssistTool.GUIDES, next.isNotEmpty())
                        }
                    }
                    repeat(5 - row.size) { Spacer(Modifier.weight(1f)) }
                }
            }
        }
    }
    CircleToggleRow(
        "Mask outside frame",
        settings.guideMaskEnabled.value,
    ) { settings.guideMaskEnabled.toggle() }
}

@Composable
private fun GridOptions(settings: OperatorSettings) {
    run {
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
private fun LevelOptions(actions: AssistOptionsActions, settings: OperatorSettings) {
    SegmentedChoice(
        LocalLevelStyle.entries.toList(),
        LocalLevelStyle::label,
        selected = { settings.levelStyle == it },
    ) { settings.levelStyle = it }
}

@Composable
private fun DesqueezeOptions(actions: AssistOptionsActions, settings: OperatorSettings) {
    CircleToggleRow(
        "Enable",
        actions.isOn(AssistTool.DESQ),
        divider = false,
    ) { actions.setVisible(AssistTool.DESQ, !actions.isOn(AssistTool.DESQ)) }
    SegmentedChoice(
        LocalDesqueezeRatio.entries.toList(),
        LocalDesqueezeRatio::label,
        selected = { settings.desqueezeRatio == it },
    ) { settings.desqueezeRatio = it }
    SegmentedChoice(
        LocalDesqueezeOrientation.entries.toList(),
        LocalDesqueezeOrientation::label,
        selected = { settings.desqueezeOrientation == it },
    ) { settings.desqueezeOrientation = it }
}

@Composable
private fun ScopeGuides(guides: ScopeGuideLines, onChange: (ScopeGuideLines) -> Unit) {
    SwitchInlineRow("Safe Border Clip", guides.clip) {
        onChange(guides.copy(clip = !guides.clip))
    }
    SwitchInlineRow("Safe Border Crush", guides.crush) {
        onChange(guides.copy(crush = !guides.crush))
    }
    SwitchInlineRow("Middle Gray", guides.middle) {
        onChange(guides.copy(middle = !guides.middle))
    }
}

/**
 * iOS `SettingsPercentSlider` row: label + help on the left, the slider and a
 * fixed-width percent readout right-aligned on the SAME row.
 */
@OptIn(androidx.compose.material3.ExperimentalMaterial3Api::class)
@Composable
private fun BrightnessSlider(
    title: String,
    value: Int,
    help: String? = null,
    onChange: (Int) -> Unit,
) {
    AssistRowDivider()
    Row(
        Modifier.fillMaxWidth().heightIn(min = 38.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(6.dp),
    ) {
        OptionLabel(title)
        help?.let { HelpBadge(it) }
        Spacer(Modifier.weight(1f))
        Slider(
            value =
                value.toFloat()
                    .coerceIn(
                        ScopeAssistConfiguration.MIN_BRIGHTNESS.toFloat(),
                        ScopeAssistConfiguration.MAX_BRIGHTNESS.toFloat(),
                    ),
            onValueChange = { onChange(it.roundToInt()) },
            valueRange =
                ScopeAssistConfiguration.MIN_BRIGHTNESS.toFloat()..
                    ScopeAssistConfiguration.MAX_BRIGHTNESS.toFloat(),
            colors =
                SliderDefaults.colors(
                    activeTrackColor = LiveDesign.accent,
                    inactiveTrackColor = LiveDesign.hairlineStrong,
                ),
            // iOS renders a round white knob, not Material's bar handle.
            thumb = {
                Box(
                    Modifier.size(22.dp)
                        .background(
                            androidx.compose.ui.graphics.Color.White,
                            androidx.compose.foundation.shape.CircleShape,
                        ),
                )
            },
            modifier = Modifier.width(150.dp).height(32.dp),
        )
        Text(
            "$value%",
            style = chromeStyle(11.5f, FontWeight.Medium, mono = true),
            color = LiveDesign.text,
            modifier = Modifier.widthIn(min = 40.dp),
            textAlign = androidx.compose.ui.text.style.TextAlign.End,
        )
    }
}

/** iOS row separator: a full-width hairline between quick-settings rows. */
@Composable
private fun AssistRowDivider() {
    Box(Modifier.fillMaxWidth().height(1.dp).background(LiveDesign.hairline))
}

/**
 * iOS `SettingsInlineRow`: one flat row — label plus optional `?` help badge on
 * the left, the control right-aligned — with a hairline above every row except
 * the panel's first. This is the popup grammar; sectioned stacks are not.
 */
@Composable
private fun AssistInlineRow(
    title: String,
    help: String? = null,
    divider: Boolean = true,
    control: @Composable () -> Unit,
) {
    if (divider) AssistRowDivider()
    Row(
        Modifier.fillMaxWidth().heightIn(min = 38.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(6.dp),
    ) {
        OptionLabel(title)
        help?.let { HelpBadge(it) }
        Spacer(Modifier.weight(1f))
        control()
    }
}

/**
 * iOS `SettingsSegmented`: a compact right-aligned pill whose segments size to
 * their text — unlike the full-width [SegmentedChoice] kept for the framing
 * pickers that iOS also renders full width.
 */
@Composable
private fun <T> CompactSegmented(
    options: List<T>,
    label: (T) -> String,
    selected: (T) -> Boolean,
    onSelect: (T) -> Unit,
) {
    Row(
        Modifier.background(LiveDesign.background.copy(alpha = 0.38f), ChromeShape)
            .border(1.dp, LiveDesign.hairline, ChromeShape)
            .padding(3.dp)
            .selectableGroup(),
        horizontalArrangement = Arrangement.spacedBy(2.dp),
    ) {
        options.forEach { option ->
            val isSelected = selected(option)
            Box(
                Modifier.height(30.dp)
                    .background(
                        if (isSelected) {
                            LiveDesign.accentDim
                        } else {
                            androidx.compose.ui.graphics.Color.Transparent
                        },
                        ChromeShape,
                    )
                    .selectable(selected = isSelected, role = Role.RadioButton) {
                        onSelect(option)
                    }
                    .padding(horizontal = 12.dp),
                contentAlignment = Alignment.Center,
            ) {
                Text(
                    label(option),
                    style = chromeStyle(11.5f, FontWeight.SemiBold),
                    color = if (isSelected) LiveDesign.accent else LiveDesign.muted,
                    maxLines = 1,
                )
            }
        }
    }
}

/**
 * iOS `SettingsNumberField`: a tappable mono value pill that edits in place
 * with the numeric keyboard and clamps on commit.
 */
@Composable
private fun NumberValueField(
    value: Int,
    range: IntRange,
    onCommit: (Int) -> Unit,
) {
    var editing by remember { mutableStateOf(false) }
    var draft by remember(value) { mutableStateOf(value.toString()) }
    val commit = {
        draft.toIntOrNull()?.let { onCommit(it.coerceIn(range)) }
        editing = false
    }
    Box(
        Modifier.height(30.dp)
            .widthIn(min = 46.dp)
            .background(LiveDesign.background.copy(alpha = 0.38f), ChromeShape)
            .border(1.dp, LiveDesign.hairline, ChromeShape)
            .then(
                if (editing) Modifier else Modifier.chromeClickable(true) { editing = true },
            )
            .padding(horizontal = 8.dp),
        contentAlignment = Alignment.Center,
    ) {
        if (editing) {
            androidx.compose.foundation.text.BasicTextField(
                value = draft,
                onValueChange = { next -> draft = next.filter(Char::isDigit).take(3) },
                textStyle =
                    chromeStyle(13f, FontWeight.Medium, mono = true)
                        .copy(
                            color = LiveDesign.text,
                            textAlign = androidx.compose.ui.text.style.TextAlign.Center,
                        ),
                keyboardOptions =
                    androidx.compose.foundation.text.KeyboardOptions(
                        keyboardType = androidx.compose.ui.text.input.KeyboardType.Number,
                        imeAction = androidx.compose.ui.text.input.ImeAction.Done,
                    ),
                keyboardActions =
                    androidx.compose.foundation.text.KeyboardActions(onDone = { commit() }),
                singleLine = true,
                cursorBrush = androidx.compose.ui.graphics.SolidColor(LiveDesign.accent),
                modifier =
                    Modifier.widthIn(min = 30.dp, max = 52.dp)
                        .onFocusChanged { if (!it.isFocused && editing) commit() }
                        .focusRequester(rememberEditFocus()),
            )
        } else {
            Text(
                value.toString(),
                style = chromeStyle(13f, FontWeight.Medium, mono = true),
                color = LiveDesign.text,
            )
        }
    }
}

/** Requests focus once for the in-place number editor as it appears. */
@Composable
private fun rememberEditFocus(): androidx.compose.ui.focus.FocusRequester {
    val requester = remember { androidx.compose.ui.focus.FocusRequester() }
    LaunchedEffect(Unit) { requester.requestFocus() }
    return requester
}

/** iOS `HelpBadge`: a quiet "?" that reveals the row's help copy in a glass popover. */
@Composable
private fun HelpBadge(text: String) {
    var open by remember { mutableStateOf(false) }
    Box {
        Box(
            Modifier.height(16.dp)
                .widthIn(min = 16.dp)
                .border(1.dp, LiveDesign.hairlineStrong, androidx.compose.foundation.shape.CircleShape)
                .chromeClickable(true) { open = !open }
                .semantics { contentDescription = "Help" },
            contentAlignment = Alignment.Center,
        ) {
            Text(
                "?",
                style = chromeStyle(10f, FontWeight.Bold),
                color = LiveDesign.muted,
            )
        }
        if (open) {
            androidx.compose.ui.window.Popup(onDismissRequest = { open = false }) {
                Box(
                    Modifier.widthIn(max = 280.dp)
                        .glass(ChromeShape)
                        .padding(10.dp)
                ) {
                    Text(
                        text,
                        style = chromeStyle(11f, FontWeight.Normal),
                        color = LiveDesign.text,
                    )
                }
            }
        }
    }
}

/**
 * iOS `SettingsSegmented`: a full-width pill of equal segments — the popup's
 * single-select control, replacing free-scrolling choice chips.
 */
@Composable
private fun <T> SegmentedChoice(
    options: List<T>,
    label: (T) -> String,
    selected: (T) -> Boolean,
    onSelect: (T) -> Unit,
) {
    Row(
        Modifier.fillMaxWidth()
            .background(LiveDesign.background.copy(alpha = 0.38f), ChromeShape)
            .border(1.dp, LiveDesign.hairline, ChromeShape)
            .padding(3.dp)
            .selectableGroup(),
        horizontalArrangement = Arrangement.spacedBy(3.dp),
    ) {
        options.forEach { option ->
            val isSelected = selected(option)
            Box(
                Modifier.weight(1f)
                    .height(34.dp)
                    .background(
                        if (isSelected) LiveDesign.accentDim else androidx.compose.ui.graphics.Color.Transparent,
                        ChromeShape,
                    )
                    .selectable(selected = isSelected, role = Role.RadioButton) {
                        onSelect(option)
                    },
                contentAlignment = Alignment.Center,
            ) {
                Text(
                    label(option),
                    style = chromeStyle(11.5f, FontWeight.SemiBold),
                    color = if (isSelected) LiveDesign.accent else LiveDesign.muted,
                    maxLines = 1,
                )
            }
        }
    }
}

/** iOS `SettingsColorDots`: swatch circles with an accent selection ring. */
@Composable
private fun <T> ColorDotsRow(
    options: List<T>,
    label: (T) -> String,
    swatch: (T) -> androidx.compose.ui.graphics.Color,
    selected: (T) -> Boolean,
    onSelect: (T) -> Unit,
) {
    Row(
        Modifier.selectableGroup(),
        horizontalArrangement = Arrangement.spacedBy(10.dp),
    ) {
        options.forEach { option ->
            val isSelected = selected(option)
            Box(
                Modifier.height(26.dp)
                    .widthIn(min = 26.dp)
                    .border(
                        width = if (isSelected) 2.dp else 1.dp,
                        // iOS rings the selected dot with its own swatch color.
                        color = if (isSelected) swatch(option) else LiveDesign.hairlineStrong,
                        shape = androidx.compose.foundation.shape.CircleShape,
                    )
                    .padding(4.dp)
                    .background(swatch(option), androidx.compose.foundation.shape.CircleShape)
                    .selectable(selected = isSelected, role = Role.RadioButton) {
                        onSelect(option)
                    }
                    .semantics { contentDescription = label(option) },
            )
        }
    }
}

/**
 * iOS `ToggleRow` (framing popups): label left, a stroked circle right that
 * fills accent when on — distinct from the Material switch the analysis
 * popups use, mirroring the iOS split.
 */
@Composable
private fun CircleToggleRow(
    title: String,
    isOn: Boolean,
    divider: Boolean = true,
    onToggle: () -> Unit,
) {
    if (divider) AssistRowDivider()
    Row(
        Modifier.fillMaxWidth()
            .heightIn(min = 38.dp)
            .toggleable(value = isOn, role = Role.Switch, onValueChange = { onToggle() }),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(6.dp),
    ) {
        OptionLabel(title)
        Spacer(Modifier.weight(1f))
        Box(
            Modifier.size(24.dp)
                .border(
                    width = if (isOn) 0.dp else 1.5.dp,
                    color = LiveDesign.muted,
                    shape = androidx.compose.foundation.shape.CircleShape,
                )
                .padding(if (isOn) 0.dp else 4.dp)
                .background(
                    if (isOn) LiveDesign.accent else androidx.compose.ui.graphics.Color.Transparent,
                    androidx.compose.foundation.shape.CircleShape,
                ),
        )
    }
}

/** iOS `SettingsSwitchInlineRow`: hairline above, label + help left, switch right. */
@Composable
private fun SwitchInlineRow(
    title: String,
    isOn: Boolean,
    help: String? = null,
    divider: Boolean = true,
    onToggle: () -> Unit,
) {
    if (divider) AssistRowDivider()
    Row(
        Modifier.fillMaxWidth()
            .heightIn(min = 38.dp)
            .toggleable(value = isOn, role = Role.Switch, onValueChange = { onToggle() }),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(6.dp),
    ) {
        OptionLabel(title)
        help?.let { HelpBadge(it) }
        Spacer(Modifier.weight(1f))
        androidx.compose.material3.Switch(
            checked = isOn,
            onCheckedChange = null,
            colors =
                androidx.compose.material3.SwitchDefaults.colors(
                    checkedTrackColor = LiveDesign.accent,
                    checkedThumbColor = LiveDesign.background,
                ),
        )
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
