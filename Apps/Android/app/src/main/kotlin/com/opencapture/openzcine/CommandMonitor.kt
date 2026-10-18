package com.opencapture.openzcine

import com.opencapture.opencine.nikon.WhiteBalanceTint
import com.opencapture.opencine.nikon.ShutterPickerPolicy
import android.content.Context
import android.content.SharedPreferences
import androidx.compose.runtime.Composable
import androidx.compose.ui.res.stringResource
import com.opencapture.monitorui.MonitorCommandDashboard
import com.opencapture.monitorui.MonitorCommandHealth
import com.opencapture.monitorui.MonitorCommandSection
import com.opencapture.monitorui.MonitorCommandTile
import com.opencapture.monitorui.monitorCommandTileOrder
import com.opencapture.monitorui.moveMonitorCommandTile
import com.opencapture.opencine.appkit.MonitorCommandTileOrderPreferences
import com.opencapture.opencine.appkit.LocalMonitorCaptureCommandEnabled
import com.opencapture.opencine.cameracontrols.LadderSheet
import com.opencapture.opencine.cameracontrols.IndependentSettingRow
import com.opencapture.opencine.cameracontrols.MonitorIndependentSettingsPanel
import androidx.compose.foundation.layout.Column
import androidx.compose.material3.Text
import com.opencapture.opencine.vocabulary.LadderSheetPresentation
import com.opencapture.opencine.vocabulary.LadderTab
import com.opencapture.opencine.nikon.CameraControl
import com.opencapture.opencine.nikon.MonitorTextFormat
import com.opencapture.opencine.vocabulary.CaptureLadder
import com.opencapture.opencine.vocabulary.CaptureTint
import com.opencapture.opencine.nikon.CameraPropertyRefreshFailure
import com.opencapture.opencine.nikon.CameraPropertyRefreshStatus
import com.opencapture.opencine.nikon.CameraPropertySnapshot
import com.opencapture.opencine.nikon.CameraSessionState
import com.opencapture.opencine.nikon.CameraShutterMode
import com.opencapture.opencine.nikon.CameraTemperatureStatus
import com.opencapture.opencine.nikon.CodecBitDepthOption
import com.opencapture.opencine.nikon.LiveFrameTimecode
import com.opencapture.opencine.nikon.IsoPickerPolicy
import com.opencapture.opencine.nikon.WbPickerPolicy
import com.opencapture.opencine.nikon.NikonDescriptorEvidence
import com.opencapture.opencine.nikon.NikonDescriptorForm
import com.opencapture.opencine.nikon.NikonDescriptorReadOutcome
import com.opencapture.opencine.core.SettingAccess
import com.opencapture.opencine.core.SupportStatus

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

    /** Retained in the full saved order for old builds; its row opens from STABILIZATION. */
    ELECTRONIC_VR,
}

/** The DISP 3 order in the store and key existing installs already hold (Core stores enum names). */
internal fun commandTileOrderStore(context: Context): MonitorCommandTileOrderPreferences<CommandTileKind> =
    commandTileOrderStore(context.getSharedPreferences("openzcine.command-dashboard", Context.MODE_PRIVATE))

internal fun commandTileOrderStore(preferences: SharedPreferences): MonitorCommandTileOrderPreferences<CommandTileKind> =
    MonitorCommandTileOrderPreferences(preferences, "display.commandGrid.order.v1", CommandTileKind.entries)

/** Removes duplicates and retains newly introduced tiles at the end. */
internal fun normalizeCommandTileOrder(order: List<CommandTileKind>): List<CommandTileKind> =
    monitorCommandTileOrder(order, CommandTileKind.entries)

/** Only the rendered projection hides e-VR; the persisted full list retains its identity. */
internal fun visibleCommandTileOrder(order: List<CommandTileKind>): List<CommandTileKind> =
    normalizeCommandTileOrder(order).filter { it != CommandTileKind.ELECTRONIC_VR }

/** Mirrors the accepted Swift hidden-slot move: visible indices never move the hidden identity. */
internal fun moveCommandTile(order: List<CommandTileKind>, kind: CommandTileKind, targetIndex: Int): List<CommandTileKind> {
    val full = normalizeCommandTileOrder(order)
    val visible = visibleCommandTileOrder(full)
    val moved = moveMonitorCommandTile(visible, kind, targetIndex, visible).iterator()
    return full.map { if (it == CommandTileKind.ELECTRONIC_VR) it else moved.next() }
}

/** App-owned presentation route; a group is never one camera control write. */
internal sealed interface CommandPanelRequest

