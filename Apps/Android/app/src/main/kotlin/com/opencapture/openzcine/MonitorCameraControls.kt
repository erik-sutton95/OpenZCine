package com.opencapture.openzcine

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.foundation.layout.offset
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.lazy.items
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.ui.draw.drawWithContent
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.BlendMode
import androidx.compose.ui.graphics.CompositingStrategy
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.unit.sp
import com.opencapture.openzcine.settings.PanelCloseButton
import androidx.compose.ui.draw.clipToBounds
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.disabled
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import com.opencapture.openzcine.bridge.MonitorZones
import com.opencapture.openzcine.bridge.ZoneFrame
import com.opencapture.openzcine.core.CameraControl
import com.opencapture.openzcine.settings.PortraitFeedAspect
import kotlin.math.max
import kotlin.math.min

/** Stable identities for the five camera controls surrounding iOS live view. */
internal enum class MonitorPickerKind {
    ISO,
    SHUTTER,
    IRIS,
    FOCUS,
    WHITE_BALANCE,
    RESOLUTION,
    CODEC,
}

/** One typed control tab inside an in-monitor picker. */
internal data class MonitorPickerModePresentation(
    val label: String,
    val request: CommandControlRequest,
)

/** Camera-backed picker shown over live view. */
internal data class MonitorPickerPresentation(
    val kind: MonitorPickerKind,
    val title: String,
    val subtitle: String,
    val modes: List<MonitorPickerModePresentation>,
)

/** One readout in the live monitor's capture strip. */
internal data class MonitorCaptureSettingPresentation(
    val kind: MonitorPickerKind,
    val label: String,
    val value: String,
    val widestValue: String,
    val picker: MonitorPickerPresentation?,
    val unavailableReason: String?,
)

/**
 * Pickers behind the landscape top-pill resolution/codec readouts (and the
 * portrait REC-options popover). Mirrors iOS: always present so a tap opens
 * the drum; options prefer the command projection (camera-advertised when the
 * body has reported them, otherwise the same static fallbacks iOS uses).
 */
internal fun monitorTopPillPickers(
    dashboard: CommandDashboardPresentation,
    strings: PhoneStringResolver,
): Map<MonitorPickerKind, MonitorPickerPresentation> {
    val primary = dashboard.tiles.associateBy(CommandTilePresentation::kind)
    fun from(
        kind: MonitorPickerKind,
        tileKind: CommandTileKind,
        control: CameraControl,
        subtitle: Int,
        fallbacks: List<String>,
    ): Pair<MonitorPickerKind, MonitorPickerPresentation>? {
        val tile = primary[tileKind]
        val cameraRequest = tile?.request?.takeIf { it.options.isNotEmpty() }
        val options = cameraRequest?.options?.ifEmpty { null } ?: fallbacks
        val current =
            cameraRequest?.currentValue
                ?: tile?.value?.takeIf { it != "—" }
                ?: options.firstOrNull()
                ?: return null
        val request =
            cameraRequest
                ?: CommandControlRequest(
                    title = tile?.title ?: strings.resolve(subtitle),
                    control = control,
                    currentValue = current,
                    options = options,
                )
        val title = tile?.title ?: request.title
        return kind to
            MonitorPickerPresentation(
                kind = kind,
                title = title,
                subtitle = strings.resolve(subtitle),
                modes = listOf(MonitorPickerModePresentation(title, request)),
            )
    }
    return listOfNotNull(
        from(
            MonitorPickerKind.RESOLUTION,
            CommandTileKind.RESOLUTION_FRAMERATE,
            CameraControl.RESOLUTION_FRAMERATE,
            R.string.camera_subtitle_resolution,
            IOS_RESOLUTION_PICKER_FALLBACKS,
        ),
        from(
            MonitorPickerKind.CODEC,
            CommandTileKind.CODEC,
            CameraControl.CODEC,
            R.string.camera_subtitle_codec,
            IOS_CODEC_PICKER_FALLBACKS,
        ),
    ).toMap()
}

