package com.opencapture.openzcine

import android.content.Context
import android.content.SharedPreferences
import android.os.SystemClock
import androidx.compose.foundation.ExperimentalFoundationApi
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.combinedClickable
import androidx.compose.foundation.gestures.detectDragGesturesAfterLongPress
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
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.key
import androidx.compose.runtime.mutableLongStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberUpdatedState
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clipToBounds
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.semantics.CustomAccessibilityAction
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.customActions
import androidx.compose.ui.semantics.disabled
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.IntOffset
import androidx.compose.ui.unit.dp
import androidx.compose.ui.zIndex
import com.opencapture.openzcine.core.CameraControl
import com.opencapture.openzcine.core.CameraPropertyRefreshFailure
import com.opencapture.openzcine.core.CameraPropertyRefreshStatus
import com.opencapture.openzcine.core.CameraPropertySnapshot
import com.opencapture.openzcine.core.CameraSessionState
import com.opencapture.openzcine.core.CameraShutterMode
import com.opencapture.openzcine.core.CameraTemperatureStatus
import com.opencapture.openzcine.core.LiveFrameTimecode
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
            enabled = controlsEnabled && pendingControl == null,
        )
    }

/** One grid or side-column value, including its safe-to-write intent when supported. */
internal data class CommandTilePresentation(
    val kind: CommandTileKind? = null,
    val title: String,
    val value: String,
    val request: CommandControlRequest? = null,
    val unavailableReason: String? = null,
)

/** A small section of the right-hand Image / Focus / Audio command column. */
internal data class CommandSideSectionPresentation(
    val title: String,
    val cells: List<CommandTilePresentation>,
)

/** All display data needed by the dashboard, projected from the typed session snapshot. */
internal data class CommandDashboardPresentation(
    val tiles: List<CommandTilePresentation>,
    val sideSections: List<CommandSideSectionPresentation>,
    val temperature: String,
    val storage: String,
    val camera: String,
    val lens: String,
    val frameRate: String,
    val refreshSummary: String,
)

