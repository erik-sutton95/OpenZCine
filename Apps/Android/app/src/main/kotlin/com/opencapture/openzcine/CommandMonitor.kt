package com.opencapture.openzcine

import android.content.Context
import android.content.SharedPreferences
import android.os.SystemClock
import androidx.activity.compose.BackHandler
import androidx.compose.animation.core.animateDpAsState
import androidx.compose.foundation.ExperimentalFoundationApi
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.combinedClickable
import androidx.compose.foundation.gestures.detectDragGesturesAfterLongPress
import androidx.compose.foundation.gestures.detectTapGestures
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.offset
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.key
import androidx.compose.runtime.mutableLongStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberUpdatedState
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.clipToBounds
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.CustomAccessibilityAction
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.customActions
import androidx.compose.ui.semantics.disabled
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.IntOffset
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.compose.ui.zIndex
import com.opencapture.openzcine.core.CameraControl
import com.opencapture.openzcine.core.CameraPropertyRefreshFailure
import com.opencapture.openzcine.core.CameraPropertyRefreshStatus
import com.opencapture.openzcine.core.CameraPropertySnapshot
import com.opencapture.openzcine.core.CameraSessionState
import com.opencapture.openzcine.core.CameraShutterMode
import com.opencapture.openzcine.core.CameraTemperatureStatus
import com.opencapture.openzcine.core.LiveFrameTimecode
import com.opencapture.openzcine.settings.PanelCloseButton
import kotlin.math.floor
import kotlin.math.roundToInt

/** The stable, persisted tile identifiers used by the DISP 3 primary grid. */
internal enum class CommandTileKind {
    MODE,
    ISO,
    SHUTTER,
    IRIS,
    WHITE_BALANCE,
    RESOLUTION_FRAMERATE,
    CODEC,
    STABILIZATION,
    ;

    companion object {
        fun fromStoredName(value: String): CommandTileKind? =
            entries.firstOrNull { it.name == value }
    }
}

/** The app-private, user-configurable order for the command grid. */
internal class CommandTileOrderStore(private val preferences: SharedPreferences) {
    constructor(context: Context) : this(
        context.getSharedPreferences(STORE_NAME, Context.MODE_PRIVATE),
    )

    fun load(): List<CommandTileKind> =
        normalizeCommandTileOrder(
            preferences.getString(ORDER_KEY, null)
                ?.split(',')
                ?.mapNotNull(CommandTileKind::fromStoredName)
                .orEmpty(),
        )

    fun save(order: List<CommandTileKind>) {
        val normalized = normalizeCommandTileOrder(order)
        preferences.edit()
            .putString(ORDER_KEY, normalized.joinToString(separator = ",") { it.name })
            .apply()
    }

    private companion object {
        const val STORE_NAME = "openzcine.command-dashboard"
        const val ORDER_KEY = "display.commandGrid.order.v1"
    }
}

/** Removes malformed duplicates and retains newly introduced tiles at the end. */
internal fun normalizeCommandTileOrder(order: List<CommandTileKind>): List<CommandTileKind> {
    val unique = order.distinct()
    return unique + CommandTileKind.entries.filterNot(unique::contains)
}

/** Moves one tile to [targetIndex] while retaining a complete, valid order. */
internal fun moveCommandTile(
    order: List<CommandTileKind>,
    kind: CommandTileKind,
    targetIndex: Int,
): List<CommandTileKind> {
    val normalized = normalizeCommandTileOrder(order).toMutableList()
    val currentIndex = normalized.indexOf(kind)
    if (currentIndex < 0) return normalized
    normalized.removeAt(currentIndex)
    normalized.add(targetIndex.coerceIn(0, normalized.size), kind)
    return normalized
}

/** One semantically validated intent passed from the Compose sheet to the session control API. */
internal data class CommandControlRequest(
    val title: String,
    val control: CameraControl,
    val currentValue: String,
    val options: List<String>,
)

/** The user-visible outcome of an accepted or rejected control write. */
internal data class CommandControlFeedback(
    val message: String,
    val isError: Boolean,
)

/** One selectable row in the command-control dialog. */
internal data class CommandControlOptionPresentation(
    val label: String,
    val selected: Boolean,
    val enabled: Boolean,
)

/** Builds the picker rows without exposing protocol bytes to Compose. */
internal fun commandControlOptions(
    request: CommandControlRequest,
    pendingControl: CameraControl?,
    controlsEnabled: Boolean = true,
): List<CommandControlOptionPresentation> =
    request.options.map { label ->
        CommandControlOptionPresentation(
            label = label,
            selected = label == request.currentValue,
            // Do not disable rows while another write is in flight — the drum must
            // stay interactive; MonitorScreen coalesces rapid settles like iOS.
            // [pendingControl] is retained for callers/tests that still pass it.
            enabled = controlsEnabled,
        )
    }

/** One grid or side-column value, including its safe-to-write intent when supported. */
internal data class CommandTilePresentation(
    val kind: CommandTileKind? = null,
    val title: String,
    val value: String,
    val request: CommandControlRequest? = null,
    val unavailableReason: String? = null,
    /** Accent-tinted value (iOS `.cmd-stile.amber`) — Sens when manual, Atten when ON. */
    val amber: Boolean = false,
    /** Dimmed value (iOS `.cmd-stile.muted`) — Picture Profile placeholder. */
    val muted: Boolean = false,
)

/**
 * Sections of the iOS command side column (Image / Focus / Audio / Monitor).
 * [EXPOSURE] is retained only for capture-bar projection — it is not shown on DISP 3.
 */
internal enum class CommandSideSectionKind {
    IMAGE,
    EXPOSURE,
    FOCUS,
    AUDIO,
    MONITOR,
}

internal data class CommandSideSectionPresentation(
    val kind: CommandSideSectionKind,
    val title: String,
    val cells: List<CommandTilePresentation>,
)

/** All display data needed by the dashboard, projected from the typed session snapshot. */
internal data class CommandDashboardPresentation(
    val tiles: List<CommandTilePresentation>,
    /** Visible side column only — Image / Focus / Audio / Monitor (iOS CommandSideColumn). */
    val sideSections: List<CommandSideSectionPresentation>,
    /**
     * Capture-bar exposure helpers (Base ISO, Shutter Mode/Lock, WB Tint). Not rendered on
     * the DISP 3 side column (iOS removed that section from the command dashboard).
     */
    val captureExposureCells: List<CommandTilePresentation> = emptyList(),
    val temperature: String,
    val storage: String,
    val camera: String,
    val lens: String,
    val frameRate: String,
    val refreshSummary: String,
)

/**
 * iOS [CmdRow] packing: pairs of two, leftover single cell spans the full width
 * (prototype `.span2`). Focus/Audio rows are ordered to match iOS CommandSideColumn.
 */
internal fun commandSideSectionRows(
    section: CommandSideSectionPresentation,
): List<List<CommandTilePresentation>> {
    val cells = section.cells
    return when (section.kind) {
        CommandSideSectionKind.IMAGE ->
            // Tone | Picture Profile
            listOf(cells.take(2)).filter { it.isNotEmpty() }
        CommandSideSectionKind.FOCUS ->
            // Mode | Area, then Subject full-width
            buildList {
                if (cells.size >= 2) add(cells.take(2))
                else if (cells.isNotEmpty()) add(cells.take(1))
                if (cells.size >= 3) add(listOf(cells[2]))
            }
        CommandSideSectionKind.AUDIO ->
            // Sens | 32-bit Float ; Input | Wind ; Atten full-width
            // cells order: Sens, 32-bit, Input, Wind, Atten
            buildList {
                if (cells.size >= 2) add(cells.take(2))
                if (cells.size >= 4) add(cells.subList(2, 4))
                else if (cells.size == 3) add(listOf(cells[2]))
                if (cells.size >= 5) add(listOf(cells[4]))
            }
        CommandSideSectionKind.MONITOR ->
            // Grid full-width
            listOf(cells.take(1)).filter { it.isNotEmpty() }
        CommandSideSectionKind.EXPOSURE ->
            // Not shown on DISP 3; keep a safe chunking if ever rendered.
            cells.chunked(2)
    }
}

private const val COMMAND_GRID_COLUMNS = 3
private const val COMMAND_GRID_SPACING_DP = 9
private const val COMMAND_REORDER_CLICK_SUPPRESSION_MS = 150L
private const val COMMAND_PORTRAIT_GRID_ROW_HEIGHT_DP = 76
/** iOS CommandSmallTile minHeight — landscape and portrait side tiles. */
private val COMMAND_SIDE_TILE_MIN_HEIGHT = 42.dp
private val COMMAND_PORTRAIT_SIDE_TILE_HEIGHT = 44.dp