/** The shared-zone anchor used by an in-monitor control panel. */
internal enum class MonitorPickerAnchor {
    CAPTURE_STRIP,
    CONTROLS_GRID,
}

/**
 * Projects the same typed command presentation used by DISP 3 into the five
 * controls surrounding live view.
 *
 * No option is invented here. A readout becomes actionable only when the
 * existing command projection already produced a Swift-validated
 * [CommandControlRequest]. Resolution, codec, and other descriptor-dependent
 * controls consequently stay read-only rather than gaining guessed choices.
 */
internal fun monitorCaptureSettings(
    dashboard: CommandDashboardPresentation,
    strings: PhoneStringResolver,
): List<MonitorCaptureSettingPresentation> {
    val primary = dashboard.tiles.associateBy(CommandTilePresentation::kind)
    val focus =
        dashboard.sideSections.firstOrNull { it.kind == CommandSideSectionKind.FOCUS }?.cells.orEmpty()
    val exposure =
        dashboard.sideSections.firstOrNull { it.kind == CommandSideSectionKind.EXPOSURE }?.cells.orEmpty()

    fun mode(label: String, tile: CommandTilePresentation?): MonitorPickerModePresentation? =
        tile?.request
            ?.takeIf { it.options.isNotEmpty() }
            ?.let { MonitorPickerModePresentation(label, it) }

    fun single(
        kind: MonitorPickerKind,
        label: String,
        widestValue: String,
        subtitle: String,
        tile: CommandTilePresentation?,
    ): MonitorCaptureSettingPresentation {
        val modes = listOfNotNull(mode(label, tile))
        return MonitorCaptureSettingPresentation(
            kind = kind,
            label = label,
            value = tile?.value ?: "—",
            widestValue = widestValue,
            picker =
                modes.takeIf(List<MonitorPickerModePresentation>::isNotEmpty)?.let {
                    MonitorPickerPresentation(kind, label, subtitle, it)
                },
            unavailableReason = tile?.unavailableReason,
        )
    }

    fun multi(
        kind: MonitorPickerKind,
        label: String,
        widestValue: String,
        subtitle: String,
        valueTile: CommandTilePresentation?,
        modes: List<MonitorPickerModePresentation>,
    ): MonitorCaptureSettingPresentation =
        MonitorCaptureSettingPresentation(
            kind = kind,
            label = label,
            value = valueTile?.value ?: "—",
            widestValue = widestValue,
            picker =
                modes.takeIf(List<MonitorPickerModePresentation>::isNotEmpty)?.let {
                    MonitorPickerPresentation(kind, label, subtitle, it)
                },
            unavailableReason = valueTile?.unavailableReason,
        )

    val focusModes =
        listOfNotNull(
            mode(strings.resolve(R.string.camera_mode_af), focus.getOrNull(0)),
            mode(strings.resolve(R.string.camera_mode_area), focus.getOrNull(1)),
            mode(strings.resolve(R.string.camera_mode_subject), focus.getOrNull(2)),
        )
    val focusValue = focus.getOrNull(0)?.value ?: "—"
    return listOf(
        multi(
            kind = MonitorPickerKind.ISO,
            label = strings.resolve(R.string.camera_label_iso),
            widestValue = "25600",
            subtitle = strings.resolve(R.string.camera_subtitle_iso),
            valueTile = primary[CommandTileKind.ISO],
            modes =
                listOfNotNull(
                    mode(strings.resolve(R.string.camera_mode_sensitivity), primary[CommandTileKind.ISO]),
                    mode(strings.resolve(R.string.camera_mode_base_iso), exposure.getOrNull(0)),
                ),
        ),
        multi(
            kind = MonitorPickerKind.SHUTTER,
            label = strings.resolve(R.string.camera_label_shutter),
            widestValue = "1/16000",
            subtitle = strings.resolve(R.string.camera_subtitle_shutter),
            valueTile = primary[CommandTileKind.SHUTTER],
            modes =
                listOfNotNull(
                    mode(strings.resolve(R.string.camera_mode_value), primary[CommandTileKind.SHUTTER]),
                    mode(strings.resolve(R.string.camera_mode_mode), exposure.getOrNull(1)),
                    mode(strings.resolve(R.string.camera_mode_lock), exposure.getOrNull(2)),
                ),
        ),
        single(
            MonitorPickerKind.IRIS,
            strings.resolve(R.string.camera_label_iris),
            "f/2.8",
            strings.resolve(R.string.camera_subtitle_iris),
            primary[CommandTileKind.IRIS],
        ),
        MonitorCaptureSettingPresentation(
            kind = MonitorPickerKind.FOCUS,
            label = strings.resolve(R.string.camera_label_focus),
            value = focusValue,
            widestValue = "Wide-L",
            picker =
                focusModes.takeIf(List<MonitorPickerModePresentation>::isNotEmpty)?.let {
                    MonitorPickerPresentation(
                        MonitorPickerKind.FOCUS,
                        strings.resolve(R.string.camera_label_focus),
                        strings.resolve(R.string.camera_subtitle_focus),
                        it,
                    )
                },
            unavailableReason = focus.getOrNull(0)?.unavailableReason,
        ),
        multi(
            kind = MonitorPickerKind.WHITE_BALANCE,
            label = strings.resolve(R.string.camera_label_wb),
            widestValue = "5600K",
            subtitle = strings.resolve(R.string.camera_subtitle_wb),
            valueTile = primary[CommandTileKind.WHITE_BALANCE],
            modes =
                listOfNotNull(
                    mode(strings.resolve(R.string.camera_mode_kelvin_preset), primary[CommandTileKind.WHITE_BALANCE]),
                    mode(strings.resolve(R.string.camera_mode_tint), exposure.getOrNull(3)),
                ),
        ),
    )
}