private const val COMMAND_GRID_COLUMNS = 3
private const val COMMAND_GRID_SPACING_DP = 9
private const val COMMAND_REORDER_CLICK_SUPPRESSION_MS = 150L
private const val COMMAND_PORTRAIT_GRID_ROW_HEIGHT_DP = 76
private val COMMAND_COMPACT_SIDE_TILE_HEIGHT = 36.dp
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
    recording: Boolean = false,
): CommandDashboardPresentation {
    val unavailable = commandPropertyUnavailableReason(sessionState, refreshStatus)
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
            ?: listOfNotNull(snapshot.resolution.monitorValueOrNull(), frameRate?.let { "${it}p" })
                .joinToString(separator = " · ")
                .ifBlank { null }
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
            "ISO is unavailable during recording until codec readback completes."
        } else {
            "ISO is locked while recording in R3D NE."
        }
    val capabilities = snapshot.controlCapabilities
    // The active descriptor changes with the camera's shutter circuit. Never
    // surface the inactive circuit or a local fallback ladder.
    val shutterOptions = capabilities.options(CameraControl.SHUTTER)
    val shutterWritable = snapshot.shutterLocked == false && shutterOptions.isNotEmpty()
    val shutterLockReason =
        when {
            snapshot.shutterLocked == true -> "Shutter is locked on the camera."
            snapshot.shutterLocked == null -> "Waiting for the camera shutter lock state."
            snapshot.shutterMode == null -> "Waiting for the active shutter mode."
            else -> "Shutter changes are unavailable."
        }

    fun editable(
        kind: CommandTileKind?,
        title: String,
        value: String?,
        control: CameraControl,
        options: List<String>,
        writable: Boolean = true,
        blockedReason: String = "This control is locked on the camera.",
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
                    "Mode",
                    snapshot.exposureMode,
                    CameraControl.EXPOSURE_MODE,
                    EXPOSURE_MODE_OPTIONS,
                ),
            CommandTileKind.ISO to
                editable(
                    CommandTileKind.ISO,
                    "ISO",
                    snapshot.iso?.takeIf { it > 0 }?.toString(),
                    CameraControl.ISO,
                    ISO_OPTIONS,
                    writable = !isoLockedDuringRecording,
                    blockedReason = isoLockReason,
                ),
            CommandTileKind.SHUTTER to
                advertisedEditable(
                    kind = CommandTileKind.SHUTTER,
                    title = "Shutter",
                    value = shutter,
                    control = CameraControl.SHUTTER,
                    blockedReason = shutterLockReason,
                    writable = shutterWritable,
                ),
            CommandTileKind.IRIS to
                editable(
                    CommandTileKind.IRIS,
                    "Iris",
                    snapshot.iris,
                    CameraControl.IRIS,
                    IRIS_OPTIONS,
                ),
            CommandTileKind.WHITE_BALANCE to
                editable(
                    CommandTileKind.WHITE_BALANCE,
                    "White Bal",
                    whiteBalance,
                    CameraControl.WHITE_BALANCE,
                    WHITE_BALANCE_OPTIONS,
                ),
            CommandTileKind.RESOLUTION_FRAMERATE to
                advertisedEditable(
                    kind = CommandTileKind.RESOLUTION_FRAMERATE,
                    title = "Resolution Framerate",
                    value = resolution,
                    control = CameraControl.RESOLUTION_FRAMERATE,
                    blockedReason = "This camera did not advertise recording modes.",
                ),
            CommandTileKind.CODEC to
                advertisedEditable(
                    kind = CommandTileKind.CODEC,
                    title = "Codec",
                    value = codec,
                    control = CameraControl.CODEC,
                    blockedReason = "This camera did not advertise codec modes.",
                ),
            CommandTileKind.STABILIZATION to
                advertisedEditable(
                    kind = CommandTileKind.STABILIZATION,
                    title = "VR",
                    value = snapshot.vibrationReduction,
                    control = CameraControl.VIBRATION_REDUCTION,
                    blockedReason = "This camera did not advertise movie VR modes.",
                ).copy(title = "VR / e-VR", value = stabilization ?: "—"),
        )
    val focusCells =
        listOf(
            editable(
                null,
                "Mode",
                snapshot.focusMode,
                CameraControl.FOCUS_MODE,
                FOCUS_MODE_OPTIONS,
            ),
            editable(
                null,
                "Area",
                snapshot.focusArea,
                CameraControl.FOCUS_AREA,
                FOCUS_AREA_OPTIONS,
            ),
            editable(
                null,
                "Subject",
                snapshot.focusSubject,
                CameraControl.FOCUS_SUBJECT,
                FOCUS_SUBJECT_OPTIONS,
            ),
        )
    val audioSensitivityCell =
        if (snapshot.audioSensitivity.monitorValueOrNull() != null) {
            editable(
                null,
                "Sens",
                snapshot.audioSensitivity,
                CameraControl.AUDIO_SENSITIVITY,
                AUDIO_SENSITIVITY_OPTIONS,
            )
        } else {
            readOnly(
                title = "Sens",
                value = snapshot.microphoneSensitivity,
                reason = "This microphone sensitivity has no Android write selector.",
            )
        }
    val audioCells =
        listOf(
            audioSensitivityCell,
            editable(
                null,
                "Input",
                snapshot.audioInput,
                CameraControl.AUDIO_INPUT,
                AUDIO_INPUT_OPTIONS,
            ),
            editable(
                null,
                "Wind",
                snapshot.windFilter,
                CameraControl.WIND_FILTER,
                ON_OFF_OPTIONS,
            ),
            editable(
                null,
                "Atten",
                snapshot.inputAttenuator,
                CameraControl.ATTENUATOR,
                ON_OFF_OPTIONS,
            ),
            editable(
                null,
                "32-bit Float",
                snapshot.audio32BitFloat,
                CameraControl.AUDIO_32_BIT_FLOAT,
                ON_OFF_OPTIONS,
            ),
        )

    val exposureCells =
        listOf(
            advertisedEditable(
                title = "Base ISO",
                value = snapshot.baseIso,
                control = CameraControl.BASE_ISO,
                blockedReason = "This camera did not advertise dual-base ISO circuits.",
            ),
            advertisedEditable(
                title = "Shutter Mode",
                value =
                    when (snapshot.shutterMode) {
                        CameraShutterMode.ANGLE -> "Angle"
                        CameraShutterMode.SPEED -> "Speed"
                        null -> null
                    },
                control = CameraControl.SHUTTER_MODE,
                blockedReason = "This camera did not advertise shutter display modes.",
            ),
            advertisedEditable(
                title = "Shutter Lock",
                value = snapshot.shutterLocked?.let { if (it) "Locked" else "Unlocked" },
                control = CameraControl.SHUTTER_LOCK,
                blockedReason = "This camera did not advertise its shutter lock control.",
            ),
            advertisedEditable(
                title = "WB Tint",
                value = snapshot.whiteBalanceTint,
                control = CameraControl.WHITE_BALANCE_TINT,
                blockedReason = "Fine tune is unavailable for the active white-balance mode.",
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
        sideSections =
            listOf(
                CommandSideSectionPresentation(
                    "Image",
                    listOf(
                        readOnly(
                            title = "Grid",
                            value = snapshot.cameraGrid,
                            reason = "Camera Grid Display is read-only on Android.",
                        ),
                        advertisedEditable(
                            title = "VR",
                            value = snapshot.vibrationReduction,
                            control = CameraControl.VIBRATION_REDUCTION,
                            blockedReason = "This camera did not advertise movie VR modes.",
                        ),
                        advertisedEditable(
                            title = "e-VR",
                            value = snapshot.electronicVr,
                            control = CameraControl.ELECTRONIC_VR,
                            blockedReason = "This camera did not advertise electronic VR.",
                        ),
                    ),
                ),
                CommandSideSectionPresentation("Exposure", exposureCells),
                CommandSideSectionPresentation("Focus", focusCells),
                CommandSideSectionPresentation("Audio", audioCells),
            ),
        temperature = commandTemperature(snapshot.temperatureStatus),
        storage = monitorStorageLabel(snapshot.storage),
        camera = camera,
        lens = snapshot.lens.monitorValueOrNull() ?: "—",
        frameRate = monitorFrameRateLabel(frameRate),
        refreshSummary = commandRefreshSummary(refreshStatus),
    )
}

