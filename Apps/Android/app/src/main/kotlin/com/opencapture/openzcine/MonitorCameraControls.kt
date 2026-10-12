package com.opencapture.openzcine

import com.opencapture.opencine.nikon.WhiteBalanceTint
import com.opencapture.opencine.nikon.FocusPickerPolicy
import com.opencapture.opencine.nikon.ShutterPickerPolicy
import com.opencapture.opencine.nikon.StillPickerLadders
import com.opencapture.monitorui.settings.MonitorSettingsSwitchGraphic
import com.opencapture.opencine.appkit.MonitorControlModel
import com.opencapture.opencine.appkit.MonitorCaptureField
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.gestures.detectDragGestures
import androidx.compose.foundation.gestures.detectTapGestures
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.offset
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.disabled
import androidx.compose.ui.semantics.role
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.semantics.toggleableState
import androidx.compose.ui.state.ToggleableState
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import com.opencapture.opencine.nikon.CameraControl
import com.opencapture.opencine.nikonwire.MonitorRelayWire
import com.opencapture.opencine.nikon.IsoPickerPolicy
import com.opencapture.opencine.nikon.WbPickerPolicy
import com.opencapture.opencine.cameracontrols.chromeClickable
import com.opencapture.monitorui.MonitorMaterial
import com.opencapture.monitorui.monitorMaterial


/** Stable identities for the camera controls surrounding iOS live view. */
internal enum class MonitorPickerKind {
    ISO,
    SHUTTER,
    IRIS,
    FOCUS,
    WHITE_BALANCE,
    RESOLUTION,
    CODEC,

    // Photography-only pickers (iOS `CameraPicker.isStillPicker` set; the
    // shared kinds above are reused by the stills strip with stills writes).
    MODE,
    DRIVE,
    METER,
    PROFILE,
    SIZE,
    QUALITY,
}

/** One typed control tab inside an in-monitor picker. */
internal data class MonitorPickerModePresentation(
    val label: String,
    val request: CommandControlRequest,
    /** Optional mono detail under the tab title (iOS ISO `800 · 200-3200`). */
    val detail: String? = null,
    /**
     * Optional write fired when this tab becomes active (iOS dual-base ISO
     * switches `movieBaseISO` before the circuit's ISO drum is used; Auto ISO
     * switches exposure mode).
     */
    val activateRequest: CommandControlRequest? = null,
    /**
     * When false, activating the tab runs [activateRequest] only (Auto On).
     * When true (default), also applies the drum [request] after activate.
     */
    val applyValueOnActivate: Boolean = true,
    /** Drum star markers for this tab (native base ISOs). */
    val markedValues: Set<String> = emptySet(),
    /**
     * Grays this tab out entirely (iOS `pickerModeDisabled`): a U-bank inner
     * program outside the banks, mutually-exclusive photo timers, or Manual
     * ISO in a full-auto program.
     */
    val disabled: Boolean = false,
    /**
     * Freezes only this tab's value drum while it tracks the camera's live
     * pick (photo ISO's Auto tab). Tabs stay interactive.
     */
    val drumLocked: Boolean = false,
    /** Shows the photo timers' `[−] n [+]` shots stepper under the drum. */
    val showsTimerShots: Boolean = false,
)

/** Camera-backed picker shown over live view. */
internal data class MonitorPickerPresentation(
    val kind: MonitorPickerKind,
    val title: String,
    val subtitle: String,
    val modes: List<MonitorPickerModePresentation>,
    /** Which mode tab to open on (iOS dual-base follows `movieBaseISO`). */
    val initialModeIndex: Int = 0,
    /**
     * Dim drum + mode bar and show [lockBanner] (iOS shutter Control-lock /
     * ISO-while-recording).
     */
    val interactionLocked: Boolean = false,
    val lockBanner: String? = null,
    /**
     * Dim/disable only the value drum (Auto ISO On). Mode tabs stay interactive so the
     * operator can switch to Auto Off / Manual.
     */
    val drumInteractionLocked: Boolean = false,
    val drumLockBanner: String? = null,
)