/** Returns the number of rows required for the dashboard's primary control grid. */
internal fun commandPrimaryGridRows(
    tileCount: Int,
    columns: Int = COMMAND_GRID_COLUMNS,
): Int {
    require(columns > 0) { "Command dashboard grid needs at least one column." }
    return (tileCount.coerceAtLeast(1) + columns - 1) / columns
}

/** Resolves one drag position to a clamped row-major command-grid slot. */
internal fun commandGridSlot(
    position: Offset,
    tileWidth: Float,
    rowHeight: Float,
    spacing: Float,
    columns: Int,
    itemCount: Int,
): Int {
    require(tileWidth > 0f && rowHeight > 0f) { "command grid cells must be positive" }
    require(spacing >= 0f && columns > 0 && itemCount > 0) {
        "command grid geometry must contain at least one item"
    }
    val column = floor(position.x / (tileWidth + spacing)).toInt().coerceIn(0, columns - 1)
    val row = floor(position.y / (rowHeight + spacing)).toInt().coerceAtLeast(0)
    return (row * columns + column).coerceIn(0, itemCount - 1)
}

/** Returns a tile only when a press lands inside its painted cell, never in a gutter. */
internal fun commandGridHitSlot(
    position: Offset,
    tileWidth: Float,
    rowHeight: Float,
    spacing: Float,
    columns: Int,
    itemCount: Int,
): Int? {
    require(tileWidth > 0f && rowHeight > 0f) { "command grid cells must be positive" }
    require(spacing >= 0f && columns > 0 && itemCount > 0) {
        "command grid geometry must contain at least one item"
    }
    if (position.x < 0f || position.y < 0f) return null
    val columnStride = tileWidth + spacing
    val rowStride = rowHeight + spacing
    val column = floor(position.x / columnStride).toInt()
    val row = floor(position.y / rowStride).toInt()
    if (column !in 0 until columns) return null
    if (position.x - column * columnStride >= tileWidth) return null
    if (position.y - row * rowStride >= rowHeight) return null
    return (row * columns + column).takeIf { it in 0 until itemCount }
}

/**
 * The compact portrait grid height, leaving a scrollable region for Image,
 * Focus, and Audio controls above the fixed monitor rail.
 */
internal fun portraitCommandGridHeightDp(tileCount: Int): Int {
    val rows = commandPrimaryGridRows(tileCount)
    return rows * COMMAND_PORTRAIT_GRID_ROW_HEIGHT_DP + (rows - 1) * COMMAND_GRID_SPACING_DP
}

/**
 * Projects the real Swift-core snapshot into the Android command dashboard.
 *
 * This is deliberately pure: it makes the UI's unavailable state, allowed
 * controls, and persisted ordering independently JVM-testable. It never falls
 * back to a demo value while a [CameraSessionState] is supplied.
 */