private fun commandPropertyUnavailableReason(
    sessionState: CameraSessionState,
    refreshStatus: CameraPropertyRefreshStatus,
): String =
    when {
        sessionState !is CameraSessionState.Connected -> "Connect to a camera to read this control."
        refreshStatus is CameraPropertyRefreshStatus.Refreshing ->
            "Waiting for camera property readback."
        refreshStatus is CameraPropertyRefreshStatus.Degraded ->
            "Camera property readback is limited: ${commandRefreshFailure(refreshStatus.failure)}."
        else -> "This camera has not reported this control."
    }

private fun commandRefreshSummary(status: CameraPropertyRefreshStatus): String =
    when (status) {
        CameraPropertyRefreshStatus.Idle -> "Idle"
        CameraPropertyRefreshStatus.Refreshing -> "Refreshing"
        CameraPropertyRefreshStatus.Ready -> "Ready"
        is CameraPropertyRefreshStatus.Degraded -> commandRefreshFailure(status.failure)
    }

private fun commandRefreshFailure(failure: CameraPropertyRefreshFailure): String =
    when (failure) {
        CameraPropertyRefreshFailure.NOT_CONNECTED -> "No camera"
        CameraPropertyRefreshFailure.CORE_UNAVAILABLE -> "Core unavailable"
        CameraPropertyRefreshFailure.MEDIA_BUSY -> "Media is active"
        CameraPropertyRefreshFailure.UNSUPPORTED_PROPERTY -> "Limited by camera"
        CameraPropertyRefreshFailure.TRANSPORT_FAILED -> "Transport unavailable"
    }

private fun commandTemperature(status: CameraTemperatureStatus?): String =
    when (status) {
        CameraTemperatureStatus.NORMAL -> "OK"
        CameraTemperatureStatus.WARNING -> "CHECK"
        CameraTemperatureStatus.HOT -> "HOT"
        null -> "—"
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
        CameraControl.RESOLUTION_FRAMERATE -> snapshot.resolutionFrameRate == label
        CameraControl.CODEC -> snapshot.codecSelection == label
        CameraControl.VIBRATION_REDUCTION -> snapshot.vibrationReduction == label
        CameraControl.ELECTRONIC_VR -> snapshot.electronicVr == label
    }

/* Every label below is accepted by `PTPCameraPropertyWrite` in the shared Swift core. */
private const val COLOR_TEMPERATURE_MODE = "Color temp"

private val ISO_OPTIONS =
    listOf(
        "200", "250", "320", "400", "500", "640", "800", "1000", "1250", "1600",
        "2000", "2500", "3200", "4000", "5000", "6400", "8000", "10000", "12800",
        "16000", "20000", "25600",
    )