internal data class CommandStabilizationRequest(
    val rows: List<IndependentSettingRow<CameraControl, CommandControlRequest>>,
    val descriptors: Map<CameraControl, NikonDescriptorEvidence> = emptyMap(),
) : CommandPanelRequest

/** One semantically validated intent passed from the Compose sheet to the session control API. */
internal data class CommandControlRequest(
    val title: String,
    val control: CameraControl,
    val currentValue: String,
    val options: List<String>,
    /**
     * Bit depths flanking [currentValue] when the core reported a depth choice for that codec
     * row. Empty for every other control and for codecs the body advertises at one depth.
     */
    val bitDepths: List<CodecBitDepthOption> = emptyList(),
    /** Caption of the depth the body is recording at, so the pair can fill the active side. */
    val bitDepthSelection: String? = null,
) : CommandPanelRequest

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
internal typealias CommandTilePresentation = MonitorCommandTile<CommandTileKind, CommandControlRequest>

/** Sections of the iOS command side column (Image / Focus / Audio / Monitor). */
internal enum class CommandSideSectionKind {
    IMAGE,
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
    val health: MonitorCommandHealth,
    val frameRate: String,
    val refreshSummary: String,
    val stabilization: CommandStabilizationRequest = CommandStabilizationRequest(emptyList()),
) {
    /** The side column as the shared dashboard draws it. */
    val sections: List<MonitorCommandSection<CommandTileKind, CommandControlRequest>>
        get() = sideSections.map { MonitorCommandSection(it.title, it.cells) }

    // Capture-strip consumers keep the existing single-control projections above. Only the
    // dashboard's generic presentation slot carries a grouped route.
    val panelTiles: List<MonitorCommandTile<CommandTileKind, CommandPanelRequest>>
        get() = tiles.map { tile ->
            val request = if (tile.kind == CommandTileKind.STABILIZATION) {
                stabilization.takeIf { it.rows.any { row -> row.request != null } }
            } else tile.request
            tile.forPanel(request)
        }

    val panelSections: List<MonitorCommandSection<CommandTileKind, CommandPanelRequest>>
        get() = sideSections.map { section ->
            MonitorCommandSection(section.title, section.cells.map { it.forPanel(it.request) })
        }
}