internal fun commandDashboardPresentation(
    snapshot: CameraPropertySnapshot,
    refreshStatus: CameraPropertyRefreshStatus,
    sessionState: CameraSessionState,
    tileOrder: List<CommandTileKind>,
    strings: PhoneStringResolver,
    recording: Boolean = false,
): CommandDashboardPresentation {
    val unavailable = commandPropertyUnavailableReason(sessionState, refreshStatus, strings)
    val codec = snapshot.codecSelection.monitorValueOrNull() ?: snapshot.codec.monitorValueOrNull()
    val frameRate = validMonitorFrameRate(snapshot.frameRate)
    val shutter =
        when (snapshot.shutterMode) {
            CameraShutterMode.ANGLE ->
                snapshot.shutterAngle.monitorValueOrNull()
                    ?: snapshot.shutterSpeed.monitorValueOrNull()
            CameraShutterMode.SPEED ->
                snapshot.shutterSpeed.monitorValueOrNull()
                    ?: snapshot.shutterAngle.monitorValueOrNull()
            null ->
                snapshot.shutterAngle.monitorValueOrNull()
                    ?: snapshot.shutterSpeed.monitorValueOrNull()
        }
    val whiteBalanceMode = snapshot.whiteBalanceMode.monitorValueOrNull()
    val whiteBalanceKelvin = snapshot.whiteBalanceKelvin?.takeIf { it > 0 }
    val whiteBalance =
        if (whiteBalanceMode == COLOR_TEMPERATURE_MODE) {
            whiteBalanceKelvin?.let { "${it}K" } ?: whiteBalanceMode
        } else {
            whiteBalanceMode ?: whiteBalanceKelvin?.let { "${it}K" }
        }
    val resolution =
        snapshot.resolutionFrameRate.monitorValueOrNull()
            ?: run {
                val rawPair =
                    listOfNotNull(
                            snapshot.resolution.monitorValueOrNull(),
                            frameRate?.let { "${it}p" },
                        )
                        .joinToString(separator = " · ")
                        .ifBlank { null }
                // Prefer compact `6K · 25p` so the drum seeds on a camera option, not
                // the raw `6048x3402 · 25p` string that never appears in the enum.
                rawPair?.let { compactRecordingModeFromRawDisplay(it) } ?: rawPair
            }
    val stabilization =
        listOfNotNull(
            snapshot.vibrationReduction.monitorValueOrNull(),
            snapshot.electronicVr.monitorValueOrNull(),
        )
            .distinct()
            .joinToString(separator = " / ")
            .ifBlank { null }
    // A take must never gain an ISO write through a missing or stale codec
    // readback. Only an explicitly non-R3D codec unlocks ISO mid-recording.
    val isoLockedDuringRecording =
        recording && codec?.contains("R3D", ignoreCase = true) != false
    val isoLockReason =
        if (codec == null) {
            strings.resolve(R.string.command_iso_recording_wait)
        } else {
            strings.resolve(R.string.command_iso_recording_locked)
        }
    val capabilities = snapshot.controlCapabilities
    val isoCapabilityReason =
        when {
            recording && isoLockedDuringRecording -> isoLockReason
            codec == null -> strings.resolve(R.string.command_iso_wait_codec)
            codec.contains("R3D", ignoreCase = true) && snapshot.baseIso == null ->
                strings.resolve(R.string.command_iso_wait_base)
            else -> strings.resolve(R.string.command_iso_no_values)
        }
    // Prefer camera-advertised active-circuit values; the capture-bar Angle/Speed
    // ladders still open when the descriptor is late (shared-core encode path).
    val shutterOptions = capabilities.options(CameraControl.SHUTTER)
    val shutterWritable =
        snapshot.shutterLocked != true && !shutter.isNullOrBlank()
    val shutterLockReason =
        when {
            snapshot.shutterLocked == true -> strings.resolve(R.string.command_shutter_locked)
            snapshot.shutterLocked == null && shutterOptions.isEmpty() ->
                strings.resolve(R.string.command_shutter_wait_lock)
            snapshot.shutterMode == null && shutterOptions.isEmpty() ->
                strings.resolve(R.string.command_shutter_wait_mode)
            else -> strings.resolve(R.string.command_shutter_unavailable)
        }

    fun editable(
        kind: CommandTileKind?,
        title: String,
        value: String?,
        control: CameraControl,
        options: List<String>,
        writable: Boolean = true,
        blockedReason: String = strings.resolve(R.string.command_control_locked),
    ): CommandTilePresentation {
        val currentValue = value.monitorValueOrNull()
        return if (currentValue == null) {
            CommandTilePresentation(kind, title, "—", unavailableReason = unavailable)
        } else if (!writable) {
            CommandTilePresentation(kind, title, currentValue, unavailableReason = blockedReason)
        } else {
            CommandTilePresentation(
                kind = kind,
                title = title,
                value = currentValue,
                request = CommandControlRequest(title, control, currentValue, options),
            )
        }
    }

    /**
     * Resolution / codec drums use **only camera-advertised options**. Static iOS-style
     * ladders are display-only previews and must not be offered for apply — writing a
     * fallback label always fails with "not supported" (no packed raw in the catalog).
     *
     * Current selection is matched onto the option list (raw `6048x3402 · 25p` →
     * `6K · 25p`, crop prefixes stripped) so the drum does not default to the first
     * row (often `6K · 24p`) while the body is on a different mode.
     */
    fun recordingModeEditable(
        kind: CommandTileKind,
        title: String,
        value: String?,
        control: CameraControl,
        fallbacks: List<String>,
        blockedReason: String,
    ): CommandTilePresentation {
        val cameraOptions = capabilities.options(control)
        val displayValue = value.monitorValueOrNull()
        // Prefer real descriptor options; never write-path-fallback to static ladders.
        val options = cameraOptions
        if (options.isEmpty()) {
            // Keep the readout visible; leave the control non-writable until Swift
            // publishes MovScreenSize / MovFileType enums.
            return if (displayValue == null) {
                CommandTilePresentation(kind, title, "—", unavailableReason = unavailable)
            } else {
                CommandTilePresentation(
                    kind = kind,
                    title = title,
                    value = displayValue,
                    unavailableReason = blockedReason,
                )
            }
        }
        val currentValue =
            matchRecordingModeOption(displayValue, options)
                ?: options.firstOrNull()
                ?: return CommandTilePresentation(kind, title, "—", unavailableReason = unavailable)
        return CommandTilePresentation(
            kind = kind,
            title = title,
            value = displayValue ?: currentValue,
            request = CommandControlRequest(title, control, currentValue, options),
        )
    }

    fun readOnly(
        kind: CommandTileKind? = null,
        title: String,
        value: String?,
        reason: String,
    ): CommandTilePresentation {
        val currentValue = value.monitorValueOrNull()
        return CommandTilePresentation(
            kind = kind,
            title = title,
            value = currentValue ?: "—",
            unavailableReason = if (currentValue == null) unavailable else reason,
        )
    }

    fun advertisedEditable(
        kind: CommandTileKind? = null,
        title: String,
        value: String?,
        control: CameraControl,
        blockedReason: String,
        writable: Boolean = true,
    ): CommandTilePresentation {
        val options = capabilities.options(control)
        return if (options.isEmpty()) {
            readOnly(kind, title, value, blockedReason)
        } else {
            editable(
                kind = kind,
                title = title,
                value = value,
                control = control,
                options = options,
                writable = writable,
                blockedReason = blockedReason,
            )
        }
    }

    val tilesByKind =
        mapOf(
            CommandTileKind.MODE to
                editable(
                    CommandTileKind.MODE,
                    strings.resolve(R.string.command_title_mode),
                    snapshot.exposureMode,
                    CameraControl.EXPOSURE_MODE,
                    EXPOSURE_MODE_OPTIONS,
                ),
            CommandTileKind.ISO to
                run {
                    val isoValue = snapshot.iso?.takeIf { it > 0 }?.toString()
                    val cameraIso = capabilities.options(CameraControl.ISO)
                    // Capture bar always uses IsoPickerPolicy ladders; keep the command
                    // tile writable with the same union when the body has not yet named
                    // a dual-base circuit (otherwise ISO padlocks with "wait for base").
                    val isoOptions =
                        cameraIso.ifEmpty {
                            when {
                                codec == null -> emptyList()
                                IsoPickerPolicy.showsDualBaseCircuits(codec) ->
                                    IsoPickerPolicy.unifiedOptions
                                else -> IsoPickerPolicy.unifiedOptions
                            }
                        }
                    editable(
                        kind = CommandTileKind.ISO,
                        title = strings.resolve(R.string.command_title_iso),
                        value = isoValue,
                        control = CameraControl.ISO,
                        options = isoOptions,
                        writable = !isoLockedDuringRecording && isoOptions.isNotEmpty(),
                        blockedReason = isoCapabilityReason,
                    )
                },
            CommandTileKind.SHUTTER to
                editable(
                    kind = CommandTileKind.SHUTTER,
                    title = strings.resolve(R.string.command_title_shutter),
                    value = shutter,
                    control = CameraControl.SHUTTER,
                    // Capture-bar / shared-core encode use Angle+Speed ladders when the
                    // body has not advertised the active circuit yet.
                    options =
                        shutterOptions.ifEmpty {
                            ShutterPickerPolicy.angleOptions + ShutterPickerPolicy.speedOptions
                        },
                    writable = shutterWritable,
                    blockedReason = shutterLockReason,
                ),
            CommandTileKind.IRIS to
                run {
                    val cameraIris = capabilities.options(CameraControl.IRIS)
                    // Match iOS: when the body omits an f-number enum, still offer the
                    // shared-core / lens ladder so IRIS is not permanently grayed out.
                    val irisOptions =
                        cameraIris.ifEmpty {
                            IrisPickerPolicy.options(forLensDescriptor = snapshot.lens)
                        }
                    editable(
                        kind = CommandTileKind.IRIS,
                        title = strings.resolve(R.string.command_title_iris),
                        value = snapshot.iris,
                        control = CameraControl.IRIS,
                        options = irisOptions,
                        writable = irisOptions.isNotEmpty(),
                        blockedReason = strings.resolve(R.string.command_reason_aperture),
                    )
                },
            CommandTileKind.WHITE_BALANCE to
                advertisedEditable(
                    kind = CommandTileKind.WHITE_BALANCE,
                    title = strings.resolve(R.string.command_title_white_balance),
                    value = whiteBalance,
                    control = CameraControl.WHITE_BALANCE,
                    blockedReason = strings.resolve(R.string.command_reason_white_balance),
                ),
            CommandTileKind.RESOLUTION_FRAMERATE to
                recordingModeEditable(
                    kind = CommandTileKind.RESOLUTION_FRAMERATE,
                    title = strings.resolve(R.string.command_title_resolution),
                    value = resolution,
                    control = CameraControl.RESOLUTION_FRAMERATE,
                    fallbacks = IOS_RESOLUTION_PICKER_FALLBACKS,
                    blockedReason = strings.resolve(R.string.command_reason_recording_modes),
                ),
            CommandTileKind.CODEC to
                recordingModeEditable(
                    kind = CommandTileKind.CODEC,
                    title = strings.resolve(R.string.command_title_codec),
                    value = codec,
                    control = CameraControl.CODEC,
                    fallbacks = IOS_CODEC_PICKER_FALLBACKS,
                    blockedReason = strings.resolve(R.string.command_reason_codec_modes),
                ),
            CommandTileKind.STABILIZATION to
                advertisedEditable(
                    kind = CommandTileKind.STABILIZATION,
                    title = strings.resolve(R.string.command_title_vr),
                    value = snapshot.vibrationReduction,
                    control = CameraControl.VIBRATION_REDUCTION,
                    blockedReason = strings.resolve(R.string.command_reason_movie_vr),
                ).copy(
                    title = strings.resolve(R.string.command_title_vr_combined),
                    value = stabilization ?: "—",
                ),
        )
    val focusCells =
        listOf(
            advertisedEditable(
                title = strings.resolve(R.string.command_title_mode),
                value = snapshot.focusMode,
                control = CameraControl.FOCUS_MODE,
                blockedReason = strings.resolve(R.string.command_reason_focus_modes),
            ),
            advertisedEditable(
                title = strings.resolve(R.string.command_title_area),
                value = snapshot.focusArea,
                control = CameraControl.FOCUS_AREA,
                blockedReason = strings.resolve(R.string.command_reason_focus_areas),
            ),
            advertisedEditable(
                title = strings.resolve(R.string.command_title_subject),
                value = snapshot.focusSubject,
                control = CameraControl.FOCUS_SUBJECT,
                blockedReason = strings.resolve(R.string.command_reason_focus_subjects),
            ),
        )
    // iOS commandMicrophoneUsesManualLevel — amber when Sens is not Auto.
    val audioSensRaw =
        snapshot.audioSensitivity.monitorValueOrNull()
            ?: snapshot.microphoneSensitivity.monitorValueOrNull()
    val audioSensManual = audioSensRaw != null && !audioSensRaw.equals("Auto", ignoreCase = true)
    val audioSensitivityCell =
        if (snapshot.audioSensitivity.monitorValueOrNull() != null) {
            advertisedEditable(
                title = strings.resolve(R.string.command_title_sensitivity_short),
                value = snapshot.audioSensitivity,
                control = CameraControl.AUDIO_SENSITIVITY,
                blockedReason = strings.resolve(R.string.command_reason_audio_sensitivity),
            ).copy(amber = audioSensManual)
        } else {
            readOnly(
                title = strings.resolve(R.string.command_title_sensitivity_short),
                value = snapshot.microphoneSensitivity,
                reason = strings.resolve(R.string.command_reason_microphone_read_only),
            ).copy(amber = audioSensManual)
        }
    // iOS commandMicrophoneInputLabel: Microphone → MIC, Line → LINE (display only).
    val audioInputDisplay =
        when (snapshot.audioInput.monitorValueOrNull()) {
            "Line" -> "LINE"
            "Microphone" -> "MIC"
            else -> snapshot.audioInput
        }
    val audioInputCell =
        advertisedEditable(
            title = strings.resolve(R.string.command_title_input),
            value = snapshot.audioInput,
            control = CameraControl.AUDIO_INPUT,
            blockedReason = strings.resolve(R.string.command_reason_audio_input),
        ).let { cell ->
            val display = audioInputDisplay.monitorValueOrNull()
            if (display != null && display != cell.value) cell.copy(value = display) else cell
        }
    val attenuatorOn =
        snapshot.inputAttenuator.monitorValueOrNull()?.equals("ON", ignoreCase = true) == true
    // iOS CommandSideColumn Audio order: Sens | 32-bit Float ; Input | Wind ; Atten
    val audioCells =
        listOf(
            audioSensitivityCell,
            advertisedEditable(
                title = strings.resolve(R.string.command_title_32_bit_float),
                value = snapshot.audio32BitFloat,
                control = CameraControl.AUDIO_32_BIT_FLOAT,
                blockedReason = strings.resolve(R.string.command_reason_32_bit_float),
            ),
            audioInputCell,
            advertisedEditable(
                title = strings.resolve(R.string.command_title_wind),
                value = snapshot.windFilter,
                control = CameraControl.WIND_FILTER,
                blockedReason = strings.resolve(R.string.command_reason_wind_filter),
            ),
            advertisedEditable(
                title = strings.resolve(R.string.command_title_attenuator),
                value = snapshot.inputAttenuator,
                control = CameraControl.ATTENUATOR,
                blockedReason = strings.resolve(R.string.command_reason_attenuator),
            ).copy(amber = attenuatorOn),
        )

    // Capture-bar only — iOS does not show these on the command side column.
    val captureExposureCells =
        listOf(
            advertisedEditable(
                title = strings.resolve(R.string.command_title_base_iso),
                value = snapshot.baseIso,
                control = CameraControl.BASE_ISO,
                blockedReason = strings.resolve(R.string.command_reason_base_iso),
            ),
            advertisedEditable(
                title = strings.resolve(R.string.command_title_shutter_mode),
                value =
                    when (snapshot.shutterMode) {
                        CameraShutterMode.ANGLE -> "Angle"
                        CameraShutterMode.SPEED -> "Speed"
                        null -> null
                    },
                control = CameraControl.SHUTTER_MODE,
                blockedReason = strings.resolve(R.string.command_reason_shutter_modes),
            ),
            advertisedEditable(
                title = strings.resolve(R.string.command_title_shutter_lock),
                value = snapshot.shutterLocked?.let { if (it) "Locked" else "Unlocked" },
                control = CameraControl.SHUTTER_LOCK,
                blockedReason = strings.resolve(R.string.command_reason_shutter_lock),
            ),
            advertisedEditable(
                title = strings.resolve(R.string.command_title_wb_tint),
                value = snapshot.whiteBalanceTint,
                control = CameraControl.WHITE_BALANCE_TINT,
                blockedReason = strings.resolve(R.string.command_reason_wb_tint),
            ),
        )

    val camera =
        (sessionState as? CameraSessionState.Connected)
            ?.identity
            ?.let { identity ->
                identity.name.takeIf(String::isNotBlank)
                    ?.trim()
                    ?: identity.model.monitorValueOrNull()
            }
            ?: "—"
    return CommandDashboardPresentation(
        tiles = normalizeCommandTileOrder(tileOrder).mapNotNull(tilesByKind::get),
        // iOS CommandSideColumn: Image → Focus → Audio → Monitor (no Exposure / VR side tiles).
        sideSections =
            listOf(
                CommandSideSectionPresentation(
                    kind = CommandSideSectionKind.IMAGE,
                    title = strings.resolve(R.string.command_section_image),
                    cells =
                        listOf(
                            readOnly(
                                title = strings.resolve(R.string.command_title_tone),
                                value = snapshot.tone,
                                reason = strings.resolve(R.string.command_reason_tone),
                            ),
                            // iOS Picture Profile placeholder (muted, no camera write path).
                            CommandTilePresentation(
                                title = strings.resolve(R.string.command_title_picture_profile),
                                value = "—",
                                unavailableReason =
                                    strings.resolve(R.string.command_reason_picture_profile),
                                muted = true,
                            ),
                        ),
                ),
                CommandSideSectionPresentation(
                    CommandSideSectionKind.FOCUS,
                    strings.resolve(R.string.command_section_focus),
                    focusCells,
                ),
                CommandSideSectionPresentation(
                    CommandSideSectionKind.AUDIO,
                    strings.resolve(R.string.command_section_audio),
                    audioCells,
                ),
                CommandSideSectionPresentation(
                    kind = CommandSideSectionKind.MONITOR,
                    title = strings.resolve(R.string.command_section_monitor),
                    cells =
                        listOf(
                            readOnly(
                                title = strings.resolve(R.string.command_title_grid),
                                value = snapshot.cameraGrid,
                                reason = strings.resolve(R.string.command_reason_grid_read_only),
                            ),
                        ),
                ),
            ),
        captureExposureCells = captureExposureCells,
        temperature = commandTemperature(snapshot.temperatureStatus, strings),
        storage = monitorStorageLabel(snapshot.storage),
        camera = camera,
        lens = snapshot.lens.monitorValueOrNull() ?: "—",
        frameRate = monitorFrameRateLabel(frameRate),
        refreshSummary = commandRefreshSummary(refreshStatus, strings),
    )
}