/** Returns the next picker state for a capture-cell tap. */
internal fun nextMonitorPicker(
    current: MonitorPickerKind?,
    requested: MonitorPickerKind,
    controlsEnabled: Boolean,
): MonitorPickerKind? =
    when {
        !controlsEnabled -> current
        current == requested -> null
        else -> requested
    }

/** Finds the live-view picker that already owns a typed command request. */
internal fun monitorPickerKindForRequest(
    settings: List<MonitorCaptureSettingPresentation>,
    request: CommandControlRequest,
): MonitorPickerKind? =
    settings.firstOrNull { setting ->
        setting.picker?.modes?.any { it.request.control == request.control } == true
    }?.kind

/** Resolves iOS's pinch thresholds without changing state for a small gesture. */
internal fun portraitAspectAfterPinch(
    zoom: Float,
    current: PortraitFeedAspect,
): PortraitFeedAspect? {
    val next =
        when {
            zoom > 1.15f -> PortraitFeedAspect.FILL
            zoom < 0.87f -> PortraitFeedAspect.FIT_16_9
            else -> null
        }
    return next?.takeIf { it != current }
}

/**
 * Seats the picker against frames supplied by the shared Swift zone map.
 * Only popup width/height limits are local; no feed, safe-area, scope, or
 * capture-strip geometry is re-derived in Compose.
 */
internal fun monitorPickerFrame(
    viewport: ZoneFrame,
    zones: MonitorZones,
    isPortrait: Boolean,
    anchor: MonitorPickerAnchor,
): ZoneFrame {
    val outerMargin = if (isPortrait) 12f else 8f
    val topLimit =
        max(
            viewport.y + outerMargin,
            zones.infoBar.y + zones.infoBar.height + if (isPortrait) 8f else 4f,
        )
    val anchorFrame =
        when (anchor) {
            MonitorPickerAnchor.CAPTURE_STRIP -> zones.captureStrip
            MonitorPickerAnchor.CONTROLS_GRID -> zones.controlsGrid
        }
    val bottomLimit =
        when {
            anchor == MonitorPickerAnchor.CAPTURE_STRIP && anchorFrame != null ->
                anchorFrame.y - 10f
            isPortrait -> zones.systemCluster.y - 10f
            else -> zones.feed.y + zones.feed.height - 10f
        }
    val availableHeight = max(0f, bottomLimit - topLimit)
    val height = min(if (isPortrait) 320f else 300f, availableHeight)
    val width =
        if (isPortrait) {
            max(0f, viewport.width - outerMargin * 2f)
        } else {
            min(420f, max(0f, anchorFrame?.width ?: zones.feed.width))
        }
    val horizontalBounds = if (isPortrait) viewport else zones.feed
    val rawX =
        if (isPortrait) {
            viewport.x + outerMargin
        } else {
            min(
                (anchorFrame ?: zones.feed).let { it.x + it.width },
                horizontalBounds.x + horizontalBounds.width - outerMargin,
            ) - width
        }
    val minX = horizontalBounds.x + outerMargin
    val maxX =
        max(
            minX,
            horizontalBounds.x + horizontalBounds.width - width - outerMargin,
        )
    return ZoneFrame(
        x = rawX.coerceIn(minX, maxX),
        y = max(topLimit, bottomLimit - height),
        width = width,
        height = height,
    )
}