private fun CommandTilePresentation.forPanel(request: CommandPanelRequest?) =
    MonitorCommandTile(kind, title, value, request,
        if (request == null) unavailableReason else null, amber, muted)

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
    // The cinema dashboard wants the MOVIE side; the accessor only falls back to the stills one
    // for a body that has never pushed a movie value at all.
    val whiteBalanceMode =
        snapshot.activeWhiteBalanceMode(photography = false).monitorValueOrNull()
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
            request =
                CommandControlRequest(
                    title,
                    control,
                    currentValue,
                    options,
                    // Depth buttons belong to the codec drum only, and only to the row the core
                    // grouped as a depth choice — never to resolution.
                    bitDepths =
                        if (control == CameraControl.CODEC) {
                            capabilities.codecBitDepths
                        } else {
                            emptyList()
                        },
                    bitDepthSelection =
                        snapshot.codecBitDepth.takeIf { control == CameraControl.CODEC },
                ),
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
                    // The body's own program enum, in its order; the ladder below is only a
                    // fallback and deliberately holds no U banks (#274).
                    capabilities.options(CameraControl.EXPOSURE_MODE)
                        .ifEmpty { EXPOSURE_MODE_OPTIONS },
                ),
            CommandTileKind.ISO to
                run {
                    val isoValue = snapshot.iso?.takeIf { it > 0 }?.toString()
                    val cameraIso = capabilities.options(CameraControl.ISO)
                    // Always keep the policy ladder available so Auto ISO codecs never
                    // padlock the drum — operators exit auto by choosing a value.
                    // A live readout with no advertised enum still opens the same ladder the
                    // capture bar uses. Leaving the tile request-less made ISO a dead cell on
                    // the command grid while the strip could change it.
                    val isoOptions =
                        cameraIso.ifEmpty {
                            if (isoValue != null) IsoPickerPolicy.unifiedOptions else emptyList()
                        }
                    val displayValue =
                        when {
                            // Show the body's working ISO while Auto is on (drum is locked).
                            IsoPickerPolicy.isAutoISOActive(snapshot.isoAuto, codec ?: "") ->
                                isoValue?.let { "A$it" } ?: "Auto"
                            else -> isoValue
                        }
                    editable(
                        kind = CommandTileKind.ISO,
                        title = strings.resolve(R.string.command_title_iso),
                        value = displayValue,
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
                    // The facade already substitutes the lens ladder where the body accepts it
                    // and fails closed otherwise, so an empty list stays read-only here.
                    val irisOptions = capabilities.options(CameraControl.IRIS)
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
                run {
                    val advertised = capabilities.options(CameraControl.WHITE_BALANCE)
                    val live = whiteBalance
                    val options =
                        advertised.ifEmpty {
                            if (live == null) {
                                emptyList()
                            } else {
                                WbPickerPolicy.kelvinOptions(emptyList(), live) +
                                    WbPickerPolicy.presetOptions(emptyList())
                            }
                        }
                    if (options.isEmpty()) {
                        readOnly(
                            CommandTileKind.WHITE_BALANCE,
                            strings.resolve(R.string.command_title_white_balance),
                            live,
                            strings.resolve(R.string.command_reason_white_balance),
                        )
                    } else {
                        editable(
                            kind = CommandTileKind.WHITE_BALANCE,
                            title = strings.resolve(R.string.command_title_white_balance),
                            value = live,
                            control = CameraControl.WHITE_BALANCE,
                            options = options,
                        )
                    }
                },
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
                    writable = !capabilities.vibrationReductionDescriptor.hasReadOnlyDescriptor(),
                ).copy(
                    title = strings.resolve(R.string.command_title_vr_combined),
                    value = stabilization ?: "—",
                ),
            // Keep the existing independent projection and codec refusal for the grouped row.
            CommandTileKind.ELECTRONIC_VR to
                advertisedEditable(
                    kind = CommandTileKind.ELECTRONIC_VR,
                    title = strings.resolve(R.string.command_title_evr),
                    value = snapshot.electronicVr,
                    control = CameraControl.ELECTRONIC_VR,
                    blockedReason = strings.resolve(R.string.command_reason_evr),
                    writable = electronicVRAllowsCodec(codec) &&
                        !capabilities.electronicVrDescriptor.hasReadOnlyDescriptor(),
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
        tiles = visibleCommandTileOrder(tileOrder).mapNotNull(tilesByKind::get),
        stabilization = CommandStabilizationRequest(
            listOf(CommandTileKind.STABILIZATION, CommandTileKind.ELECTRONIC_VR).map { kind ->
                val tile = tilesByKind.getValue(kind)
                val control = if (kind == CommandTileKind.STABILIZATION) CameraControl.VIBRATION_REDUCTION else CameraControl.ELECTRONIC_VR
                IndependentSettingRow(
                    id = control,
                    title = strings.resolve(if (kind == CommandTileKind.STABILIZATION) R.string.command_title_vr else R.string.command_title_evr),
                    options = capabilities.options(control),
                    current = (if (kind == CommandTileKind.STABILIZATION) snapshot.vibrationReduction else snapshot.electronicVr).monitorValueOrNull(),
                    request = tile.request,
                    unavailableReason = tile.unavailableReason,
                )
            },
            descriptors = mapOf(
                CameraControl.VIBRATION_REDUCTION to capabilities.vibrationReductionDescriptor,
                CameraControl.ELECTRONIC_VR to capabilities.electronicVrDescriptor,
            ),
        ),
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
        health =
            MonitorCommandHealth(
                temperature = commandTemperature(snapshot.temperatureStatus, strings),
                temperatureOk = snapshot.temperatureStatus == CameraTemperatureStatus.NORMAL,
                storage = monitorStorageLabel(snapshot.storage),
                camera = camera,
                lens = snapshot.lens.monitorValueOrNull() ?: UNAVAILABLE_MONITOR_VALUE,
            ),
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

/**
 * Whether the active codec lets electronic VR be written. The ZR cannot apply e-VR to a RAW
 * stream, so iOS disables the e-VR row on `MonitorTextFormat.isRawCodec`
 * (ios/Runner/MonitorPanels.swift:1566-1568); the RAW / R3D substring test is transcribed from
 * the shared core (Sources/OpenZCineCore/MonitorTextFormat.swift:45) so both shells classify the
 * same string the same way, and it holds for the body's verbatim name and the shortened label.
 *
 * A codec that has not been read back yet fails closed: the Android facade already withholds the
 * e-VR enum for an unrecognized codec (Sources/OpenZCineAndroidFacade/PTPIPClientSession.swift:
 * 439-442), and this gate must never be looser than the wire it guards.
 */
internal fun electronicVRAllowsCodec(codec: String?): Boolean =
    codec?.takeIf { it.isNotBlank() }?.let { !MonitorTextFormat.isRawCodec(it) } ?: false

/** Latest parsed access wins; a failed attempt keeps the retained descriptor's access fact. */
private fun NikonDescriptorEvidence.hasReadOnlyDescriptor(): Boolean {
    fun com.opencapture.opencine.nikon.NikonDescriptorObservation.isParsed(): Boolean =
        outcome == NikonDescriptorReadOutcome.DESCRIBED && form != NikonDescriptorForm.UNKNOWN &&
            capability.support == SupportStatus.SUPPORTED
    val actual = latestAttempt.takeIf { it.isParsed() }
        ?: lastValidObservation?.takeIf { it.isParsed() } ?: observation
    return actual.isParsed() && actual.capability.access == SettingAccess.READ_ONLY
}

/** True only when a completed property refresh reflects the accepted control write. */
internal fun cameraPropertyConfirmsSelection(
    snapshot: CameraPropertySnapshot,
    control: CameraControl,
    label: String,
): Boolean =
    when (control) {
        CameraControl.ISO -> snapshot.iso?.toString() == label
        CameraControl.ISO_AUTO ->
            snapshot.isoAuto?.let { auto ->
                (if (auto) IsoPickerPolicy.AUTO_ISO_ON_LABEL else IsoPickerPolicy.AUTO_ISO_OFF_LABEL) ==
                    label
            } == true
        CameraControl.SHUTTER ->
            when (snapshot.shutterMode) {
                CameraShutterMode.ANGLE -> snapshot.shutterAngle == label
                CameraShutterMode.SPEED -> snapshot.shutterSpeed == label
                null -> false
            }
        CameraControl.IRIS -> snapshot.iris == label
        CameraControl.WHITE_BALANCE ->
            if (label.endsWith("K")) {
                snapshot.activeWhiteBalanceMode(photography = false) == COLOR_TEMPERATURE_MODE &&
                    snapshot.whiteBalanceKelvin?.let { "${it}K" } == label
            } else {
                snapshot.activeWhiteBalanceMode(photography = false) == label
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
                    MonitorTextFormat.resolutionLabel(snapshot.resolution.monitorValueOrNull(), snapshot.frameRate ?: 0, ""),
                    label,
                )
            }
        }
        CameraControl.CODEC ->
            recordingModeLabelsMatch(snapshot.codecSelection, label) ||
                recordingModeLabelsMatch(
                    snapshot.codec?.let(MonitorTextFormat::codecShortLabel),
                    label,
                )
        CameraControl.VIBRATION_REDUCTION -> snapshot.vibrationReduction == label
        CameraControl.ELECTRONIC_VR -> snapshot.electronicVr == label
        // Photo mode: the stills poll writes these properties into the same
        // snapshot readouts the photo strip renders.
        CameraControl.STILL_ISO -> snapshot.iso?.toString() == label
        CameraControl.STILL_ISO_AUTO ->
            snapshot.isoAuto?.let { auto -> (if (auto) "On" else "Off") == label } == true
        CameraControl.STILL_SHUTTER -> snapshot.shutterSpeed == label
        CameraControl.STILL_IRIS -> snapshot.iris == label
        CameraControl.STILL_DRIVE -> snapshot.stillCaptureMode == label
        CameraControl.STILL_FOCUS_MODE -> snapshot.activeFocusMode(photography = true) == label
        CameraControl.STILL_FOCUS_AREA -> snapshot.focusArea == label
        CameraControl.STILL_FOCUS_SUBJECT -> snapshot.focusSubject == label
        CameraControl.STILL_METER -> snapshot.meteringMode == label
        CameraControl.STILL_IMAGE_AREA -> snapshot.imageArea == label
        CameraControl.STILL_IMAGE_SIZE -> snapshot.imageSize == label
        CameraControl.STILL_QUALITY -> snapshot.compression == label
        CameraControl.STILL_RAW_COMPRESSION -> snapshot.rawCompression == label
        CameraControl.STILL_USER_MODE_PROGRAM -> snapshot.userModeProgram == label
        CameraControl.STILL_PICTURE_CONTROL -> snapshot.pictureControl == label
        CameraControl.MOVIE_TONE -> snapshot.movieTone == label
    }