/** One readout in the live monitor's capture strip. */
internal data class MonitorCaptureSettingPresentation(
    val kind: MonitorPickerKind,
    val label: String,
    val value: String,
    val widestValue: String,
    val picker: MonitorPickerPresentation?,
    val unavailableReason: String?,
    /**
     * Camera Control-lock or rejected write (iOS `lockedControls` / lock glyph next
     * to the label).
     */
    val controlLocked: Boolean = false,
    /**
     * Dimmed readout: shutter lock engaged or ISO locked while recording R3D
     * (iOS 0.55 opacity).
     */
    val dimmed: Boolean = false,
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
        // Only open when the tile has a camera-backed request with real options.
        // Static fallback ladders are not writable and must not seed the drum.
        val cameraRequest = tile?.request?.takeIf { it.options.isNotEmpty() } ?: return null
        val options = cameraRequest.options
        val display = tile.value?.takeIf { it != "—" }
        val current =
            matchRecordingModeOption(cameraRequest.currentValue, options)
                ?: matchRecordingModeOption(display, options)
                ?: cameraRequest.currentValue.takeIf { it in options }
                ?: options.firstOrNull()
                ?: return null
        val request = cameraRequest.copy(currentValue = current, options = options)
        val title = tile.title
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
    /** Authoritative camera TV-lock when known; dims the shutter drum like iOS. */
    shutterLockedOnCamera: Boolean? = null,
    /** Movie ISO auto (`MovISOAutoControl`); drives Auto On/Off tab for non-R3D NE. */
    isoAuto: Boolean? = null,
    /** Exposure program mode (M/P/A/S/…); Auto Off / manual ISO only in M. */
    exposureMode: String? = null,
): List<MonitorCaptureSettingPresentation> {
    val primary = dashboard.tiles.associateBy(CommandTilePresentation::kind)
    val focus =
        dashboard.sideSections.firstOrNull { it.kind == CommandSideSectionKind.FOCUS }?.cells.orEmpty()
    // Capture-bar exposure helpers live off the DISP 3 side column (iOS CommandSideColumn
    // has no Exposure section); still project Base ISO / shutter mode / WB tint here.
    val exposure = dashboard.captureExposureCells

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
        controlLocked: Boolean = false,
        dimmed: Boolean = false,
    ): MonitorCaptureSettingPresentation {
        val modes = listOfNotNull(mode(label, tile))
        return MonitorCaptureSettingPresentation(
            kind = kind,
            label = label,
            value = captureBarDisplayValue(tile?.value ?: "—"),
            widestValue = widestValue,
            picker =
                modes.takeIf(List<MonitorPickerModePresentation>::isNotEmpty)?.let {
                    MonitorPickerPresentation(kind, label, subtitle, it)
                },
            unavailableReason = tile?.unavailableReason,
            controlLocked = controlLocked,
            dimmed = dimmed,
        )
    }

    fun multi(
        kind: MonitorPickerKind,
        label: String,
        widestValue: String,
        subtitle: String,
        valueTile: CommandTilePresentation?,
        modes: List<MonitorPickerModePresentation>,
        controlLocked: Boolean = false,
        dimmed: Boolean = false,
    ): MonitorCaptureSettingPresentation =
        MonitorCaptureSettingPresentation(
            kind = kind,
            label = label,
            value = captureBarDisplayValue(valueTile?.value ?: "—"),
            widestValue = widestValue,
            picker =
                modes.takeIf(List<MonitorPickerModePresentation>::isNotEmpty)?.let {
                    MonitorPickerPresentation(kind, label, subtitle, it)
                },
            unavailableReason = valueTile?.unavailableReason,
            controlLocked = controlLocked,
            dimmed = dimmed,
        )

    val focusValue = focus.getOrNull(0)?.value ?: "—"
    val focusPresentation =
        focusPickerPresentation(
            afModeTile = focus.getOrNull(0),
            areaTile = focus.getOrNull(1),
            subjectTile = focus.getOrNull(2),
            strings = strings,
        )
    val isoTile = primary[CommandTileKind.ISO]
    val shutterTile = primary[CommandTileKind.SHUTTER]
    // Codec drives dual-base vs unified ISO layout (iOS ISOPickerPolicy).
    val codec =
        primary[CommandTileKind.CODEC]?.value?.takeIf { it != "—" }.orEmpty()
    // Padlock only for true recording lock — not "wait for base/codec" while the
    // dual-base / unified policy ladder is still available to write.
    val isoLocked =
        isoTile?.unavailableReason?.contains("recording", ignoreCase = true) == true &&
            isoTile.request == null &&
            isoTile.value != "—"
    val shutterLocked =
        shutterTile?.request == null &&
            shutterTile?.unavailableReason != null &&
            shutterTile.value != "—" &&
            shutterTile.unavailableReason?.contains("locked", ignoreCase = true) == true
    val isoPresentation =
        isoPickerPresentation(
            isoTile = isoTile,
            codec = codec,
            baseIsoTile = exposure.getOrNull(0),
            isoAuto = isoAuto,
            exposureMode = exposureMode,
            strings = strings,
        )
    val shutterPresentation =
        shutterPickerPresentation(
            shutterTile = shutterTile,
            shutterModeTile = exposure.getOrNull(1),
            strings = strings,
            // Prefer the camera property; fall back to the command tile's locked reason so
            // unit tests / partial projections still dim the drum correctly.
            shutterLocked =
                shutterLockedOnCamera
                    ?: (
                        shutterTile?.unavailableReason
                            ?.contains("locked", ignoreCase = true) == true
                    ),
        )
    // iOS CameraDisplayState.preview order: ISO · SHUTTER · IRIS · WB · FOCUS.
    return listOf(
        MonitorCaptureSettingPresentation(
            kind = MonitorPickerKind.ISO,
            label = strings.resolve(R.string.camera_label_iso),
            value = captureBarDisplayValue(isoTile?.value ?: "—"),
            widestValue = "25600",
            picker = isoPresentation,
            unavailableReason = isoTile?.unavailableReason,
            controlLocked = isoLocked,
            dimmed = isoLocked,
        ),
        MonitorCaptureSettingPresentation(
            kind = MonitorPickerKind.SHUTTER,
            label = strings.resolve(R.string.camera_label_shutter),
            value = captureBarDisplayValue(shutterTile?.value ?: "—"),
            widestValue = "1/16000",
            picker = shutterPresentation,
            unavailableReason = shutterTile?.unavailableReason,
            controlLocked = shutterLocked,
            dimmed = shutterLocked,
        ),
        run {
            val irisTile = primary[CommandTileKind.IRIS]
            // Only the f-numbers the facade reports. Core already falls back to the lens ladder
            // where the body allows that write; a body that advertises none leaves IRIS read-only.
            val presentation =
                irisTile?.request?.takeIf { it.options.isNotEmpty() }?.let { request ->
                    MonitorPickerPresentation(
                        kind = MonitorPickerKind.IRIS,
                        title = strings.resolve(R.string.camera_label_iris),
                        subtitle = strings.resolve(R.string.camera_subtitle_iris),
                        modes = listOf(MonitorPickerModePresentation(request.title, request)),
                    )
                }
            MonitorCaptureSettingPresentation(
                kind = MonitorPickerKind.IRIS,
                label = strings.resolve(R.string.camera_label_iris),
                value = captureBarDisplayValue(irisTile?.value ?: "—"),
                widestValue = "f/2.8",
                picker = presentation,
                unavailableReason = if (presentation == null) irisTile?.unavailableReason else null,
            )
        },
        run {
            val wbTile = primary[CommandTileKind.WHITE_BALANCE]
            val tintTile = exposure.getOrNull(3)
            val wbPresentation = wbPickerPresentation(wbTile, tintTile, strings)
            MonitorCaptureSettingPresentation(
                kind = MonitorPickerKind.WHITE_BALANCE,
                label = strings.resolve(R.string.camera_label_wb),
                value = captureBarDisplayValue(wbTile?.value ?: "—"),
                widestValue = "10000K",
                picker = wbPresentation,
                unavailableReason = wbTile?.unavailableReason,
            )
        },
        MonitorCaptureSettingPresentation(
            kind = MonitorPickerKind.FOCUS,
            label = strings.resolve(R.string.camera_label_focus),
            value = captureBarDisplayValue(focusValue),
            widestValue = "Wide-L",
            picker = focusPresentation,
            unavailableReason = focus.getOrNull(0)?.unavailableReason,
        ),
    )
}