/**
 * Seats iOS's portrait-fill assist rail inside the shared feed frame and
 * above the shared capture-strip frame.
 */
internal fun portraitFillAssistRailFrame(
    feed: ZoneFrame,
    captureStrip: ZoneFrame?,
    expanded: Boolean,
): ZoneFrame {
    val edge = 10f
    val width = if (expanded) 60f else 44f
    val feedBottom = feed.y + feed.height
    val railBottom = captureStrip?.y?.coerceIn(feed.y, feedBottom) ?: feedBottom
    val top = feed.y + edge
    val height = if (expanded) max(0f, railBottom - top - edge) else 44f
    val y =
        if (expanded) {
            top
        } else {
            max(top, railBottom - height - edge)
        }
    return ZoneFrame(feed.x + edge, y, width, height)
}

/** The actionable ISO/shutter/iris/focus/WB strip shared by both orientations. */
@Composable
internal fun MonitorCaptureStrip(
    settings: List<MonitorCaptureSettingPresentation>,
    activePicker: MonitorPickerKind?,
    controlsEnabled: Boolean,
    pendingControl: CameraControl?,
    onOpenPicker: (MonitorPickerKind) -> Unit,
    modifier: Modifier = Modifier,
    maxContentWidth: Dp? = null,
) {
    val applyingState = stringResource(R.string.camera_state_applying)
    val otherChangeState = stringResource(R.string.camera_state_other_change)
    val readOnlyState = stringResource(R.string.camera_state_read_only)
    val lockedState = stringResource(R.string.camera_state_locked)
    val changeHint = stringResource(R.string.camera_state_change_hint)
    // The glass shell stays at the shared 58dp band (iOS
    // DesignTokens.controlHeight) so the two bottom bars always align; when a
    // width budget is given, only the CELLS scale down to fit — scaling the
    // whole pill shrank its height below the assist bar's.
    Box(
        modifier =
            modifier
                .height(LiveDesign.CONTROL_HEIGHT_DP.dp)
                .glass(ChromeShape)
                .padding(horizontal = 12.dp, vertical = 4.dp),
        contentAlignment = Alignment.CenterStart,
    ) {
        val cells: @Composable () -> Unit = {
            CaptureStripCells(
                settings = settings,
                activePicker = activePicker,
                controlsEnabled = controlsEnabled,
                pendingControl = pendingControl,
                onOpenPicker = onOpenPicker,
                applyingState = applyingState,
                otherChangeState = otherChangeState,
                readOnlyState = readOnlyState,
                lockedState = lockedState,
                changeHint = changeHint,
            )
        }
        if (maxContentWidth != null) {
            FitScale(maxContentWidth - 24.dp) { cells() }
        } else {
            cells()
        }
    }
}