/* Every label below is accepted by `PTPCameraPropertyWrite` in the shared Swift core. */
private const val COLOR_TEMPERATURE_MODE = "Color temp"

/**
 * Conservative MODE fallback for a body that has not advertised its
 * `ExposureProgramMode` enum. No U banks — a body that has them says so, and
 * inferring them offered a Zf three user modes it does not have (#274).
 */
private val EXPOSURE_MODE_OPTIONS = listOf("Auto", "P", "A", "S", "M")

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
 * DISP 3: the shared command dashboard over the Nikon projection. A tile is "applying" while
 * its [CameraControl] is the pending write; the health strip ends in the shared link gauge.
 */
@Composable
internal fun CommandDashboard(
    presentation: CommandDashboardPresentation,
    portrait: Boolean,
    controlsEnabled: Boolean,
    pendingControl: CameraControl?,
    onOpenControl: (CommandPanelRequest) -> Unit,
    onMoveTile: (CommandTileKind, Int) -> Unit,
    liveFps: String,
    signalBars: Int,
) {
    MonitorCommandDashboard(
        presentation.panelTiles, presentation.panelSections, presentation.health, portrait, controlsEnabled,
        pending = pendingControl != null,
        applying = { request -> when (request) {
            is CommandControlRequest -> request.control == pendingControl
            is CommandStabilizationRequest -> request.rows.any { it.request?.control == pendingControl && pendingControl != null }
        } },
        onOpenControl = onOpenControl,
        onMoveTile = onMoveTile,
    ) {
        // The link gauge every app's status bar draws (tap toggles bars and fps).
        com.opencapture.monitorui.MonitorTelemetry(signalBars, liveFps, emptyList(), horizontal = true, showsPower = false)
    }
}