/**
 * iOS `CameraPicker.focus.modes` — three independent tabs (AF Mode / Area /
 * Subject), each its own camera control. Ladders match iOS; multi-value camera
 * enums merge in extras without replacing the full AF Mode set.
 */
internal fun focusPickerPresentation(
    afModeTile: CommandTilePresentation?,
    areaTile: CommandTilePresentation?,
    subjectTile: CommandTilePresentation?,
    strings: PhoneStringResolver,
): MonitorPickerPresentation? {
    fun drum(
        tabLabel: String,
        tile: CommandTilePresentation?,
        control: CameraControl,
        options: List<String>,
        base: String,
        live: String?,
    ): MonitorPickerModePresentation? {
        // Open when the body has a readout even if options are still settling.
        val value = live?.takeIf { it != "—" } ?: tile?.value?.takeIf { it != "—" } ?: return null
        val request =
            tile?.request?.copy(
                control = control,
                currentValue =
                    when {
                        value in options -> value
                        else -> base
                    },
                options = options,
            )
                ?: CommandControlRequest(
                    title = strings.resolve(R.string.camera_label_focus),
                    control = control,
                    currentValue = if (value in options) value else base,
                    options = options,
                )
        return MonitorPickerModePresentation(label = tabLabel, request = request)
    }

    val afLive = afModeTile?.value?.takeIf { it != "—" }
    val areaLive = areaTile?.value?.takeIf { it != "—" }
    val subjectLive = subjectTile?.value?.takeIf { it != "—" }
    val afOpts =
        FocusPickerPolicy.afModeOptions(afModeTile?.request?.options.orEmpty())
    val areaOpts =
        FocusPickerPolicy.areaOptions(areaTile?.request?.options.orEmpty())
    val subjectOpts =
        FocusPickerPolicy.subjectOptions(subjectTile?.request?.options.orEmpty())

    // Tab titles are iOS-literal (same as Kelvin / Preset / Tint) so tests and
    // chrome match without string-resource indirection.
    val modes =
        listOfNotNull(
            drum(
                tabLabel = "AF Mode",
                tile = afModeTile,
                control = CameraControl.FOCUS_MODE,
                options = afOpts,
                base = FocusPickerPolicy.AF_MODE_BASE,
                live = afLive,
            ),
            drum(
                tabLabel = "Area",
                tile = areaTile,
                control = CameraControl.FOCUS_AREA,
                options = areaOpts,
                base = FocusPickerPolicy.AREA_BASE,
                live = areaLive,
            ),
            drum(
                tabLabel = "Subject",
                tile = subjectTile,
                control = CameraControl.FOCUS_SUBJECT,
                options = subjectOpts,
                base = FocusPickerPolicy.SUBJECT_BASE,
                live = subjectLive,
            ),
        )
    if (modes.isEmpty()) return null

    val initialMode =
        when {
            FocusPickerPolicy.isAfModeLabel(afLive.orEmpty()) -> 0
            FocusPickerPolicy.isAreaLabel(areaLive.orEmpty()) &&
                !FocusPickerPolicy.isAfModeLabel(afLive.orEmpty()) -> 1
            FocusPickerPolicy.isSubjectLabel(subjectLive.orEmpty()) &&
                afLive == null -> 2
            else -> 0
        }

    return MonitorPickerPresentation(
        kind = MonitorPickerKind.FOCUS,
        title = strings.resolve(R.string.camera_label_focus),
        subtitle = FocusPickerPolicy.SUBTITLE,
        modes = modes,
        initialModeIndex = initialMode.coerceIn(0, modes.lastIndex),
    )
}

