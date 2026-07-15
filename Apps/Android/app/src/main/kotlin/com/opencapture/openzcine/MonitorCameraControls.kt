package com.opencapture.openzcine

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
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
import androidx.compose.ui.draw.clipToBounds
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.disabled
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
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
): List<MonitorCaptureSettingPresentation> {
    val primary = dashboard.tiles.associateBy(CommandTilePresentation::kind)
    val focus = dashboard.sideSections.firstOrNull { it.title == "Focus" }?.cells.orEmpty()

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

    val focusModes =
        listOfNotNull(
            mode("AF Mode", focus.getOrNull(0)),
            mode("Area", focus.getOrNull(1)),
            mode("Subject", focus.getOrNull(2)),
        )
    val focusValue = focus.getOrNull(0)?.value ?: "—"
    return listOf(
        single(
            MonitorPickerKind.ISO,
            "ISO",
            "25600",
            "Sensitivity",
            primary[CommandTileKind.ISO],
        ),
        single(
            MonitorPickerKind.SHUTTER,
            "SHUTTER",
            "1/16000",
            "Angle / speed",
            primary[CommandTileKind.SHUTTER],
        ),
        single(
            MonitorPickerKind.IRIS,
            "IRIS",
            "f/2.8",
            "Aperture",
            primary[CommandTileKind.IRIS],
        ),
        MonitorCaptureSettingPresentation(
            kind = MonitorPickerKind.FOCUS,
            label = "FOCUS",
            value = focusValue,
            widestValue = "Wide-L",
            picker =
                focusModes.takeIf(List<MonitorPickerModePresentation>::isNotEmpty)?.let {
                    MonitorPickerPresentation(
                        MonitorPickerKind.FOCUS,
                        "FOCUS",
                        "AF mode / area / subject",
                        it,
                    )
                },
            unavailableReason = focus.getOrNull(0)?.unavailableReason,
        ),
        single(
            MonitorPickerKind.WHITE_BALANCE,
            "WB",
            "5600K",
            "Kelvin / preset",
            primary[CommandTileKind.WHITE_BALANCE],
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

/** DISP always cycles live, clean, command and clears any live-view picker. */
internal fun nextMonitorDispIndex(current: Int): Int = (current + 1).mod(3)

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
) {
    Row(
        modifier =
            modifier
                .glass(ChromeShape)
                .padding(horizontal = 12.dp, vertical = 4.dp),
        horizontalArrangement = Arrangement.spacedBy(8.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        settings.forEach { setting ->
            val active = activePicker == setting.kind
            val enabled = setting.picker != null && controlsEnabled && pendingControl == null
            val pending = setting.picker?.modes?.any { it.request.control == pendingControl } == true
            val summary =
                buildString {
                    append(setting.label)
                    append(": ")
                    append(setting.value)
                    when {
                        pending -> append(". Applying change.")
                        pendingControl != null -> append(". Another camera change is in progress.")
                        setting.picker == null ->
                            append(". ${setting.unavailableReason ?: "Read-only on this camera."}")
                        !controlsEnabled -> append(". Camera controls are locked.")
                        else -> append(". Double tap to change.")
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
                    contentDescription =
                        "${picker.title} camera control picker. ${picker.subtitle}."
                },
        verticalArrangement = Arrangement.spacedBy(8.dp),
    ) {
        Row(
            Modifier.fillMaxWidth(),
            horizontalArrangement = Arrangement.SpaceBetween,
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(2.dp)) {
                Text(
                    picker.title,
                    style = chromeStyle(18f, FontWeight.ExtraBold),
                    color = LiveDesign.text,
                    maxLines = 1,
                )
                Text(
                    picker.subtitle.uppercase(),
                    style = chromeStyle(10f, FontWeight.SemiBold, mono = true),
                    color = LiveDesign.faint,
                    maxLines = 1,
                    overflow = TextOverflow.Clip,
                )
            }
            TextButton(onClick = onDismiss, enabled = !pending) { Text("Close") }
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
                "Controls are unavailable until the camera is connected and unlocked.",
                style = chromeStyle(11f, FontWeight.Medium),
                color = LiveDesign.muted,
                maxLines = 2,
            )
        }

        Column(
            Modifier
                .fillMaxWidth()
                .weight(1f)
                .verticalScroll(rememberScrollState()),
            verticalArrangement = Arrangement.spacedBy(4.dp),
        ) {
            commandControlOptions(mode.request, pendingControl, controlsEnabled).forEach { option ->
                TextButton(
                    onClick = { onSelect(mode.request, option.label) },
                    enabled = option.enabled,
                    modifier =
                        Modifier
                            .fillMaxWidth()
                            .background(
                                if (option.selected) LiveDesign.accentDim else Color.Transparent,
                                ChromeShape,
                            )
                            .border(
                                1.dp,
                                if (option.selected) LiveDesign.accent else LiveDesign.hairline,
                                ChromeShape,
                            )
                            .semantics {
                                contentDescription =
                                    "${mode.label} ${option.label}" +
                                        if (option.selected) ", currently selected" else ""
                            },
                ) {
                    Text(
                        option.label,
                        style = chromeStyle(15f, FontWeight.Medium, mono = true),
                        color = if (option.selected) LiveDesign.accent else LiveDesign.text,
                    )
                }
            }
            if (pendingControl == mode.request.control) {
                Text(
                    "Applying change…",
                    style = chromeStyle(11f, FontWeight.Medium),
                    color = LiveDesign.muted,
                )
            }
        }
    }
}