private fun commandPropertyUnavailableReason(
    sessionState: CameraSessionState,
    refreshStatus: CameraPropertyRefreshStatus,
    strings: PhoneStringResolver,
): String =
    when {
        sessionState !is CameraSessionState.Connected ->
            strings.resolve(R.string.command_not_connected)
        refreshStatus is CameraPropertyRefreshStatus.Refreshing ->
            strings.resolve(R.string.command_wait_readback)
        refreshStatus is CameraPropertyRefreshStatus.Degraded ->
            strings.resolve(
                R.string.command_limited_readback,
                commandRefreshFailure(refreshStatus.failure, strings),
            )
        else -> strings.resolve(R.string.command_not_reported)
    }

private fun commandRefreshSummary(
    status: CameraPropertyRefreshStatus,
    strings: PhoneStringResolver,
): String =
    when (status) {
        CameraPropertyRefreshStatus.Idle -> strings.resolve(R.string.status_idle)
        CameraPropertyRefreshStatus.Refreshing -> strings.resolve(R.string.status_refreshing)
        CameraPropertyRefreshStatus.Ready -> strings.resolve(R.string.status_ready)
        is CameraPropertyRefreshStatus.Degraded -> commandRefreshFailure(status.failure, strings)
    }

private fun commandRefreshFailure(
    failure: CameraPropertyRefreshFailure,
    strings: PhoneStringResolver,
): String =
    when (failure) {
        CameraPropertyRefreshFailure.NOT_CONNECTED -> strings.resolve(R.string.command_failure_no_camera)
        CameraPropertyRefreshFailure.CORE_UNAVAILABLE -> strings.resolve(R.string.command_failure_core)
        CameraPropertyRefreshFailure.MEDIA_BUSY -> strings.resolve(R.string.command_failure_media)
        CameraPropertyRefreshFailure.UNSUPPORTED_PROPERTY -> strings.resolve(R.string.command_failure_unsupported)
        CameraPropertyRefreshFailure.TRANSPORT_FAILED -> strings.resolve(R.string.command_failure_transport)
    }

private fun commandTemperature(
    status: CameraTemperatureStatus?,
    strings: PhoneStringResolver,
): String =
    when (status) {
        CameraTemperatureStatus.NORMAL -> strings.resolve(R.string.temperature_ok)
        CameraTemperatureStatus.WARNING -> strings.resolve(R.string.temperature_check)
        CameraTemperatureStatus.HOT -> strings.resolve(R.string.temperature_hot)
        null -> "—"
    }

/**
 * Compares recording-mode labels loosely: crop prefixes (`[FX] ` / `[DX] `) and
 * spacing around the middle-dot are ignored so top-bar REC confirmation matches
 * both the capability string and the compact info-pill readout.
 */
internal fun recordingModeLabelsMatch(left: String?, right: String?): Boolean {
    val a = normalizeRecordingModeLabel(left)
    val b = normalizeRecordingModeLabel(right)
    return a.isNotEmpty() && a == b
}

/** Normalize crop prefix + middot spacing for recording-mode labels. */
internal fun normalizeRecordingModeLabel(value: String?): String {
    if (value.isNullOrBlank()) return ""
    return value
        .trim()
        .replace(Regex("""^\[[^\]]+\]\s*"""), "")
        .replace(Regex("""\s*·\s*"""), "·")
        .replace(Regex("""\s+"""), " ")
}

/**
 * Maps a display value (compact `6K · 25p`, raw `6048x3402 · 25p`, or crop-prefixed)
 * onto the first camera-advertised option that represents the same mode.
 */