/**
 * The host's strip labels on the wire (iOS `CameraDisplayState.values`) mapped to this shell's
 * stable picker kinds. Kinds, not labels: the local labels are localized strings.
 */
private val relayValueKinds =
    mapOf(
        "ISO" to MonitorPickerKind.ISO,
        "SHUTTER" to MonitorPickerKind.SHUTTER,
        "IRIS" to MonitorPickerKind.IRIS,
        "WB" to MonitorPickerKind.WHITE_BALANCE,
        "FOCUS" to MonitorPickerKind.FOCUS,
    )

/**
 * A watcher's capture strip shows the broadcaster's values, forwarded over the relay already
 * formatted (iOS `applyRelayState`). Display only: the cells keep whatever picker the local
 * presentation carried — for a watcher that is none, so the strip reads and never writes,
 * exactly the iOS watcher's strip.
 */
internal fun relayCaptureSettings(
    settings: List<MonitorCaptureSettingPresentation>,
    relayedValues: List<MonitorRelayWire.StateValue>,
): List<MonitorCaptureSettingPresentation> {
    val byKind =
        relayedValues
            .mapNotNull { value -> relayValueKinds[value.label]?.let { it to value.value } }
            .toMap()
    return settings.map { setting ->
        byKind[setting.kind]
            ?.takeIf { it.isNotBlank() }
            ?.let { setting.copy(value = captureBarDisplayValue(it)) }
            ?: setting
    }
}

/**
 * Bar-side abbreviations (iOS `CaptureSettingButton.displayValue`). Full forms
 * stay in the drum; only the strip shortens.
 */