@Composable
private fun CaptureStripCells(
    settings: List<MonitorCaptureSettingPresentation>,
    activePicker: MonitorPickerKind?,
    controlsEnabled: Boolean,
    pendingControl: CameraControl?,
    onOpenPicker: (MonitorPickerKind) -> Unit,
    applyingState: String,
    otherChangeState: String,
    readOnlyState: String,
    lockedState: String,
    changeHint: String,
) {
    Row(
        horizontalArrangement = Arrangement.spacedBy(8.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        settings.forEach { setting ->
            val active = activePicker == setting.kind
            val enabled = setting.picker != null && controlsEnabled && pendingControl == null
            val pending = setting.picker?.modes?.any { it.request.control == pendingControl } == true
            val valueDescription =
                stringResource(R.string.command_value_description, setting.label, setting.value)
            val unavailableDescription =
                stringResource(
                    R.string.command_read_only_description,
                    setting.unavailableReason ?: readOnlyState,
                )
            val summary =
                buildString {
                    append(valueDescription)
                    when {
                        pending -> append(applyingState)
                        pendingControl != null -> append(otherChangeState)
                        setting.picker == null -> append(unavailableDescription)
                        !controlsEnabled -> append(lockedState)
                        else -> append(changeHint)
                    }
                }
            Box(
                Modifier
                    .background(if (active) LiveDesign.accentDim else Color.Transparent, ChromeShape)
                    .border(
                        1.dp,
                        if (active) LiveDesign.accent else Color.Transparent,
                        ChromeShape,
                    )
                    .semantics(mergeDescendants = true) {
                        contentDescription = summary
                        if (!enabled) disabled()
                    }
                    .chromeClickable(enabled) { onOpenPicker(setting.kind) }
                    .alpha(if (setting.picker == null) 0.62f else 1f),
            ) {
                CaptureSettingCell(setting.label, setting.value, setting.widestValue)
            }
        }
    }
}

/** Anchored, non-modal camera-control picker that keeps DISP and monitor rails reachable. */
@Composable
internal fun MonitorControlPickerPanel(
    picker: MonitorPickerPresentation,
    frame: ZoneFrame,
    controlsEnabled: Boolean,
    pendingControl: CameraControl?,
    feedback: CommandControlFeedback?,
    onSelect: (CommandControlRequest, String) -> Unit,
    onDismiss: () -> Unit,
    modifier: Modifier = Modifier,
) {
    val pickerDescription =
        stringResource(R.string.camera_picker_description, picker.title, picker.subtitle)
    var selectedMode by remember(picker.kind) { mutableIntStateOf(0) }
    val modeIndex = selectedMode.coerceIn(0, picker.modes.lastIndex)
    val mode = picker.modes[modeIndex]
    val pending = pendingControl != null
    Column(
        modifier =
            modifier
                .zone(frame)
                .clipToBounds()
                .glass(ChromeShape)
                .border(1.dp, LiveDesign.hairlineStrong, ChromeShape)
                .padding(horizontal = 16.dp, vertical = 12.dp)
                .semantics {
                    contentDescription = pickerDescription
                },
        verticalArrangement = Arrangement.spacedBy(8.dp),
    ) {
        // iOS `PickerHeader`: kerned heavy name + mono uppercase subtitle,
        // baseline-aligned, then the circular glass close button.
        Row(
            Modifier.fillMaxWidth(),
            horizontalArrangement = Arrangement.spacedBy(12.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Row(
                Modifier.weight(1f),
                horizontalArrangement = Arrangement.spacedBy(12.dp),
                verticalAlignment = Alignment.Bottom,
            ) {
                Text(
                    picker.title,
                    style = chromeStyle(18f, FontWeight.ExtraBold).copy(letterSpacing = 2.sp),
                    color = LiveDesign.text,
                    maxLines = 1,
                )
                Text(
                    picker.subtitle.uppercase(),
                    style =
                        chromeStyle(11f, FontWeight.SemiBold, mono = true)
                            .copy(letterSpacing = 1.5.sp),
                    color = LiveDesign.faint,
                    maxLines = 1,
                    overflow = TextOverflow.Clip,
                    modifier = Modifier.padding(bottom = 2.dp),
                )
            }
            PanelCloseButton(onDismiss)
        }

        if (picker.modes.size > 1) {
            Row(
                Modifier.fillMaxWidth().horizontalScroll(rememberScrollState()),
                horizontalArrangement = Arrangement.spacedBy(5.dp),
            ) {
                picker.modes.forEachIndexed { index, candidate ->
                    val selected = index == modeIndex
                    TextButton(
                        onClick = { selectedMode = index },
                        enabled = !pending,
                        modifier =
                            Modifier
                                .background(
                                    if (selected) LiveDesign.accentDim else Color.Transparent,
                                    ChromeShape,
                                )
                                .border(
                                    1.dp,
                                    if (selected) LiveDesign.accent else LiveDesign.hairline,
                                    ChromeShape,
                                ),
                    ) {
                        Text(
                            candidate.label,
                            style = chromeStyle(11f, FontWeight.Bold, mono = true),
                            color = if (selected) LiveDesign.accent else LiveDesign.muted,
                        )
                    }
                }
            }
        }

        feedback?.let {
            Text(
                it.message,
                style = chromeStyle(11f, FontWeight.Medium),
                color = if (it.isError) LiveDesign.rec else LiveDesign.good,
                maxLines = 2,
                overflow = TextOverflow.Clip,
            )
        }
        if (!controlsEnabled) {
            Text(
                stringResource(R.string.camera_controls_unavailable),
                style = chromeStyle(11f, FontWeight.Medium),
                color = LiveDesign.muted,
                maxLines = 2,
            )
        }

        // iOS: WB "Tint" tab swaps the drum for `WhiteBalanceTintPad`.
        // Every other mode uses `AccentDrumWheel`.
        if (mode.request.control == CameraControl.WHITE_BALANCE_TINT) {
            // Dim when the body advertised no fine-tune options for the active
            // WB mode (iOS `whiteBalanceTintAvailable`); still show the pad.
            val tintAvailable = mode.request.options.isNotEmpty()
            WhiteBalanceTintPad(
                currentLabel = mode.request.currentValue.ifBlank { "Neutral" },
                available = tintAvailable,
                interactive = controlsEnabled && !pending && tintAvailable,
                onCommit = { label ->
                    if (label != mode.request.currentValue) onSelect(mode.request, label)
                },
                modifier = Modifier.fillMaxWidth().weight(1f),
            )
            if (pendingControl == mode.request.control) {
                Text(
                    stringResource(R.string.camera_applying_change),
                    style = chromeStyle(11f, FontWeight.Medium),
                    color = LiveDesign.muted,
                )
            }
        } else {
            // iOS `AccentDrumWheel`: the option set is a snapping vertical drum
            // that applies on settle, not a flat list of buttons.
            val options = commandControlOptions(mode.request, pendingControl, controlsEnabled)
            val selectedLabel =
                options.firstOrNull { it.selected }?.label
                    ?: options.firstOrNull()?.label
                    ?: ""
            val optionDescription =
                stringResource(R.string.camera_picker_options_description, mode.label)
            Column(
                Modifier.fillMaxWidth().weight(1f),
                verticalArrangement = Arrangement.spacedBy(4.dp),
            ) {
                AccentDrumWheel(
                    options = options.map { it.label },
                    selection = selectedLabel,
                    interactive = controlsEnabled && !pending,
                    modifier =
                        Modifier
                            .fillMaxWidth()
                            .weight(1f)
                            .semantics { contentDescription = optionDescription },
                    onSettle = { settled ->
                        if (settled != selectedLabel) onSelect(mode.request, settled)
                    },
                )
                if (pendingControl == mode.request.control) {
                    Text(
                        stringResource(R.string.camera_applying_change),
                        style = chromeStyle(11f, FontWeight.Medium),
                        color = LiveDesign.muted,
                    )
                }
            }
        }
    }
}

/**
 * iOS `AccentDrumWheel`: a snapping vertical drum — the centred row renders
 * large in accent between two hairlines, neighbours dim above/below behind a
 * top/bottom fade. Settling on a row calls [onSettle]; the whole wheel dims
 * and stops scrolling when not [interactive] (control lock).
 */
@Composable
internal fun AccentDrumWheel(
    options: List<String>,
    selection: String,
    onSettle: (String) -> Unit,
    modifier: Modifier = Modifier,
    interactive: Boolean = true,
    markedValues: Set<String> = emptySet(),
    wheelHeight: Dp = 176.dp,
    rowHeight: Dp = 52.dp,
) {
    if (options.isEmpty()) return
    val listState =
        androidx.compose.foundation.lazy.rememberLazyListState(
            initialFirstVisibleItemIndex = options.indexOf(selection).coerceAtLeast(0),
        )
    val fling = androidx.compose.foundation.gestures.snapping.rememberSnapFlingBehavior(listState)
    val centeredIndex by remember {
        androidx.compose.runtime.derivedStateOf {
            val layout = listState.layoutInfo
            val center = (layout.viewportStartOffset + layout.viewportEndOffset) / 2
            layout.visibleItemsInfo
                .minByOrNull { kotlin.math.abs(it.offset + it.size / 2 - center) }
                ?.index ?: 0
        }
    }
    // Apply the row the wheel settles on (iOS applies on drum settle).
    LaunchedEffect(listState, options) {
        androidx.compose.runtime.snapshotFlow { listState.isScrollInProgress to centeredIndex }
            .collect { (scrolling, index) ->
                if (!scrolling) options.getOrNull(index)?.let(onSettle)
            }
    }
    val edgePadding = (wheelHeight - rowHeight) / 2
    Box(
        modifier.height(wheelHeight).alpha(if (interactive) 1f else 0.55f),
        contentAlignment = Alignment.Center,
    ) {
        androidx.compose.foundation.lazy.LazyColumn(
            state = listState,
            flingBehavior = fling,
            userScrollEnabled = interactive,
            contentPadding = androidx.compose.foundation.layout.PaddingValues(vertical = edgePadding),
            modifier =
                Modifier.fillMaxWidth()
                    .graphicsLayer { compositingStrategy = CompositingStrategy.Offscreen }
                    .drawWithContent {
                        drawContent()
                        // Top/bottom fade so off-centre rows dissolve, iOS mask.
                        val fade = size.height * 0.22f
                        drawRect(
                            Brush.verticalGradient(
                                0f to Color.Transparent, 1f to Color.Black, endY = fade,
                            ),
                            size = Size(size.width, fade),
                            blendMode = BlendMode.DstIn,
                        )
                        drawRect(
                            Brush.verticalGradient(
                                0f to Color.Black, 1f to Color.Transparent,
                                startY = size.height - fade, endY = size.height,
                            ),
                            topLeft = Offset(0f, size.height - fade),
                            size = Size(size.width, fade),
                            blendMode = BlendMode.DstIn,
                        )
                    },
        ) {
            items(options.size) { index ->
                val option = options[index]
                val centered = index == centeredIndex
                Row(
                    Modifier.fillMaxWidth().height(rowHeight),
                    horizontalArrangement = Arrangement.Center,
                    verticalAlignment = Alignment.CenterVertically,
                ) {
                    Text(
                        option,
                        style =
                            chromeStyle(
                                if (centered) 30f else 23f,
                                if (centered) FontWeight.SemiBold else FontWeight.Normal,
                                mono = true,
                            ),
                        color = if (centered) LiveDesign.accent else LiveDesign.muted.copy(alpha = 0.7f),
                        maxLines = 1,
                    )
                    if (option in markedValues) {
                        Text(
                            " ★",
                            style = chromeStyle(if (centered) 13f else 10f, FontWeight.Bold),
                            color = if (centered) LiveDesign.accent else LiveDesign.muted.copy(alpha = 0.7f),
                        )
                    }
                }
            }
        }
        // Hairlines bracketing the settled row.
        Box(
            Modifier.fillMaxWidth().height(1.dp).offset(y = -rowHeight / 2)
                .background(LiveDesign.hairlineStrong),
        )
        Box(
            Modifier.fillMaxWidth().height(1.dp).offset(y = rowHeight / 2)
                .background(LiveDesign.hairlineStrong),
        )
    }
}