/** Actual shared row controls; the live composition supplies popup chrome and native dispatch. */
@Composable
internal fun CommandStabilizationPanel(
    request: CommandStabilizationRequest,
    controlsEnabled: Boolean,
    currentSource: () -> Boolean,
    feedback: CommandControlFeedback?,
    onSelect: (CommandControlRequest, String) -> Unit,
    onUnavailable: (CameraControl, String?) -> Unit,
) {
    val commandEnabled = LocalMonitorCaptureCommandEnabled.current
    Column {
        MonitorIndependentSettingsPanel(request.rows, controlsEnabled && commandEnabled, currentSource,
            onSelect = { target, label -> if (label.isNotBlank()) onSelect(target, label) },
            onUnavailable = onUnavailable)
        feedback?.let { Text(it.message) }
    }
}

/**
 * One command tile as a single-tab ladder. Tint uses the shared pad.
 * The tab does not apply its value when the dialog opens.
 */
internal fun commandLadderPresentation(
    request: CommandControlRequest,
    subtitle: String = request.currentValue,
): LadderSheetPresentation<CameraControl> {
    val tint = if (request.control == CameraControl.WHITE_BALANCE_TINT) {
        val (amber, green) = WhiteBalanceTint.cellsFromLabel(request.currentValue.ifBlank { "Neutral" })
        CaptureTint(greenMagenta = green, amberBlue = amber, range = WhiteBalanceTint.cellRange)
    } else {
        null
    }
    return LadderSheetPresentation(
        title = request.title,
        subtitle = subtitle,
        tabs = listOf(
            LadderTab(
                label = request.title,
                key = request.control,
                ladder = CaptureLadder(current = request.currentValue, values = request.options),
                applyOnActivate = false,
                tint = tint,
            ),
        ),
    )
}

/** Native command ladder; the live composition supplies the common popup chrome. */
@Composable
internal fun CommandControlDialog(
    request: CommandControlRequest,
    controlsEnabled: Boolean,
    pendingControl: CameraControl?,
    feedback: CommandControlFeedback?,
    onSelect: (String) -> Unit,
    onDismiss: () -> Unit,
    chromeless: Boolean = false,
) {
    // An in-flight write stays interactive. pendingControl names that write, and it is not a lock.
    val interactive = controlsEnabled &&
        commandControlOptions(request, pendingControl, controlsEnabled).all { it.enabled }
    val subtitle = stringResource(R.string.command_current_value, request.currentValue)

    LadderSheet(
        presentation = commandLadderPresentation(request, subtitle),
        enabled = interactive,
        onWrite = { write ->
            if (write.value.isNotBlank()) onSelect(write.value)
        },
        onClose = onDismiss,
        chromeless = chromeless,
        error = feedback?.takeIf { it.isError }?.message,
        unavailable = if (interactive) null else stringResource(R.string.camera_controls_unavailable),
        tintLabel = { tint -> WhiteBalanceTint.label(tint.amberBlue ?: 0, tint.greenMagenta) },
        tintHelp = stringResource(R.string.camera_wb_tint_steps_help) + "\n" +
            stringResource(R.string.camera_wb_tint_double_tap_help),
    )
}