internal fun captureBarDisplayValue(value: String): String =
    when (value) {
        "Auto Subject" -> "Auto-S"
        else -> value
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

/**
 * Projects the WB capture-bar picker (iOS `CameraPicker.whiteBalance`):
 * **Kelvin** / **Preset** / **Tint** — not a combined Kelvin·Preset tab.
 * Tint is the shared ladder sheet's tint pad.
 */
internal fun wbPickerPresentation(
    wbTile: CommandTilePresentation?,
    tintTile: CommandTilePresentation?,
    strings: PhoneStringResolver,
): MonitorPickerPresentation? {
    val live = wbTile?.value?.takeIf { it != "—" } ?: return null
    // Open when the body has a WB readout even if the write domain is still
    // settling (same as shutter lock — operator can still browse).
    val cameraOpts = wbTile.request?.options.orEmpty()
    val kelvinOptions = WbPickerPolicy.kelvinOptions(cameraOpts, liveLabel = live)
    val presetOptions = WbPickerPolicy.presetOptions(cameraOpts)
    val tintOptions =
        tintTile?.request?.options?.takeIf { it.isNotEmpty() }
            ?: listOf(tintTile?.value?.takeIf { it != "—" } ?: "Neutral")
    val tintCurrent = tintTile?.value?.takeIf { it != "—" } ?: "Neutral"
    val title = strings.resolve(R.string.camera_label_wb)
    val kelvinCurrent =
        when {
            live in kelvinOptions -> live
            WbPickerPolicy.isKelvinLabel(live) -> live
            else -> WbPickerPolicy.KELVIN_BASE
        }
    val presetCurrent =
        when {
            live in presetOptions -> live
            WbPickerPolicy.isPresetLabel(live) -> live
            else -> WbPickerPolicy.PRESET_BASE
        }
    val initialMode =
        when {
            WbPickerPolicy.isKelvinLabel(live) || live in kelvinOptions -> 0
            WbPickerPolicy.isPresetLabel(live) || live in presetOptions -> 1
            else -> 0
        }
    return MonitorPickerPresentation(
        kind = MonitorPickerKind.WHITE_BALANCE,
        title = title,
        subtitle = WbPickerPolicy.SUBTITLE,
        modes =
            listOf(
                MonitorPickerModePresentation(
                    label = "Kelvin",
                    request =
                        CommandControlRequest(
                            title = title,
                            control = CameraControl.WHITE_BALANCE,
                            currentValue = kelvinCurrent,
                            options = kelvinOptions,
                        ),
                ),
                MonitorPickerModePresentation(
                    label = "Preset",
                    request =
                        CommandControlRequest(
                            title = title,
                            control = CameraControl.WHITE_BALANCE,
                            currentValue = presetCurrent,
                            options = presetOptions,
                        ),
                ),
                MonitorPickerModePresentation(
                    label = "Tint",
                    request =
                        CommandControlRequest(
                            title = strings.resolve(R.string.camera_mode_tint),
                            control = CameraControl.WHITE_BALANCE_TINT,
                            currentValue = tintCurrent,
                            options = tintOptions,
                        ),
                ),
            ),
        initialModeIndex = initialMode,
    )
}

/**
 * Projects the SHUTTER capture-bar picker (iOS `CameraPicker.shutter`):
 * **Angle** / **Speed** dual circuit tabs — not Value / Mode / Lock.
 * Lock is long-press on the strip cell, not a mode tab.
 *
 * Options prefer a multi-value camera enum for the active circuit; otherwise
 * the hardcoded iOS ladders from [ShutterPickerPolicy].
 */
internal fun shutterPickerPresentation(
    shutterTile: CommandTilePresentation?,
    shutterModeTile: CommandTilePresentation?,
    strings: PhoneStringResolver,
    shutterLocked: Boolean? = null,
): MonitorPickerPresentation? {
    val live = shutterTile?.value?.takeIf { it != "—" } ?: return null
    // Only the camera TV-lock gate dims the drum. Empty descriptor options or a
    // still-settling shutterMode must not look like "Shutter locked" — the capture
    // strip still encodes Angle/Speed ladders through the shared core (iOS parity).
    val lockedOnCamera = shutterLocked == true
    val cameraOpts = shutterTile.request?.options.orEmpty()
    val angleOptions = ShutterPickerPolicy.angleOptions(cameraOpts)
    val speedOptions = ShutterPickerPolicy.speedOptions(cameraOpts)
    val modeIsSpeed =
        shutterModeTile?.value.equals("Speed", ignoreCase = true) == true ||
            (shutterModeTile?.value == null && live.startsWith("1/"))
    val title = strings.resolve(R.string.camera_label_shutter)
    val modeTitle = strings.resolve(R.string.command_title_shutter_mode)
    fun circuit(
        label: String,
        options: List<String>,
        base: String,
        modeValue: String,
    ): MonitorPickerModePresentation {
        val current = if (live in options) live else base
        return MonitorPickerModePresentation(
            label = label,
            request =
                CommandControlRequest(
                    title = title,
                    control = CameraControl.SHUTTER,
                    currentValue = current,
                    options = options,
                ),
            activateRequest =
                CommandControlRequest(
                    title = modeTitle,
                    control = CameraControl.SHUTTER_MODE,
                    currentValue = modeValue,
                    options = listOf("Angle", "Speed"),
                ),
        )
    }
    return MonitorPickerPresentation(
        kind = MonitorPickerKind.SHUTTER,
        title = title,
        subtitle = ShutterPickerPolicy.SUBTITLE,
        modes =
            listOf(
                circuit("Angle", angleOptions, ShutterPickerPolicy.ANGLE_BASE, "Angle"),
                circuit("Speed", speedOptions, ShutterPickerPolicy.SPEED_BASE, "Speed"),
            ),
        initialModeIndex = if (modeIsSpeed) 1 else 0,
        interactionLocked = lockedOnCamera,
        lockBanner =
            if (lockedOnCamera) {
                "Shutter locked on camera — hold anywhere to unlock"
            } else {
                null
            },
    )
}

/**
 * Projects the ISO capture-bar picker from [IsoPickerPolicy] (iOS
 * `ISOPickerPolicy` / `PickerPanel`).
 *
 * - R3D NE: Low Base / High Base tabs with full ladders + base-ISO activate.
 * - Other codecs: Auto On / Auto Off tabs + unified drum (exit auto by picking ISO).
 * - Auto Off / manual drum only when [exposureMode] is **M**.
 * Options always come from the policy (not a partial camera enum).
 */
internal fun isoPickerPresentation(
    isoTile: CommandTilePresentation?,
    codec: String,
    baseIsoTile: CommandTilePresentation?,
    isoAuto: Boolean?,
    exposureMode: String?,
    strings: PhoneStringResolver,
): MonitorPickerPresentation? {
    // Prefer live ISO. Auto-mode tiles may read "A3200" / "Auto" — strip the Auto prefix for the drum.
    val live =
        isoTile?.value
            ?.takeIf { it != "—" }
            ?.removePrefix("A")
            ?.takeIf { !it.equals("Auto", ignoreCase = true) }
    val dual = IsoPickerPolicy.showsDualBaseCircuits(codec)
    val autoControl = IsoPickerPolicy.showsAutoISOControl(codec)
    // Empty / non-writable ISO tile must not invent a unified drum. Require a live
    // value, a camera-backed request, or a known Auto/dual-base codec layout.
    if (
        live == null &&
            isoTile?.request == null &&
            !autoControl &&
            !dual
    ) {
        return null
    }
    val title = strings.resolve(R.string.camera_label_iso)
    val subtitle = IsoPickerPolicy.pickerSubtitle(codec, exposureMode)
    val ladder = IsoPickerPolicy.unifiedOptions
    // Inject Auto-driven values outside the fixed ladder (e.g. 51200).
    val options =
        if (live != null && live !in ladder) {
            IsoPickerPolicy.options(codec, 0, includingLiveISO = live)
        } else {
            ladder
        }
    val current = live?.takeIf { it in options } ?: live ?: options.firstOrNull() ?: return null

    if (autoControl) {
        val modes =
            IsoPickerPolicy.pickerModes(codec, exposureMode).map { mode ->
                val activatesAuto = mode.activatesAutoISO == true
                val modeOptions =
                    IsoPickerPolicy.options(
                        codec = codec,
                        modeIndex = 0,
                        includingLiveISO = live,
                    )
                MonitorPickerModePresentation(
                    label = mode.title,
                    detail = mode.detail,
                    request =
                        CommandControlRequest(
                            title = title,
                            control = CameraControl.ISO,
                            currentValue = current,
                            options = modeOptions,
                        ),
                    activateRequest =
                        CommandControlRequest(
                            title = title,
                            control = CameraControl.ISO_AUTO,
                            currentValue =
                                if (activatesAuto) {
                                    IsoPickerPolicy.AUTO_ISO_ON_LABEL
                                } else {
                                    IsoPickerPolicy.AUTO_ISO_OFF_LABEL
                                },
                            options =
                                listOf(
                                    IsoPickerPolicy.AUTO_ISO_ON_LABEL,
                                    IsoPickerPolicy.AUTO_ISO_OFF_LABEL,
                                ),
                        ),
                    // Auto On: only MovISOAutoControl. Auto Off: turn auto off; do not
                    // immediately re-write the live Auto value (it may sit outside the
                    // manual ladder, e.g. 51200) — the operator picks a manual step next.
                    applyValueOnActivate = false,
                    markedValues = IsoPickerPolicy.markedValues(codec, 0),
                )
            }
        val cameraOwned =
            IsoPickerPolicy.isISOValueCameraOwned(codec, isoAuto, exposureMode)
        return MonitorPickerPresentation(
            kind = MonitorPickerKind.ISO,
            title = title,
            subtitle = subtitle,
            modes = modes,
            initialModeIndex =
                IsoPickerPolicy.autoISOModeIndex(codec, isoAuto, exposureMode),
            // Drum is camera-owned while Auto is on or (non-R3D) mode is not M.
            drumInteractionLocked = cameraOwned,
            drumLockBanner =
                if (cameraOwned) {
                    if (IsoPickerPolicy.allowsManualISO(codec, exposureMode)) {
                        strings.resolve(R.string.iso_auto_drum_locked)
                    } else {
                        strings.resolve(R.string.iso_manual_requires_m_mode)
                    }
                } else {
                    null
                },
        )
    }

    if (!dual) {
        return MonitorPickerPresentation(
            kind = MonitorPickerKind.ISO,
            title = title,
            subtitle = subtitle,
            modes =
                listOf(
                    MonitorPickerModePresentation(
                        label = title,
                        request =
                            CommandControlRequest(
                                title = title,
                                control = CameraControl.ISO,
                                currentValue = current,
                                options = options,
                            ),
                        markedValues = IsoPickerPolicy.markedValues(codec, 0),
                    ),
                ),
        )
    }
    val baseLabel = baseIsoTile?.value?.takeIf { it != "—" }
    val highBase = baseLabel.equals("High", ignoreCase = true)
    val modes =
        IsoPickerPolicy.pickerModes(codec).mapIndexed { index, mode ->
            val circuitCurrent =
                when {
                    live != null && live in mode.options -> live
                    else -> mode.base
                }
            val baseValue = if (index == 0) "Low" else "High"
            MonitorPickerModePresentation(
                label = mode.title,
                detail = mode.detail,
                request =
                    CommandControlRequest(
                        title = title,
                        control = CameraControl.ISO,
                        currentValue = circuitCurrent,
                        options = mode.options,
                    ),
                activateRequest =
                    CommandControlRequest(
                        title = strings.resolve(R.string.camera_mode_base_iso),
                        control = CameraControl.BASE_ISO,
                        currentValue = baseValue,
                        options = listOf("Low", "High"),
                    ),
                markedValues = IsoPickerPolicy.markedValues(codec, index),
            )
        }
    // R3D NE dual-base is always manual ISO (even in A/S/P) — never gate on exposure mode.
    return MonitorPickerPresentation(
        kind = MonitorPickerKind.ISO,
        title = title,
        subtitle = subtitle,
        modes = modes,
        initialModeIndex = if (highBase) 1 else 0,
    )
}

/** Whether [kind] uses the top-deck drop-down path on landscape (iOS `isTopBar`). */
internal fun MonitorPickerKind.isTopBarPicker(): Boolean =
    this == MonitorPickerKind.RESOLUTION ||
        this == MonitorPickerKind.CODEC ||
        this == MonitorPickerKind.SIZE ||
        this == MonitorPickerKind.QUALITY

/**
 * The Nikon controls inside the shared camera panel (iOS `PickerPanel` body). The live composition
 * supplies the panel chrome, reveal, backdrop and dismissal.
 */
@Composable
internal fun MonitorControlPickerPanel(
    picker: MonitorPickerPresentation,
    commonControl: MonitorControlModel? = null,
    commonField: MonitorCaptureField? = null,
    controlsEnabled: Boolean,
    feedback: CommandControlFeedback?,
    onSelect: (CommandControlRequest, String) -> Unit,
    onDismiss: () -> Unit,
    slideFromTop: Boolean = false,
    /** iOS PickerPanel long-press: shutter control lock toggle (0.45s, hold anywhere). */
    onShutterLongPress: (() -> Unit)? = null,
    /** Photo timers' shared shot count, rendered in tabs flagged [MonitorPickerModePresentation.showsTimerShots]. */
    timerShotsCount: Int = 1,
    /** Steps the timers' shot count by ±1 (nil hides the stepper row). */
    onAdjustTimerShots: ((Int) -> Unit)? = null,
    /** Live NEF (RAW) compression readout for the QUALITY dual-drum panel. */
    nefCompression: String? = null,
    /** The body's advertised NEF compressions; empty keeps the conservative ladder (#274). */
    nefOptions: List<String> = emptyList(),
    /** Current persisted focus-scrub preference, shown as a toggle row in the FOCUS popup. */
    mfScrubEnabled: Boolean = true,
    /** Flips the focus-scrub preference; null omits the FOCUS popup's toggle row. */
    onToggleMfScrub: (() -> Unit)? = null,
) {
    val writeEnabled = controlsEnabled && com.opencapture.opencine.appkit.LocalMonitorCaptureCommandEnabled.current
    if (picker.kind == MonitorPickerKind.QUALITY) {
        // Image quality is a dual-drum pair, not a value wheel (iOS `QualityPickerPanel`).
        QualityPickerPanelBody(
            picker = picker,
            nefCompression = nefCompression,
            onSelect = onSelect,
            nefOptions = nefOptions.ifEmpty { StillPickerLadders.NEF_OPTIONS },
            controlsEnabled = writeEnabled,
        )
        return
    }
    // Every other kind is a shared ladder (`ladderKinds`).
    VideoLadderBody(
        picker = picker,
        field = commonField,
        control = commonControl,
        controlsEnabled = writeEnabled,
        error = feedback?.takeIf { it.isError }?.message,
        unavailable = stringResource(R.string.camera_controls_unavailable),
        fromTop = slideFromTop,
        onWrite = onSelect,
        onClose = onDismiss,
        onHold = if (picker.kind == MonitorPickerKind.SHUTTER && writeEnabled) onShutterLongPress else null,
        tintLabel = { tint -> WhiteBalanceTint.label(tint.amberBlue ?: 0, tint.greenMagenta) },
        tintHelp = stringResource(R.string.camera_wb_tint_steps_help) + "\n" +
            stringResource(R.string.camera_wb_tint_double_tap_help),
        footer = { tab ->
            if (ladderShowsTimerShots(picker, tab) && onAdjustTimerShots != null) {
                TimerShotsRow(count = timerShotsCount, enabled = writeEnabled && !tab.disabled, onAdjust = onAdjustTimerShots)
            }
            if (picker.kind == MonitorPickerKind.FOCUS && onToggleMfScrub != null) {
                MfScrubToggleRow(enabled = mfScrubEnabled, onToggle = onToggleMfScrub)
            }
        },
    )
}

/**
 * FOCUS popup toggle for the live-view focus-scrub strip (iOS `mfScrubToggleRow`): a bordered
 * glass row with a label and the shared settings switch graphic. Off hides the strip regardless
 * of focus mode.
 */
@Composable
private fun MfScrubToggleRow(enabled: Boolean, onToggle: () -> Unit) {
    Row(
        Modifier
            .fillMaxWidth()
            .background(LiveDesign.background.copy(alpha = 0.28f), ChromeShape)
            .border(1.dp, LiveDesign.hairline, ChromeShape)
            .chromeClickable(onClick = onToggle)
            .semantics {
                role = Role.Switch
                toggleableState = ToggleableState(enabled)
            }
            .padding(horizontal = 12.dp, vertical = 6.dp),
        horizontalArrangement = Arrangement.spacedBy(12.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Text(
            stringResource(R.string.camera_focus_scrub_toggle),
            style = chromeStyle(12f, FontWeight.SemiBold),
            color = LiveDesign.text,
            maxLines = 1,
            modifier = Modifier.weight(1f),
        )
        MonitorSettingsSwitchGraphic(isOn = enabled)
    }
}

/**
 * Drag-to-pulse gain per dp — deliberately gentle so a full strip sweep is a controllable focus
 * pull, not a slam to the stop (was 24/dp, ~6-8× too twitchy on a real lens).
 */
/**
 * Drag-to-pulse gain at the slow end of the ramp — mirrors iOS `MFDriveVerticalScrub.pulsesPerPoint`.
 *
 * Was 4, which a real video pull found too coarse to trim focus with. Calibration knob, not a
 * derived constant: raise it if a full sweep cannot cross the range on a real body, lower it if
 * trimming still overshoots. Keep it in step with iOS.
 */
internal const val MF_DRIVE_PULSES_PER_DP = 2

/** Dp of per-frame travel that buys one extra multiple of gain. Larger = slower drags stay fine. */
internal const val MF_DRIVE_SPEED_RAMP_DP = 14f

/** Ceiling on the flick multiplier. */
internal const val MF_DRIVE_MAX_SPEED_FACTOR = 4f

/**
 * Vertical focus-by-wire strip on the live view (MF + proven-drivable lens
 * only): a slim glass capsule with ∞ at the top, NEAR at the bottom, and a
 * centre tick. Dragging drives the lens by relative pulses — up toward
 * infinity — there is no absolute position to seek. Travel ends light their
 * label. [verify-on-HW: pulses-per-dp feel per lens]
 */
@Composable
internal fun MFDriveStrip(
    atEnd: Int?,
    enabled: Boolean,
    onDrive: (Int) -> Unit,
    modifier: Modifier = Modifier,
    /** Net acknowledged pulses (+ toward infinity) — scrolls the drum ticks. */
    netPulses: Int = 0,
    /** Relative focus position 0…1 once both travel ends are pinned; null while uncalibrated. */
    dialFraction: Float? = null,
) {
    // Drag feedback (iOS MFDriveVerticalScrub isDragging): the strip must
    // visibly react to touch even before the lens moves — a scrub against a
    // busy body otherwise reads as dead input.
    var dragging by remember { mutableStateOf(false) }
    Box(
        modifier
            .alpha(if (enabled) 1f else 0.55f)
            .pointerInput(enabled) {
                if (!enabled) return@pointerInput
                detectDragGestures(
                    onDragStart = { dragging = true },
                    onDragEnd = { dragging = false },
                    onDragCancel = { dragging = false },
                ) { change, dragAmount ->
                    change.consume()
                    // Screen-up is negative y; up drives toward infinity (+).
                    // Ring-like speed response: a slow drag steps finely, a
                    // deliberate flick multiplies travel — mirrors the iOS gain curve.
                    val deltaDp = -dragAmount.y.toDp().value
                    val speedFactor =
                        (1f + kotlin.math.abs(deltaDp) / MF_DRIVE_SPEED_RAMP_DP)
                            .coerceAtMost(MF_DRIVE_MAX_SPEED_FACTOR)
                    val pulses =
                        (deltaDp * MF_DRIVE_PULSES_PER_DP * speedFactor).toInt()
                    if (pulses != 0) onDrive(pulses)
                }
            }
            // Absorb plain taps: the strip sits over the feed, and a tap that
            // fell through would move the AF point under the scrub.
            .pointerInput(Unit) { detectTapGestures(onTap = {}) }
            .semantics {
                contentDescription =
                    "Manual focus drive. Drag up toward infinity or down toward near."
            },
        contentAlignment = Alignment.Center,
    ) {
        Column(
            Modifier
                .width(28.dp)
                .fillMaxHeight()
                .monitorMaterial(MonitorMaterial.Compact, CircleShape)
                .background(
                    Color.White.copy(alpha = if (dragging) 0.14f else 0f),
                    CircleShape,
                )
                .border(
                    if (dragging) 1.5.dp else 1.dp,
                    if (dragging) LiveDesign.accent else LiveDesign.hairline,
                    CircleShape,
                )
                .padding(vertical = 12.dp),
            horizontalAlignment = Alignment.CenterHorizontally,
        ) {
            Text(
                "∞",
                style = chromeStyle(12f, FontWeight.SemiBold, mono = true),
                color = if (atEnd == 1) LiveDesign.accent else LiveDesign.muted,
            )
            // Scrolling tick drum: ticks move with the drive like a physical focus ring; a fixed
            // centre line marks the current position.
            val tickColor = LiveDesign.text
            val centreColor = LiveDesign.accent
            Canvas(Modifier.weight(1f).fillMaxWidth()) {
                val tickSpacing = 11.dp.toPx()
                val pulsesPerTick = 220f
                val mid = size.height / 2f
                val current = netPulses / pulsesPerTick
                val span = (mid / tickSpacing).toInt() + 2
                val base = Math.round(current)
                for (offset in -span..span) {
                    val index = base + offset
                    val y = mid - (index - current) * tickSpacing
                    if (y < 0f || y > size.height) continue
                    val major = index % 5 == 0
                    val w = (if (major) 0.72f else 0.4f) * size.width
                    drawRect(
                        color = tickColor.copy(alpha = if (major) 0.5f else 0.28f),
                        topLeft = androidx.compose.ui.geometry.Offset((size.width - w) / 2f, y),
                        size = androidx.compose.ui.geometry.Size(w, if (major) 1.5.dp.toPx() else 1f),
                    )
                }
                val cw = (if (dragging) 26.dp else 20.dp).toPx()
                drawRect(
                    color = centreColor.copy(alpha = 0.95f),
                    topLeft = androidx.compose.ui.geometry.Offset((size.width - cw) / 2f, mid - 1f),
                    size = androidx.compose.ui.geometry.Size(cw, 2f),
                )
            }
            Text(
                "NEAR",
                style = chromeStyle(7f, FontWeight.SemiBold, mono = true),
                color = if (atEnd == -1) LiveDesign.accent else LiveDesign.muted,
                maxLines = 1,
                softWrap = false,
            )
            dialFraction?.let { fraction ->
                Text(
                    "${Math.round(fraction * 100)}",
                    style = chromeStyle(9f, FontWeight.SemiBold, mono = true),
                    color = LiveDesign.text,
                )
            }
        }
    }
}