private val IRIS_OPTIONS =
    listOf("f/1.4", "f/2.0", "f/2.8", "f/4.0", "f/5.6", "f/8.0", "f/11.0")

private val WHITE_BALANCE_OPTIONS =
    listOf(
        "3200K", "4300K", "5400K", "5500K", "5600K", "5700K", "6500K", "Auto",
        "Natural auto", "Sunny", "Cloudy", "Shade", "Incandescent", "Fluorescent", "Flash",
        "Preset",
    )

private val EXPOSURE_MODE_OPTIONS = listOf("Auto", "P", "A", "S", "M", "U1", "U2", "U3")
private val FOCUS_MODE_OPTIONS = listOf("AF-S", "AF-C", "AF-F", "MF")
private val FOCUS_AREA_OPTIONS =
    listOf("Single", "Auto", "Wide-S", "Wide-L", "Wide-C1", "Wide-C2", "Subject")
private val FOCUS_SUBJECT_OPTIONS =
    listOf("Off", "Auto", "People", "Animal", "Vehicle", "Bird", "Airplane")
private val AUDIO_SENSITIVITY_OPTIONS = listOf("Auto") + (1..20).map(Int::toString)
private val AUDIO_INPUT_OPTIONS = listOf("Microphone", "Line")
private val ON_OFF_OPTIONS = listOf("OFF", "ON")

/**
 * The DISP 3 command dashboard: camera-backed health and primary controls at
 * left, with an iOS-shaped Image / Focus / Audio companion column at right.
 */