internal fun matchRecordingModeOption(display: String?, options: List<String>): String? {
    if (options.isEmpty()) return null
    val raw = display?.trim()?.takeIf { it.isNotEmpty() } ?: return null
    options.firstOrNull { it == raw }?.let { return it }
    val normalized = normalizeRecordingModeLabel(raw)
    options.firstOrNull { normalizeRecordingModeLabel(it) == normalized }?.let { return it }
    // Raw property path: "6048x3402 · 25p" or "6048x3402 · 25p" → compact class label.
    val compact = compactRecordingModeFromRawDisplay(raw)
    if (compact != null) {
        val compactNorm = normalizeRecordingModeLabel(compact)
        options.firstOrNull { normalizeRecordingModeLabel(it) == compactNorm }?.let { return it }
    }
    return null
}

/**
 * Turns a raw `WxH · Np` / `WxH·Np` tile value into `6K · 25p`-style compact form.
 */
internal fun compactRecordingModeFromRawDisplay(display: String): String? {
    val cleaned = display.trim().replace(Regex("""\s*·\s*"""), " · ")
    val match =
        Regex(
                """^(\d+)\s*[xX×]\s*(\d+)\s*·\s*(\d+)\s*p?$""",
                RegexOption.IGNORE_CASE,
            )
            .matchEntire(cleaned)
            ?: return null
    val width = match.groupValues[1].toIntOrNull() ?: return null
    val fps = match.groupValues[3].toIntOrNull() ?: return null
    val resolutionClass =
        when {
            width >= 7680 -> "8K"
            width >= 5000 -> "6K"
            width >= 3500 -> "4K"
            else -> width.toString()
        }
    return "$resolutionClass · ${fps}p"
}

/** True only when a completed property refresh reflects the accepted control write. */
internal fun cameraPropertyConfirmsSelection(
    snapshot: CameraPropertySnapshot,
    control: CameraControl,
    label: String,
): Boolean =
    when (control) {
        CameraControl.ISO -> snapshot.iso?.toString() == label
        CameraControl.SHUTTER ->
            when (snapshot.shutterMode) {
                CameraShutterMode.ANGLE -> snapshot.shutterAngle == label
                CameraShutterMode.SPEED -> snapshot.shutterSpeed == label
                null -> false
            }
        CameraControl.IRIS -> snapshot.iris == label
        CameraControl.WHITE_BALANCE ->
            if (label.endsWith("K")) {
                snapshot.whiteBalanceMode == COLOR_TEMPERATURE_MODE &&
                    snapshot.whiteBalanceKelvin?.let { "${it}K" } == label
            } else {
                snapshot.whiteBalanceMode == label
            }
        CameraControl.FOCUS_MODE -> snapshot.focusMode == label
        CameraControl.FOCUS_AREA -> snapshot.focusArea == label
        CameraControl.FOCUS_SUBJECT -> snapshot.focusSubject == label
        CameraControl.EXPOSURE_MODE -> snapshot.exposureMode == label
        CameraControl.AUDIO_SENSITIVITY -> snapshot.audioSensitivity == label
        CameraControl.AUDIO_INPUT -> snapshot.audioInput == label
        CameraControl.WIND_FILTER -> snapshot.windFilter == label
        CameraControl.ATTENUATOR -> snapshot.inputAttenuator == label
        CameraControl.AUDIO_32_BIT_FLOAT -> snapshot.audio32BitFloat == label
        CameraControl.BASE_ISO -> snapshot.baseIso == label
        CameraControl.SHUTTER_MODE ->
            when (snapshot.shutterMode) {
                CameraShutterMode.ANGLE -> label == "Angle"
                CameraShutterMode.SPEED -> label == "Speed"
                null -> false
            }
        CameraControl.SHUTTER_LOCK ->
            snapshot.shutterLocked?.let { (if (it) "Locked" else "Unlocked") == label } == true
        CameraControl.WHITE_BALANCE_TINT -> snapshot.whiteBalanceTint == label
        CameraControl.RESOLUTION_FRAMERATE -> {
            // Prefer the D0A0-backed live label. Falling through to resolution+fps when
            // resolutionFrameRate is already present caused false "already confirmed"
            // skips: all 6K modes share WxH (`6048x3402`), so a lagging fps property
            // (often stuck at 24) made selecting 24p look like a no-op and never write.
            val live = snapshot.resolutionFrameRate
            if (!live.isNullOrBlank()) {
                recordingModeLabelsMatch(live, label)
            } else {
                recordingModeLabelsMatch(
                    monitorResolutionLabel(snapshot.resolution, snapshot.frameRate, ""),
                    label,
                )
            }
        }
        CameraControl.CODEC ->
            recordingModeLabelsMatch(snapshot.codecSelection, label) ||
                recordingModeLabelsMatch(
                    snapshot.codec?.let(::monitorCodecShortLabel),
                    label,
                )
        CameraControl.VIBRATION_REDUCTION -> snapshot.vibrationReduction == label
        CameraControl.ELECTRONIC_VR -> snapshot.electronicVr == label
    }

/* Every label below is accepted by `PTPCameraPropertyWrite` in the shared Swift core. */
private const val COLOR_TEMPERATURE_MODE = "Color temp"

private val EXPOSURE_MODE_OPTIONS = listOf("Auto", "P", "A", "S", "M", "U1", "U2", "U3")

/**
 * iOS `CameraPicker.options` fallbacks for the resolution/codec drums when the
 * body has not yet advertised `MovScreenSize` / `MovFileType` enums (demo feed
 * and partial readback). Prefer camera-advertised lists when present; never
 * invent packed PTP values — the Swift core still rejects unknown labels on
 * real hardware writes.
 */
internal val IOS_RESOLUTION_PICKER_FALLBACKS =
    listOf("6K · 24p", "6K · 25p", "6K · 30p", "6K · 50p", "4K · 60p")

/** iOS `CameraPicker.options` codec fallback list (see [IOS_RESOLUTION_PICKER_FALLBACKS]). */
internal val IOS_CODEC_PICKER_FALLBACKS =
    listOf("R3D NE", "N-RAW", "ProRes RAW HQ", "ProRes 422 HQ", "H.265 10-bit")

/**
 * The DISP 3 command dashboard: camera-backed health and primary controls at
 * left, with an iOS-shaped Image / Focus / Audio / Monitor companion column at
 * right (`ios/Runner/MonitorPanels.swift` CommandMonitor).
 */
@Composable
internal fun CommandDashboard(
    recording: Boolean,
    timecodeRetention: MonitorTimecodeRetention,
    sessionState: CameraSessionState,
    presentation: CommandDashboardPresentation,
    controlsEnabled: Boolean,
    pendingControl: CameraControl?,
    onOpenControl: (CommandControlRequest) -> Unit,
    onMoveTile: (CommandTileKind, Int) -> Unit,
    onReorderStarted: () -> Unit = {},
    liveFps: String = presentation.frameRate,
    signalBars: Int = 0,
    modifier: Modifier = Modifier,
) {
    Row(
        modifier,
        horizontalArrangement = Arrangement.spacedBy(12.dp),
    ) {
        Column(
            Modifier.weight(2.35f).fillMaxHeight(),
            verticalArrangement = Arrangement.spacedBy(8.dp),
        ) {
            Row(
                horizontalArrangement = Arrangement.spacedBy(11.dp),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                RecordChip(recording)
                // iOS CommandTimecodeReadout: monospaced 60pt.
                RetainedCameraTimecodeReadout(
                    retention = timecodeRetention,
                    sessionState = sessionState,
                    sizeSp = 60f,
                )
            }
            CommandHealthStrip(
                presentation = presentation,
                liveFps = liveFps,
                signalBars = signalBars,
            )
            CommandGrid(
                tiles = presentation.tiles,
                controlsEnabled = controlsEnabled,
                pendingControl = pendingControl,
                onOpenControl = onOpenControl,
                onMoveTile = onMoveTile,
                onReorderStarted = onReorderStarted,
                modifier = Modifier.fillMaxWidth().weight(1f),
            )
        }
        // iOS sideWidth = max(160, width * 0.27) ≈ 0.85fr of the 2.35+0.85 split.
        CommandSideColumn(
            sections = presentation.sideSections,
            controlsEnabled = controlsEnabled,
            pendingControl = pendingControl,
            onOpenControl = onOpenControl,
            modifier = Modifier.weight(0.85f).fillMaxHeight(),
        )
    }
}

/**
 * The portrait command surface keeps the system rail outside its viewport and
 * makes every secondary control reachable through one labeled scroll region.
 */