@Composable
internal fun CommandDashboard(
    recording: Boolean,
    timecode: LiveFrameTimecode?,
    presentation: CommandDashboardPresentation,
    controlsEnabled: Boolean,
    pendingControl: CameraControl?,
    onOpenControl: (CommandControlRequest) -> Unit,
    onMoveTile: (CommandTileKind, Int) -> Unit,
    onReorderStarted: () -> Unit = {},
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
                CommandTimecode(timecode, sizeSp = 44f)
            }
            CommandHealthStrip(presentation)
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
    timecode: LiveFrameTimecode?,
    controlsEnabled: Boolean,
    pendingControl: CameraControl?,
    onOpenControl: (CommandControlRequest) -> Unit,
    onMoveTile: (CommandTileKind, Int) -> Unit,
    onReorderStarted: () -> Unit = {},
    modifier: Modifier = Modifier,
) {
    CommandDashboardScrollContainer(
        accessibilityLabel =
            "Command dashboard. Swipe up to view Image, Focus, and Audio controls.",
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
                    CommandTimecode(
                        timecode = timecode,
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

/** Camera-derived Temp / Storage / Camera / Lens / Frame-rate health blocks. */
@Composable
private fun CommandHealthStrip(presentation: CommandDashboardPresentation) {
    Row(
        Modifier
            .fillMaxWidth()
            .background(LiveDesign.surface, ChromeShape)
            .border(1.dp, LiveDesign.hairline, ChromeShape)
            .padding(horizontal = 8.dp, vertical = 6.dp),
        horizontalArrangement = Arrangement.spacedBy(6.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        CommandStatusBlock("Temp", presentation.temperature, Modifier.weight(0.65f))
        CommandStatusBlock("Storage", presentation.storage, Modifier.weight(1.1f))
        CommandStatusBlock("Camera", presentation.camera, Modifier.weight(1f))
        CommandStatusBlock("Lens", presentation.lens, Modifier.weight(1.25f))
        CommandStatusBlock("FPS", presentation.frameRate, Modifier.weight(0.65f))
        CommandStatusBlock("Read", presentation.refreshSummary, Modifier.weight(0.8f))
    }
}

@Composable
private fun CommandStatusBlock(label: String, value: String, modifier: Modifier = Modifier) {
    Column(
        modifier.semantics { contentDescription = "$label $value" },
        verticalArrangement = Arrangement.spacedBy(2.dp),
    ) {
        Text(
            label.uppercase(),
            style = chromeStyle(8f, FontWeight.Bold),
            color = LiveDesign.faint,
            maxLines = 1,
        )
        Text(
            value,
            style = chromeStyle(10.5f, FontWeight.Medium, mono = true),
            color = if (label == "Temp" && value == "OK") LiveDesign.good else LiveDesign.text,
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
        val rowHeight = maxOf(66.dp, (maxHeight - spacing * (rows - 1)) / rows)
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
                                .graphicsLayer {
                                    scaleX = if (dragging) 1.04f else 1f
                                    scaleY = if (dragging) 1.04f else 1f
                                    shadowElevation = if (dragging) 14.dp.toPx() else 0f
                                    shape = ChromeShape
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
    val applyingThisControl = request?.control == pendingControl
    val controlEnabled = request != null && controlsEnabled && !pending
    // Dashboard layout is app-local, so even read-only camera values remain
    // reorderable without implying that their Nikon property can be changed.
    val canMove = tile.kind != null
    val interactive = controlEnabled || canMove
    val reorderActions =
        buildList {
            if (canMove && index > 0) {
                add(
                    CustomAccessibilityAction("Move ${tile.title} earlier") {
                        onMoveTo(index - 1)
                        true
                    },
                )
            }
            if (canMove && index < tileCount - 1) {
                add(
                    CustomAccessibilityAction("Move ${tile.title} later") {
                        onMoveTo(index + 1)
                        true
                    },
                )
            }
        }
    val description =
        buildString {
            append(tile.title)
            append(": ")
            append(tile.value)
            when {
                applyingThisControl -> append(". Applying change.")
                pending -> append(". Another control is being applied.")
                request == null -> append(". ${tile.unavailableReason ?: "Read-only."} Long press and drag to reorder.")
                !controlsEnabled -> append(". Controls are locked. Long press and drag to reorder.")
                else -> append(". Double tap to change; long press and drag to reorder.")
            }
        }
    Column(
        modifier
            .background(LiveDesign.surface, ChromeShape)
            .border(1.dp, LiveDesign.hairline, ChromeShape)
            .semantics(mergeDescendants = true) {
                contentDescription = description
                customActions = reorderActions
                if (!interactive) disabled()
            }
            .combinedClickable(
                enabled = interactive,
                onClickLabel = if (controlEnabled) "Change ${tile.title}" else null,
                onClick = { request?.takeIf { controlEnabled }?.let(onOpenControl) },
            )
            .padding(horizontal = 12.dp, vertical = 8.dp),
        verticalArrangement = Arrangement.SpaceBetween,
    ) {
        Text(
            tile.title.uppercase(),
            style = chromeStyle(10f, FontWeight.Bold),
            color = LiveDesign.faint,
            maxLines = 2,
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
        accessibilityLabel =
            "Image, Focus, and Audio controls. Swipe up to reveal more command controls.",
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

/** The shared Image / Focus / Audio section stack for both dashboard orientations. */
@Composable
private fun CommandSecondarySections(
    sections: List<CommandSideSectionPresentation>,
    controlsEnabled: Boolean,
    pendingControl: CameraControl?,
    onOpenControl: (CommandControlRequest) -> Unit,
    compact: Boolean,
    modifier: Modifier = Modifier,
) {
    Column(
        modifier,
        verticalArrangement = Arrangement.spacedBy(if (compact) 6.dp else 8.dp),
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
                "MORE ↓",
                style = chromeStyle(9f, FontWeight.Bold),
                color = LiveDesign.muted,
                modifier =
                    Modifier
                        .align(Alignment.BottomCenter)
                        .padding(bottom = 3.dp)
                        .semantics {
                            contentDescription =
                                "More command controls below. Swipe up to reveal them."
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
    Column(
        Modifier.fillMaxWidth(),
        verticalArrangement = Arrangement.spacedBy(if (compact) 2.dp else 4.dp),
    ) {
        Text(
            section.title.uppercase(),
            style = chromeStyle(if (compact) 8.5f else 9.5f, FontWeight.Bold),
            color = LiveDesign.faint,
            modifier = Modifier.padding(start = 2.dp),
        )
        section.cells.chunked(2).forEach { row ->
            Row(
                Modifier.fillMaxWidth(),
                horizontalArrangement = Arrangement.spacedBy(6.dp),
            ) {
                row.forEach { cell ->
                    CommandSmallTile(
                        cell = cell,
                        controlsEnabled = controlsEnabled,
                        pendingControl = pendingControl,
                        onOpenControl = onOpenControl,
                        compact = compact,
                        modifier = Modifier.weight(1f),
                    )
                }
                repeat(2 - row.size) { Box(Modifier.weight(1f)) }
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
    val applyingThisControl = request?.control == pendingControl
    val enabled = request != null && controlsEnabled && !pending
    val description =
        buildString {
            append(cell.title)
            append(": ")
            append(cell.value)
            when {
                applyingThisControl -> append(". Applying change.")
                pending -> append(". Another control is being applied.")
                request == null -> append(". ${cell.unavailableReason ?: "Read-only."}")
                !controlsEnabled -> append(". Controls are locked.")
                else -> append(". Double tap to change.")
            }
        }
    Column(
        modifier
            .height(
                if (compact) COMMAND_COMPACT_SIDE_TILE_HEIGHT else COMMAND_PORTRAIT_SIDE_TILE_HEIGHT,
            )
            .background(LiveDesign.surface, ChromeShape)
            .border(1.dp, LiveDesign.hairline, ChromeShape)
            .semantics(mergeDescendants = true) {
                contentDescription = description
                if (!enabled) disabled()
            }
            .combinedClickable(
                enabled = enabled,
                onClickLabel = "Change ${cell.title}",
                onClick = { request?.let(onOpenControl) },
            )
            .padding(horizontal = 8.dp, vertical = if (compact) 3.dp else 5.dp),
        verticalArrangement = Arrangement.spacedBy(if (compact) 1.dp else 2.dp),
    ) {
        Text(
            cell.title.uppercase(),
            style = chromeStyle(if (compact) 7.5f else 8.5f, FontWeight.Bold),
            color = LiveDesign.muted,
            maxLines = 1,
            overflow = TextOverflow.Clip,
        )
        Text(
            cell.value,
            style = chromeStyle(if (compact) 11.5f else 13f, FontWeight.Medium, mono = true),
            color = if (enabled) LiveDesign.text else LiveDesign.muted,
            maxLines = 1,
            overflow = TextOverflow.Clip,
        )
    }
}

/** Accessible picker for the fixed set of Swift-validated control labels. */
@Composable
internal fun CommandControlDialog(
    request: CommandControlRequest,
    controlsEnabled: Boolean,
    pendingControl: CameraControl?,
    feedback: CommandControlFeedback?,
    onSelect: (String) -> Unit,
    onDismiss: () -> Unit,
) {
    val pending = pendingControl != null
    val options = commandControlOptions(request, pendingControl, controlsEnabled)
    AlertDialog(
        onDismissRequest = {
            if (!pending) onDismiss()
        },
        title = {
            Column(verticalArrangement = Arrangement.spacedBy(3.dp)) {
                Text(request.title)
                Text(
                    "Current: ${request.currentValue}",
                    style = chromeStyle(13f, FontWeight.Medium, mono = true),
                    color = LiveDesign.muted,
                )
            }
        },
        text = {
            Column(
                Modifier.heightIn(max = 320.dp).verticalScroll(rememberScrollState()),
                verticalArrangement = Arrangement.spacedBy(4.dp),
            ) {
                if (feedback != null) {
                    Text(
                        feedback.message,
                        color = if (feedback.isError) LiveDesign.rec else LiveDesign.good,
                        style = chromeStyle(12f, FontWeight.Medium),
                        modifier = Modifier.padding(bottom = 4.dp),
                    )
                }
                if (!controlsEnabled) {
                    Text(
                        "Controls are unavailable until the camera is connected and unlocked.",
                        color = LiveDesign.muted,
                        style = chromeStyle(12f, FontWeight.Medium),
                        modifier = Modifier.padding(bottom = 4.dp),
                    )
                }
                options.forEach { option ->
                    TextButton(
                        onClick = { onSelect(option.label) },
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
                                        "${request.title} ${option.label}" +
                                            if (option.selected) ", currently selected" else ""
                                },
                    ) {
                        Text(
                            option.label,
                            style = chromeStyle(16f, FontWeight.Medium, mono = true),
                            color = if (option.selected) LiveDesign.accent else LiveDesign.text,
                        )
                    }
                }
                if (pending) {
                    Text(
                        "Applying change…",
                        style = chromeStyle(12f, FontWeight.Medium),
                        color = LiveDesign.muted,
                    )
                }
            }
        },
        confirmButton = {
            TextButton(onClick = onDismiss, enabled = !pending) { Text("Done") }
        },
    )
}