@Composable
internal fun PortraitCommandDashboard(
    presentation: CommandDashboardPresentation,
    timecodeRetention: MonitorTimecodeRetention,
    sessionState: CameraSessionState,
    controlsEnabled: Boolean,
    pendingControl: CameraControl?,
    onOpenControl: (CommandControlRequest) -> Unit,
    onMoveTile: (CommandTileKind, Int) -> Unit,
    onReorderStarted: () -> Unit = {},
    modifier: Modifier = Modifier,
) {
    CommandDashboardScrollContainer(
        accessibilityLabel = stringResource(R.string.command_dashboard_description),
        modifier = modifier.background(LiveDesign.background),
    ) {
        Column(
            Modifier
                .fillMaxWidth()
                .padding(start = 12.dp, end = 12.dp, bottom = 24.dp),
            verticalArrangement = Arrangement.spacedBy(10.dp),
        ) {
            BoxWithConstraints(
                Modifier.fillMaxWidth().height(80.dp),
                contentAlignment = Alignment.Center,
            ) {
                FitScale(maxWidth) {
                    RetainedCameraTimecodeReadout(
                        retention = timecodeRetention,
                        sessionState = sessionState,
                        sizeSp = 52f,
                    )
                }
            }
            CommandGrid(
                tiles = presentation.tiles,
                controlsEnabled = controlsEnabled,
                pendingControl = pendingControl,
                onOpenControl = onOpenControl,
                onMoveTile = onMoveTile,
                onReorderStarted = onReorderStarted,
                modifier =
                    Modifier
                        .fillMaxWidth()
                        .height(portraitCommandGridHeightDp(presentation.tiles.size).dp),
            )
            CommandSecondarySections(
                sections = presentation.sideSections,
                controlsEnabled = controlsEnabled,
                pendingControl = pendingControl,
                onOpenControl = onOpenControl,
                compact = false,
                modifier = Modifier.fillMaxWidth(),
            )
        }
    }
}

/** Hero timecode with the accent frame field (iOS `CommandTimecodeReadout`). */
@Composable
internal fun CommandTimecode(
    timecode: LiveFrameTimecode?,
    sizeSp: Float,
    modifier: Modifier = Modifier,
) {
    CameraTimecodeReadout(timecode = timecode, sizeSp = sizeSp, modifier = modifier)
}

/**
 * Camera-derived Temp / Storage / Camera / Lens strip + live FPS chip
 * (iOS `CommandHealthStrip` — no "Read" block; FPS lives in [FpsChip]).
 */
@Composable
private fun CommandHealthStrip(
    presentation: CommandDashboardPresentation,
    liveFps: String,
    signalBars: Int,
) {
    val okLabel = stringResource(R.string.temperature_ok)
    Row(
        Modifier
            .fillMaxWidth()
            .clip(ChromeShape)
            .background(LiveDesign.surface, ChromeShape)
            .border(1.dp, LiveDesign.hairline, ChromeShape)
            .padding(horizontal = 10.dp, vertical = 6.dp),
        horizontalArrangement = Arrangement.spacedBy(10.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        CommandStatusBlock(
            stringResource(R.string.command_health_temp),
            presentation.temperature,
            Modifier.weight(0.7f, fill = false).widthIn(min = 52.dp, max = 148.dp),
            good = presentation.temperature == okLabel ||
                presentation.temperature.startsWith(okLabel),
        )
        CommandStatusBlock(
            stringResource(R.string.command_health_storage),
            presentation.storage,
            Modifier.weight(1.1f).widthIn(min = 52.dp, max = 148.dp),
        )
        CommandStatusBlock(
            stringResource(R.string.command_health_camera),
            presentation.camera,
            Modifier.weight(1f).widthIn(min = 52.dp, max = 148.dp),
        )
        CommandStatusBlock(
            stringResource(R.string.command_health_lens),
            presentation.lens,
            Modifier.weight(1.25f).widthIn(min = 52.dp, max = 148.dp),
        )
        // Hold the FPS chip at its natural size (iOS fixedSize + layoutPriority).
        FpsChip(signalBars = signalBars, fps = liveFps)
    }
}

@Composable
private fun CommandStatusBlock(
    label: String,
    value: String,
    modifier: Modifier = Modifier,
    good: Boolean = false,
) {
    val description = stringResource(R.string.command_health_value_description, label, value)
    Column(
        modifier.semantics { contentDescription = description },
        verticalArrangement = Arrangement.spacedBy(2.dp),
    ) {
        Text(
            label.uppercase(),
            // iOS CommandStatusBlock: 8.5 bold
            style = chromeStyle(8.5f, FontWeight.Bold),
            color = LiveDesign.faint,
            maxLines = 1,
        )
        Text(
            value,
            // iOS: 12 medium mono
            style = chromeStyle(12f, FontWeight.Medium, mono = true),
            color = if (good) LiveDesign.good else LiveDesign.text,
            maxLines = 1,
            overflow = TextOverflow.Clip,
        )
    }
}

/** The three-column primary grid, shared by landscape DISP 3 and portrait controls. */
@Composable
internal fun CommandGrid(
    tiles: List<CommandTilePresentation>,
    controlsEnabled: Boolean,
    pendingControl: CameraControl?,
    onOpenControl: (CommandControlRequest) -> Unit,
    onMoveTile: (CommandTileKind, Int) -> Unit,
    onReorderStarted: () -> Unit = {},
    modifier: Modifier = Modifier,
) {
    val columns = COMMAND_GRID_COLUMNS
    val spacing = COMMAND_GRID_SPACING_DP.dp
    val rows = commandPrimaryGridRows(tiles.size, columns)
    val latestTiles by rememberUpdatedState(tiles)
    val latestMoveTile by rememberUpdatedState(onMoveTile)
    val latestReorderStarted by rememberUpdatedState(onReorderStarted)
    val latestOpenControl by rememberUpdatedState(onOpenControl)
    var draggingKind by remember { mutableStateOf<CommandTileKind?>(null) }
    var dragPosition by remember { mutableStateOf(Offset.Zero) }
    var suppressCameraClicksUntil by remember { mutableLongStateOf(0L) }
    val density = LocalDensity.current
    BoxWithConstraints(modifier.clipToBounds()) {
        // iOS CommandPrimaryGrid: max(44, (height - spacing * (rows-1)) / rows)
        val rowHeight = maxOf(44.dp, (maxHeight - spacing * (rows - 1)) / rows)
        val spacingPx = with(density) { spacing.toPx() }
        val tileWidth = (maxWidth - spacing * (columns - 1)) / columns
        val tileWidthPx = with(density) { tileWidth.toPx() }
        val rowHeightPx = with(density) { rowHeight.toPx() }
        val viewportWidthPx = constraints.maxWidth.toFloat()
        val viewportHeightPx = constraints.maxHeight.toFloat()
        Box(
            Modifier.fillMaxSize()
                .pointerInput(tileWidthPx, rowHeightPx, spacingPx, columns) {
                    detectDragGesturesAfterLongPress(
                        onDragStart = { start ->
                            val current = latestTiles
                            if (current.isNotEmpty()) {
                                val index =
                                    commandGridHitSlot(
                                        start,
                                        tileWidthPx,
                                        rowHeightPx,
                                        spacingPx,
                                        columns,
                                        current.size,
                                    )
                                index?.let(current::getOrNull)?.kind?.let { kind ->
                                    suppressCameraClicksUntil = Long.MAX_VALUE
                                    draggingKind = kind
                                    dragPosition = start
                                    latestReorderStarted()
                                }
                            }
                        },
                        onDrag = { change, _ ->
                            val kind = draggingKind
                            if (kind != null) {
                                change.consume()
                                dragPosition = change.position
                                val current = latestTiles
                                if (current.isNotEmpty()) {
                                    val target =
                                        commandGridSlot(
                                            change.position,
                                            tileWidthPx,
                                            rowHeightPx,
                                            spacingPx,
                                            columns,
                                            current.size,
                                        )
                                    if (current.indexOfFirst { it.kind == kind } != target) {
                                        latestMoveTile(kind, target)
                                    }
                                }
                            }
                        },
                        onDragEnd = {
                            if (draggingKind != null) {
                                suppressCameraClicksUntil =
                                    SystemClock.uptimeMillis() +
                                    COMMAND_REORDER_CLICK_SUPPRESSION_MS
                            }
                            draggingKind = null
                        },
                        onDragCancel = {
                            if (draggingKind != null) {
                                suppressCameraClicksUntil =
                                    SystemClock.uptimeMillis() +
                                    COMMAND_REORDER_CLICK_SUPPRESSION_MS
                            }
                            draggingKind = null
                        },
                    )
                },
        ) {
            tiles.forEachIndexed { index, tile ->
                val kind = tile.kind
                key(kind ?: "${tile.title}-$index") {
                    val dragging = kind != null && kind == draggingKind
                    val slotX = (index % columns) * (tileWidthPx + spacingPx)
                    val slotY = (index / columns) * (rowHeightPx + spacingPx)
                    val offset =
                        if (dragging) {
                            IntOffset(
                                (dragPosition.x - tileWidthPx / 2f)
                                    .coerceIn(0f, (viewportWidthPx - tileWidthPx).coerceAtLeast(0f))
                                    .roundToInt(),
                                (dragPosition.y - rowHeightPx / 2f)
                                    .coerceIn(0f, (viewportHeightPx - rowHeightPx).coerceAtLeast(0f))
                                    .roundToInt(),
                            )
                        } else {
                            IntOffset(slotX.roundToInt(), slotY.roundToInt())
                        }
                    CommandTile(
                        tile = tile,
                        index = index,
                        tileCount = tiles.size,
                        controlsEnabled = controlsEnabled,
                        pendingControl = pendingControl,
                        onOpenControl = { request ->
                            if (SystemClock.uptimeMillis() >= suppressCameraClicksUntil) {
                                latestOpenControl(request)
                            }
                        },
                        onMoveTo = { target ->
                            kind?.let {
                                latestMoveTile(it, target)
                                latestReorderStarted()
                            }
                        },
                        modifier =
                            Modifier.offset { offset }
                                .width(tileWidth)
                                .height(rowHeight)
                                // iOS: scaleEffect(1.06) + shadow(radius: 16, y: 8) while dragging.
                                .graphicsLayer {
                                    scaleX = if (dragging) 1.06f else 1f
                                    scaleY = if (dragging) 1.06f else 1f
                                    shadowElevation = if (dragging) 16.dp.toPx() else 0f
                                    shape = ChromeShape
                                    clip = true
                                }
                                .zIndex(if (dragging) 1f else 0f),
                    )
                }
            }
        }
    }
}

/** One camera value tile with direct drag and accessibility reorder actions. */
@OptIn(ExperimentalFoundationApi::class)
@Composable
private fun CommandTile(
    tile: CommandTilePresentation,
    index: Int,
    tileCount: Int,
    controlsEnabled: Boolean,
    pendingControl: CameraControl?,
    onOpenControl: (CommandControlRequest) -> Unit,
    onMoveTo: (Int) -> Unit,
    modifier: Modifier = Modifier,
) {
    val request = tile.request
    val pending = pendingControl != null
    // `null == null` is true in Kotlin — never treat a missing request as "applying".
    val applyingThisControl = request != null && request.control == pendingControl
    // Stay tappable while another control writes — applies coalesce; greying the
    // whole grid made rapid multi-control edits feel stuck.
    val controlEnabled = request != null && controlsEnabled
    // Dashboard layout is app-local, so even read-only camera values remain
    // reorderable without implying that their Nikon property can be changed.
    val canMove = tile.kind != null
    val interactive = controlEnabled || canMove
    val moveEarlierLabel = stringResource(R.string.command_move_earlier, tile.title)
    val moveLaterLabel = stringResource(R.string.command_move_later, tile.title)
    val applyingDescription = stringResource(R.string.command_state_applying)
    val pendingDescription = stringResource(R.string.command_state_pending)
    val readOnlyDescription = tile.unavailableReason ?: stringResource(R.string.command_state_read_only)
    val readOnlyReorderDescription =
        stringResource(R.string.command_state_read_only_reorder, readOnlyDescription)
    val lockedReorderDescription = stringResource(R.string.command_state_locked_reorder)
    val changeReorderDescription = stringResource(R.string.command_state_change_reorder)
    val changeLabel = stringResource(R.string.command_change_description, tile.title)
    val valueDescription = stringResource(R.string.command_value_description, tile.title, tile.value)
    val reorderActions =
        buildList {
            if (canMove && index > 0) {
                add(
                    CustomAccessibilityAction(moveEarlierLabel) {
                        onMoveTo(index - 1)
                        true
                    },
                )
            }
            if (canMove && index < tileCount - 1) {
                add(
                    CustomAccessibilityAction(moveLaterLabel) {
                        onMoveTo(index + 1)
                        true
                    },
                )
            }
        }
    val description =
        buildString {
            append(valueDescription)
            when {
                applyingThisControl -> append(applyingDescription)
                pending -> append(pendingDescription)
                request == null -> append(readOnlyReorderDescription)
                !controlsEnabled -> append(lockedReorderDescription)
                else -> append(changeReorderDescription)
            }
        }
    // iOS CommandTile: pad h12/v8, title 10 bold, value 24 medium mono, LiveDesign.cornerRadius.
    Column(
        modifier
            .clip(ChromeShape)
            .background(LiveDesign.surface, ChromeShape)
            .border(1.dp, LiveDesign.hairline, ChromeShape)
            .semantics(mergeDescendants = true) {
                contentDescription = description
                customActions = reorderActions
                if (!interactive) disabled()
            }
            .combinedClickable(
                enabled = interactive,
                onClickLabel = if (controlEnabled) changeLabel else null,
                onClick = { request?.takeIf { controlEnabled }?.let(onOpenControl) },
            )
            .padding(horizontal = 12.dp, vertical = 8.dp),
        verticalArrangement = Arrangement.SpaceBetween,
    ) {
        Text(
            tile.title.uppercase(),
            style = chromeStyle(10f, FontWeight.Bold),
            color = LiveDesign.faint,
            maxLines = 1,
            overflow = TextOverflow.Clip,
        )
        BoxWithConstraints(Modifier.fillMaxWidth()) {
            FitScale(maxWidth) {
                Text(
                    tile.value,
                    style =
                        chromeStyle(
                            commandTileValueSize(tile.value),
                            FontWeight.Medium,
                            mono = true,
                        ),
                    color = if (controlEnabled) LiveDesign.text else LiveDesign.muted,
                    maxLines = 1,
                    overflow = TextOverflow.Clip,
                )
            }
        }
    }
}

/** Keeps full camera values visible inside the tight three-column portrait grid. */
internal fun commandTileValueSize(value: String): Float =
    when {
        value.length <= 8 -> 24f
        value.length <= 11 -> 20f
        else -> 16f
    }

/** The compact iOS-shaped Image / Focus / Audio companion column. */
@Composable
private fun CommandSideColumn(
    sections: List<CommandSideSectionPresentation>,
    controlsEnabled: Boolean,
    pendingControl: CameraControl?,
    onOpenControl: (CommandControlRequest) -> Unit,
    modifier: Modifier = Modifier,
) {
    CommandDashboardScrollContainer(
        accessibilityLabel = stringResource(R.string.command_side_description),
        modifier = modifier,
    ) {
        CommandSecondarySections(
            sections = sections,
            controlsEnabled = controlsEnabled,
            pendingControl = pendingControl,
            onOpenControl = onOpenControl,
            compact = true,
            modifier = Modifier.fillMaxWidth().padding(bottom = 8.dp),
        )
    }
}

/** The shared Image / Focus / Audio / Monitor section stack (iOS CommandSideColumn). */
@Composable
private fun CommandSecondarySections(
    sections: List<CommandSideSectionPresentation>,
    controlsEnabled: Boolean,
    pendingControl: CameraControl?,
    onOpenControl: (CommandControlRequest) -> Unit,
    compact: Boolean,
    modifier: Modifier = Modifier,
) {
    // iOS CommandSideColumn VStack spacing: 4 between sections.
    Column(
        modifier,
        verticalArrangement = Arrangement.spacedBy(4.dp),
    ) {
        sections.forEach { section ->
            CommandSideSection(
                section = section,
                controlsEnabled = controlsEnabled,
                pendingControl = pendingControl,
                onOpenControl = onOpenControl,
                compact = compact,
            )
        }
    }
}

/**
 * iOS-shaped vertical command scroller with an explicit visual and TalkBack
 * affordance whenever more settings remain below the viewport.
 */
@Composable
private fun CommandDashboardScrollContainer(
    accessibilityLabel: String,
    modifier: Modifier = Modifier,
    content: @Composable () -> Unit,
) {
    val scrollState = rememberScrollState()
    val moreDescription = stringResource(R.string.command_more_description)
    Box(modifier.clipToBounds()) {
        Box(
            Modifier
                .fillMaxSize()
                .verticalScroll(scrollState)
                .semantics { contentDescription = accessibilityLabel },
        ) {
            content()
        }
        if (scrollState.canScrollForward) {
            Box(
                Modifier
                    .align(Alignment.BottomCenter)
                    .fillMaxWidth()
                    .height(44.dp)
                    .background(
                        Brush.verticalGradient(
                            colors = listOf(Color.Transparent, LiveDesign.background),
                        ),
                    ),
            )
            Text(
                stringResource(R.string.command_more),
                style = chromeStyle(9f, FontWeight.Bold),
                color = LiveDesign.muted,
                modifier =
                    Modifier
                        .align(Alignment.BottomCenter)
                        .padding(bottom = 3.dp)
                        .semantics {
                            contentDescription = moreDescription
                        },
            )
        }
    }
}

@Composable
private fun CommandSideSection(
    section: CommandSideSectionPresentation,
    controlsEnabled: Boolean,
    pendingControl: CameraControl?,
    onOpenControl: (CommandControlRequest) -> Unit,
    compact: Boolean,
) {
    // iOS CommandSection: title 9.5 bold, rows VStack spacing 5, CmdRow HStack spacing 6.
    Column(
        Modifier.fillMaxWidth(),
        verticalArrangement = Arrangement.spacedBy(4.dp),
    ) {
        Text(
            section.title.uppercase(),
            style = chromeStyle(9.5f, FontWeight.Bold),
            color = LiveDesign.faint,
            modifier = Modifier.padding(start = 2.dp),
        )
        Column(
            Modifier.fillMaxWidth(),
            verticalArrangement = Arrangement.spacedBy(5.dp),
        ) {
            commandSideSectionRows(section).forEach { row ->
                Row(
                    Modifier.fillMaxWidth(),
                    horizontalArrangement = Arrangement.spacedBy(6.dp),
                ) {
                    row.forEach { cell ->
                        // One tile in a row spans full width (iOS CmdRow / .span2).
                        CommandSmallTile(
                            cell = cell,
                            controlsEnabled = controlsEnabled,
                            pendingControl = pendingControl,
                            onOpenControl = onOpenControl,
                            compact = compact,
                            modifier = Modifier.weight(1f),
                        )
                    }
                }
            }
        }
    }
}

@Composable
@OptIn(ExperimentalFoundationApi::class)
private fun CommandSmallTile(
    cell: CommandTilePresentation,
    controlsEnabled: Boolean,
    pendingControl: CameraControl?,
    onOpenControl: (CommandControlRequest) -> Unit,
    compact: Boolean,
    modifier: Modifier = Modifier,
) {
    val request = cell.request
    val pending = pendingControl != null
    // Same null-equality trap as the primary tile path.
    val applyingThisControl = request != null && request.control == pendingControl
    val enabled = request != null && controlsEnabled
    val applyingDescription = stringResource(R.string.command_state_applying)
    val pendingDescription = stringResource(R.string.command_state_pending)
    val readOnlyDescription = cell.unavailableReason ?: stringResource(R.string.command_state_read_only)
    val lockedDescription = stringResource(R.string.command_state_locked)
    val changeDescription = stringResource(R.string.camera_state_change_hint)
    val changeLabel = stringResource(R.string.command_change_description, cell.title)
    val valueDescription = stringResource(R.string.command_value_description, cell.title, cell.value)
    val readOnlyValueDescription =
        stringResource(R.string.command_read_only_description, readOnlyDescription)
    val description =
        buildString {
            append(valueDescription)
            when {
                applyingThisControl -> append(applyingDescription)
                pending -> append(pendingDescription)
                request == null -> append(readOnlyValueDescription)
                !controlsEnabled -> append(lockedDescription)
                else -> append(changeDescription)
            }
        }
    // iOS CommandSmallTile: minHeight 42, pad h10/v6, title 9 bold muted, value 15 medium mono.
    val valueColor =
        when {
            cell.amber -> LiveDesign.accent
            cell.muted -> LiveDesign.faint
            enabled -> LiveDesign.text
            else -> LiveDesign.muted
        }
    Column(
        modifier
            .heightIn(min = if (compact) COMMAND_SIDE_TILE_MIN_HEIGHT else COMMAND_PORTRAIT_SIDE_TILE_HEIGHT)
            .clip(ChromeShape)
            .background(LiveDesign.surface, ChromeShape)
            .border(1.dp, LiveDesign.hairline, ChromeShape)
            .semantics(mergeDescendants = true) {
                contentDescription = description
                if (!enabled) disabled()
            }
            .combinedClickable(
                enabled = enabled,
                onClickLabel = changeLabel,
                onClick = { request?.let(onOpenControl) },
            )
            .padding(horizontal = 10.dp, vertical = 6.dp),
        verticalArrangement = Arrangement.spacedBy(5.dp),
    ) {
        Text(
            cell.title.uppercase(),
            style = chromeStyle(9f, FontWeight.Bold),
            color = LiveDesign.muted,
            maxLines = 1,
            overflow = TextOverflow.Clip,
        )
        Text(
            cell.value,
            style = chromeStyle(15f, FontWeight.Medium, mono = true),
            color = valueColor,
            maxLines = 1,
            overflow = TextOverflow.Clip,
        )
    }
}

/**
 * Command-mode control surface — same glass drum / tint pad as live pickers
 * (iOS `PickerPanel` dead-centred when `displayMode == .command`), not a
 * Material dialog.
 */
@Composable
internal fun CommandControlDialog(
    request: CommandControlRequest,
    controlsEnabled: Boolean,
    pendingControl: CameraControl?,
    feedback: CommandControlFeedback?,
    onSelect: (String) -> Unit,
    onDismiss: () -> Unit,
) {
    val options = commandControlOptions(request, pendingControl, controlsEnabled)
    val isTintPad = request.control == CameraControl.WHITE_BALANCE_TINT
    // Allow dismiss while a write drains — iOS never traps the operator in the panel.
    BackHandler(onBack = onDismiss)

    var revealed by remember(request.control, request.title) { mutableStateOf(false) }
    LaunchedEffect(request.control, request.title) { revealed = true }
    val travel = 320.dp
    val revealOffset by
        animateDpAsState(
            targetValue = if (revealed) 0.dp else travel,
            animationSpec = IosPanelRevealSpec,
            label = "commandPickerReveal",
        )

    Box(Modifier.fillMaxSize()) {
        Box(
            Modifier.fillMaxSize()
                .chromeClickable(onClick = onDismiss),
        )
        Column(
            modifier =
                Modifier
                    .align(Alignment.Center)
                    .offset(y = revealOffset)
                    .alpha(if (revealed) 1f else 0f)
                    .width(420.dp)
                    .heightIn(max = 360.dp)
                    // Scene overlay glass (blurs chrome + feed); shape from drawBackdrop.
                    .overlayGlass(ChromeShape)
                    .border(1.dp, LiveDesign.hairlineStrong, ChromeShape)
                    .pointerInput(Unit) { detectTapGestures(onTap = {}) }
                    .padding(horizontal = 20.dp, vertical = 16.dp),
            verticalArrangement = Arrangement.spacedBy(14.dp),
        ) {
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
                        request.title,
                        style = chromeStyle(18f, FontWeight.ExtraBold).copy(letterSpacing = 2.sp),
                        color = LiveDesign.text,
                        maxLines = 1,
                    )
                    Text(
                        stringResource(R.string.command_current_value, request.currentValue)
                            .uppercase(),
                        style =
                            chromeStyle(11f, FontWeight.SemiBold, mono = true)
                                .copy(letterSpacing = 1.5.sp),
                        color = LiveDesign.faint,
                        maxLines = 1,
                        overflow = TextOverflow.Clip,
                        modifier = Modifier.padding(bottom = 2.dp),
                    )
                }
                PanelCloseButton(onClick = onDismiss)
            }
            // Errors only — success toasts steal height and iOS stays silent on snap.
            if (feedback?.isError == true) {
                Text(
                    feedback.message,
                    style = chromeStyle(11f, FontWeight.Medium),
                    color = LiveDesign.rec,
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
            // iOS PickerPanel: local selection + lastApplied, seeded once on open.
            // Never gate settles on request.currentValue — that blocks re-selecting the
            // value the popup opened on (25→30 works, 30→25 silent until reopen).
            val openKey = request.control to request.title
            val labels = options.map { it.label }
            val seed =
                labels.firstOrNull { it == request.currentValue }
                    ?: labels.firstOrNull()
                    ?: request.currentValue
            var lastApplied by remember(openKey) { mutableStateOf(seed) }
            var selection by remember(openKey) { mutableStateOf(seed) }
            if (isTintPad) {
                val tintAvailable = options.isNotEmpty()
                WhiteBalanceTintPad(
                    currentLabel = lastApplied.ifBlank { "Neutral" },
                    available = tintAvailable,
                    interactive = controlsEnabled && tintAvailable,
                    onCommit = { label ->
                        if (label != lastApplied) {
                            lastApplied = label
                            selection = label
                            onSelect(label)
                        }
                    },
                    modifier = Modifier.fillMaxWidth(),
                )
            } else {
                AccentDrumWheel(
                    options = labels,
                    selection = selection,
                    // Stay interactive during in-flight applies (coalesced queue).
                    interactive = controlsEnabled,
                    modifier = Modifier.fillMaxWidth(),
                    onSettle = { settled ->
                        if (settled.isEmpty()) return@AccentDrumWheel
                        selection = settled
                        if (settled != lastApplied) {
                            lastApplied = settled
                            onSelect(settled)
                        }
                    },
                )
            }
        }
    }
}
