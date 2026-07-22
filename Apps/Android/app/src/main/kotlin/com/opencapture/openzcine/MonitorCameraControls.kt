package com.opencapture.openzcine

import androidx.activity.compose.BackHandler
import androidx.compose.animation.AnimatedContent
import androidx.compose.animation.core.CubicBezierEasing
import androidx.compose.animation.core.animateDpAsState
import androidx.compose.animation.core.tween
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.animation.togetherWith
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.gestures.awaitEachGesture
import androidx.compose.foundation.gestures.awaitFirstDown
import androidx.compose.foundation.gestures.detectTapGestures
import androidx.compose.foundation.gestures.waitForUpOrCancellation
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.offset
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.wrapContentHeight
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.key
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.clipToBounds
import androidx.compose.ui.draw.drawWithContent
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.BlendMode
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.CompositingStrategy
import androidx.compose.ui.graphics.Path
import androidx.compose.ui.graphics.StrokeCap
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.layout.boundsInRoot
import androidx.compose.ui.layout.onGloballyPositioned
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.platform.LocalViewConfiguration
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.disabled
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.opencapture.openzcine.bridge.MonitorZones
import com.opencapture.openzcine.bridge.ZoneFrame
import com.opencapture.openzcine.core.CameraControl
import com.opencapture.openzcine.settings.PanelCloseButton
import com.opencapture.openzcine.settings.PortraitFeedAspect
import kotlin.math.cos
import kotlin.math.max
import kotlin.math.min
import kotlin.math.sin
import kotlinx.coroutines.withTimeoutOrNull

/**
 * iOS `panelRevealCurve`: CSS cubic-bezier(0.16, 1, 0.3, 1), 0.20s ease-out-expo
 * used for picker + assist slide reveals (`NativeAppModel.panelRevealCurve`).
 */
internal val IosPanelRevealSpec =
    tween<Dp>(
        durationMillis = 200,
        easing = CubicBezierEasing(0.16f, 1f, 0.3f, 1f),
    )

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
    /** Authoritative camera TV-lock when known; dims the shutter drum like iOS. */
    shutterLockedOnCamera: Boolean? = null,
    /** Movie ISO auto (`MovISOAutoControl`); drives Auto On/Off tab for non-R3D NE. */
    isoAuto: Boolean? = null,
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
            shutterTile.unavailableReason.contains("locked", ignoreCase = true)
    val isoPresentation =
        isoPickerPresentation(
            isoTile = isoTile,
            codec = codec,
            baseIsoTile = exposure.getOrNull(0),
            isoAuto = isoAuto,
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
            val cameraOpts = irisTile?.request?.options.orEmpty()
            val options =
                cameraOpts.ifEmpty {
                    IrisPickerPolicy.options(forLensDescriptor = null)
                }
            // Open IRIS whenever we have a live f-number, using the lens/core ladder
            // if the body did not advertise a writable enum (same as iOS).
            val live = irisTile?.value?.takeIf { it != "—" }
            val presentation =
                if (live != null && options.isNotEmpty()) {
                    val request =
                        irisTile.request?.copy(options = options)
                            ?: CommandControlRequest(
                                title = strings.resolve(R.string.camera_label_iris),
                                control = CameraControl.IRIS,
                                currentValue = if (live in options) live else options.first(),
                                options = options,
                            )
                    MonitorPickerPresentation(
                        kind = MonitorPickerKind.IRIS,
                        title = strings.resolve(R.string.camera_label_iris),
                        subtitle = strings.resolve(R.string.camera_subtitle_iris),
                        modes = listOf(MonitorPickerModePresentation(request.title, request)),
                    )
                } else {
                    null
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
 * Bar-side abbreviations (iOS `CaptureSettingButton.displayValue`). Full forms
 * stay in the drum; only the strip shortens.
 */
internal fun captureBarDisplayValue(value: String): String =
    when (value) {
        "Auto Subject" -> "Auto-S"
        else -> value
    }

/**
 * SF Symbol name for a WB preset in the capture bar; null for Kelvin readouts
 * (iOS `CaptureSettingButton.valueIcon`).
 */
internal fun captureBarWbIcon(value: String): CaptureWbIcon? =
    when (value) {
        "Auto" -> CaptureWbIcon.AUTO
        "Natural auto" -> CaptureWbIcon.NATURAL_AUTO
        "Sunny" -> CaptureWbIcon.SUNNY
        "Cloudy" -> CaptureWbIcon.CLOUDY
        "Shade" -> CaptureWbIcon.SHADE
        "Incandescent" -> CaptureWbIcon.INCANDESCENT
        "Fluorescent" -> CaptureWbIcon.FLUORESCENT
        "Flash" -> CaptureWbIcon.FLASH
        "Preset" -> CaptureWbIcon.PRESET
        else -> null
    }

/** Compact WB preset icons for the capture strip (iOS SF Symbol stand-ins). */
internal enum class CaptureWbIcon {
    AUTO,
    NATURAL_AUTO,
    SUNNY,
    CLOUDY,
    SHADE,
    INCANDESCENT,
    FLUORESCENT,
    FLASH,
    PRESET,
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
 * Projects the WB capture-bar picker (iOS `CameraPicker.whiteBalance`):
 * **Kelvin** / **Preset** / **Tint** — not a combined Kelvin·Preset tab.
 * Tint swaps the drum for [WhiteBalanceTintPad].
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
 * Options always come from the policy (not a partial camera enum).
 */
internal fun isoPickerPresentation(
    isoTile: CommandTilePresentation?,
    codec: String,
    baseIsoTile: CommandTilePresentation?,
    isoAuto: Boolean?,
    strings: PhoneStringResolver,
): MonitorPickerPresentation? {
    // Prefer live ISO; when Auto is driving ISO the body may report "—"/Auto — still open the drum.
    val live = isoTile?.value?.takeIf { it != "—" && !it.equals("Auto", ignoreCase = true) }
    val canWrite = isoTile?.request != null || IsoPickerPolicy.showsAutoISOControl(codec)
    if (!canWrite && isoTile?.unavailableReason == null && live == null &&
        !IsoPickerPolicy.showsAutoISOControl(codec)
    ) {
        return null
    }
    val dual = IsoPickerPolicy.showsDualBaseCircuits(codec)
    val autoControl = IsoPickerPolicy.showsAutoISOControl(codec)
    val title = strings.resolve(R.string.camera_label_iso)
    val subtitle = IsoPickerPolicy.pickerSubtitle(codec)
    val options = IsoPickerPolicy.unifiedOptions
    val current = live?.takeIf { it in options } ?: options.firstOrNull() ?: return null

    if (autoControl) {
        val modes =
            IsoPickerPolicy.pickerModes(codec).map { mode ->
                val activatesAuto = mode.activatesAutoISO == true
                MonitorPickerModePresentation(
                    label = mode.title,
                    detail = mode.detail,
                    request =
                        CommandControlRequest(
                            title = title,
                            control = CameraControl.ISO,
                            currentValue = current,
                            options = mode.options,
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
                    // Auto On does not write ISO; Auto Off writes the drum after manual.
                    applyValueOnActivate = mode.activatesAutoISO != true,
                    markedValues = IsoPickerPolicy.markedValues(codec, 0),
                )
            }
        return MonitorPickerPresentation(
            kind = MonitorPickerKind.ISO,
            title = title,
            subtitle = subtitle,
            modes = modes,
            initialModeIndex = IsoPickerPolicy.autoISOModeIndex(isoAuto),
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
    return MonitorPickerPresentation(
        kind = MonitorPickerKind.ISO,
        title = title,
        subtitle = subtitle,
        modes = modes,
        initialModeIndex = if (highBase) 1 else 0,
    )
}

/**
 * Seats the picker against frames supplied by the shared Swift zone map.
 * Landscape capture-bar pickers prefer the **measured** glass pill frame (iOS
 * `captureBarFrame`) so width and trailing edge match the content-hugging bar
 * rather than the wider zone slot.
 */
internal fun monitorPickerFrame(
    viewport: ZoneFrame,
    zones: MonitorZones,
    isPortrait: Boolean,
    anchor: MonitorPickerAnchor,
    measuredCaptureBar: ZoneFrame? = null,
): ZoneFrame {
    val outerMargin = if (isPortrait) 12f else 8f
    // Portrait keeps a gap under the info bar. Landscape mirrors iOS: the
    // bottom-anchored picker may grow upward through the info-bar band so the
    // WB tint pad (header + 180dp arrow cluster + mode tabs) still fits on
    // short handsets (~384dp tall landscape, e.g. SM-A12).
    val topLimit =
        if (isPortrait) {
            max(
                viewport.y + outerMargin,
                zones.infoBar.y + zones.infoBar.height + 8f,
            )
        } else {
            viewport.y + outerMargin
        }
    val zoneAnchor =
        when (anchor) {
            MonitorPickerAnchor.CAPTURE_STRIP -> zones.captureStrip
            MonitorPickerAnchor.CONTROLS_GRID -> zones.controlsGrid
        }
    // iOS uses the measured GlassPanel (`captureBarFrame`), not the zone slot.
    val measuredBar =
        measuredCaptureBar?.takeIf {
            !isPortrait &&
                anchor == MonitorPickerAnchor.CAPTURE_STRIP &&
                it.width > 1f &&
                it.height > 1f
        }
    val anchorFrame = measuredBar ?: zoneAnchor
    // iOS bottomPickerBody gap above the capture bar is 10pt landscape/portrait.
    val barGap = 10f
    // Landscape seats just above the bottom chrome. Prefer the higher strip
    // (assist vs capture) so short handsets reclaim the dead band the zone map
    // sometimes leaves above the glass pills — but when we have a measured bar,
    // seat directly above it (iOS hasBar path).
    val landscapeStripTop =
        if (measuredBar != null) {
            measuredBar.y
        } else {
            listOfNotNull(zones.captureStrip?.y, zones.assistStrip?.y).minOrNull()
        }
    val bottomLimit =
        when {
            isPortrait && anchor == MonitorPickerAnchor.CAPTURE_STRIP && zoneAnchor != null ->
                zoneAnchor.y - barGap
            isPortrait -> zones.systemCluster.y - barGap
            measuredBar != null -> measuredBar.y - barGap
            landscapeStripTop != null -> landscapeStripTop - barGap
            zoneAnchor != null -> zoneAnchor.y - barGap
            else -> zones.feed.y + zones.feed.height - barGap
        }
    val availableHeight = max(0f, bottomLimit - topLimit)
    // Landscape max raised so the tint pad (header + 180dp arrow cluster + mode
    // tabs) is never forced under ~300dp of panel height. Drum pickers fill
    // leftover space.
    val height = min(if (isPortrait) 320f else 360f, availableHeight)
    // iOS hasBar: width = bar.width, trailing edge = bar.maxX (no feed clamp that
    // shifts the panel left of the glass pill).
    val width =
        if (isPortrait) {
            max(0f, viewport.width - outerMargin * 2f)
        } else if (anchorFrame != null) {
            // Prefer exact bar / strip width (iOS). Cap at 420 only as a fallback
            // when the zone is missing and we would otherwise use the full feed.
            max(0f, anchorFrame.width)
        } else {
            min(420f, max(0f, zones.feed.width))
        }
    val rawX =
        if (isPortrait) {
            viewport.x + outerMargin
        } else if (anchorFrame != null) {
            // Trailing-align to the bar (iOS .bottomTrailing on bar.maxX).
            anchorFrame.x + anchorFrame.width - width
        } else {
            zones.feed.x + zones.feed.width - outerMargin - width
        }
    // Keep the panel on-screen without shifting its trailing edge left of the
    // capture bar when the bar itself is already inside the viewport.
    val minX = viewport.x + outerMargin
    val maxX =
        max(
            minX,
            viewport.x + viewport.width - width - outerMargin,
        )
    val x =
        if (!isPortrait && anchorFrame != null) {
            // Prefer exact trailing alignment; only nudge if the left edge clips.
            max(minX, rawX)
        } else {
            rawX.coerceIn(minX, maxX)
        }
    return ZoneFrame(
        x = x,
        y = max(topLimit, bottomLimit - height),
        width = width,
        height = height,
    )
}

/**
 * iOS landscape top-deck res/codec popdown: width 340, centered on the info
 * bar (cell midX), dropped just below the bar. Command mode centres the
 * panel in the viewport.
 */
internal fun monitorTopBarPickerFrame(
    viewport: ZoneFrame,
    zones: MonitorZones,
    isCommandCenter: Boolean = false,
): ZoneFrame {
    val outerMargin = 8f
    val width = min(340f, max(0f, viewport.width - outerMargin * 2f))
    val height = min(300f, max(120f, viewport.height * 0.55f))
    val x =
        if (isCommandCenter) {
            viewport.x + (viewport.width - width) / 2f
        } else {
            val mid = zones.infoBar.x + zones.infoBar.width / 2f
            (mid - width / 2f).coerceIn(
                viewport.x + outerMargin,
                viewport.x + viewport.width - width - outerMargin,
            )
        }
    val y =
        if (isCommandCenter) {
            viewport.y + (viewport.height - height) / 2f
        } else {
            zones.infoBar.y + zones.infoBar.height + 8f
        }
    return ZoneFrame(x = x, y = y, width = width, height = height)
}

/** Whether [kind] uses the top-deck drop-down path on landscape (iOS `isTopBar`). */
internal fun MonitorPickerKind.isTopBarPicker(): Boolean =
    this == MonitorPickerKind.RESOLUTION || this == MonitorPickerKind.CODEC

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
    /** iOS shutter long-press: toggle camera Movie TV lock (0.45s hold). */
    onShutterLongPress: (() -> Unit)? = null,
    /**
     * Publishes the glass pill's root bounds in dp (iOS `captureBarFrame`) so
     * the exposure picker can trailing-align to the content-hugging bar.
     */
    onBarBoundsInRoot: ((ZoneFrame) -> Unit)? = null,
) {
    val applyingState = stringResource(R.string.camera_state_applying)
    val otherChangeState = stringResource(R.string.camera_state_other_change)
    val readOnlyState = stringResource(R.string.camera_state_read_only)
    val lockedState = stringResource(R.string.camera_state_locked)
    val changeHint = stringResource(R.string.camera_state_change_hint)
    val density = LocalDensity.current
    // The glass shell stays at the shared 58dp band (iOS
    // DesignTokens.controlHeight) so the two bottom bars always align; when a
    // width budget is given, only the CELLS scale down to fit — scaling the
    // whole pill shrank its height below the assist bar's.
    Box(
        modifier =
            modifier
                .height(LiveDesign.CONTROL_HEIGHT_DP.dp)
                .glass(ChromeShape)
                .then(
                    if (onBarBoundsInRoot != null) {
                        Modifier.onGloballyPositioned { coords ->
                            val b = coords.boundsInRoot()
                            with(density) {
                                onBarBoundsInRoot(
                                    ZoneFrame(
                                        x = b.left.toDp().value,
                                        y = b.top.toDp().value,
                                        width = b.width.toDp().value,
                                        height = b.height.toDp().value,
                                    ),
                                )
                            }
                        }
                    } else {
                        Modifier
                    },
                )
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
                onShutterLongPress = onShutterLongPress,
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
    onShutterLongPress: (() -> Unit)?,
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
            // iOS stroke uses accentDim (same as fill), not full accent.
            val cellModifier =
                Modifier
                    .background(if (active) LiveDesign.accentDim else Color.Transparent, ChromeShape)
                    .border(
                        1.dp,
                        if (active) LiveDesign.accentDim else Color.Transparent,
                        ChromeShape,
                    )
                    .semantics(mergeDescendants = true) {
                        contentDescription = summary
                        if (!enabled) disabled()
                    }
                    .then(
                        if (setting.kind == MonitorPickerKind.SHUTTER && onShutterLongPress != null) {
                            // iOS capture-bar SHUTTER: tap opens, 0.45s hold toggles TV lock
                            // even when the cell is dimmed (locked on body).
                            Modifier.pointerInput(enabled, onShutterLongPress) {
                                awaitEachGesture {
                                    awaitFirstDown()
                                    val releasedEarly =
                                        withTimeoutOrNull(450L) { waitForUpOrCancellation() }
                                    if (releasedEarly == null) {
                                        onShutterLongPress()
                                        waitForUpOrCancellation()
                                    } else if (enabled) {
                                        onOpenPicker(setting.kind)
                                    }
                                }
                            }
                        } else {
                            Modifier.chromeClickable(enabled) { onOpenPicker(setting.kind) }
                        },
                    )
                    .alpha(
                        when {
                            setting.dimmed -> 0.55f
                            setting.picker == null -> 0.62f
                            else -> 1f
                        },
                    )
            Box(cellModifier) {
                CaptureSettingCell(
                    label = setting.label,
                    value = setting.value,
                    widestValue = setting.widestValue,
                    active = active,
                    controlLocked = setting.controlLocked,
                    wbIcon =
                        if (setting.kind == MonitorPickerKind.WHITE_BALANCE) {
                            captureBarWbIcon(setting.value)
                        } else {
                            null
                        },
                )
            }
        }
    }
}

/**
 * Anchored glass camera-control picker (iOS `PickerPanel` / `PanelHost`).
 *
 * - Capture / portrait: slides **up** from below the frame.
 * - Landscape top-bar res/codec ([slideFromTop]): slides **down** from above.
 * - [switchPicker] (kind change while open): slide shell stays put; content
 *   cross-fades in place (iOS `.id(picker)` + `.transition(.opacity)` +
 *   `easeInOut(0.14)`).
 * - Outside-tap backdrop + Back dismiss match iOS `handleBackdropTap`.
 * Rails stay reachable (non-modal, transparent backdrop).
 */
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
    slideFromTop: Boolean = false,
    showBackdrop: Boolean = true,
    /** iOS PickerPanel long-press: shutter control lock toggle (0.45s, hold anywhere). */
    onShutterLongPress: (() -> Unit)? = null,
) {
    val dismissAllowed = pendingControl == null
    BackHandler(enabled = dismissAllowed, onBack = onDismiss)

    // Slide container is NOT keyed on kind — switchPicker must not re-slide.
    // iOS leaves panelRevealed true and only cross-fades body content.
    var revealed by remember { mutableStateOf(false) }
    LaunchedEffect(Unit) { revealed = true }
    val travel = (frame.height + 40f).dp
    val revealOffset by
        animateDpAsState(
            targetValue =
                if (revealed) {
                    0.dp
                } else if (slideFromTop) {
                    -travel
                } else {
                    travel
                },
            animationSpec = IosPanelRevealSpec,
            label = "monitorPickerReveal",
        )
    val revealAlpha = if (revealed) 1f else 0f
    // iOS switchPicker: withAnimation(.easeInOut(duration: 0.14)).
    val switchSpec = tween<Float>(durationMillis = 140)

    Box(modifier = modifier.fillMaxSize()) {
        if (showBackdrop) {
            // Transparent full-screen hit target — iOS PanelHost clear backdrop.
            Box(
                Modifier.fillMaxSize()
                    .chromeClickable(enabled = dismissAllowed, onClick = onDismiss),
            )
        }
        // Outer box parks the glass card; content swaps via AnimatedContent.
        Box(
            modifier =
                Modifier
                    .offset(frame.x.dp, frame.y.dp + revealOffset)
                    .size(frame.width.dp, frame.height.dp)
                    .alpha(revealAlpha),
            contentAlignment = Alignment.TopStart,
        ) {
            AnimatedContent(
                targetState = picker,
                transitionSpec = {
                    fadeIn(switchSpec) togetherWith fadeOut(switchSpec)
                },
                contentKey = { it.kind },
                label = "monitorPickerSwitch",
            ) { currentPicker ->
                PickerPanelBody(
                    picker = currentPicker,
                    frame = frame,
                    controlsEnabled = controlsEnabled,
                    pendingControl = pendingControl,
                    feedback = feedback,
                    onSelect = onSelect,
                    onDismiss = onDismiss,
                    onShutterLongPress = onShutterLongPress,
                )
            }
        }
    }
}

/** Glass card body for one picker setting (header + drum/tint + mode bar). */
@Composable
private fun PickerPanelBody(
    picker: MonitorPickerPresentation,
    frame: ZoneFrame,
    controlsEnabled: Boolean,
    pendingControl: CameraControl?,
    feedback: CommandControlFeedback?,
    onSelect: (CommandControlRequest, String) -> Unit,
    onDismiss: () -> Unit,
    onShutterLongPress: (() -> Unit)? = null,
) {
    val pickerDescription =
        stringResource(R.string.camera_picker_description, picker.title, picker.subtitle)
    val viewConfiguration = LocalViewConfiguration.current
    // iOS uses 0.45s; Compose default is often 400ms — use the stricter of the two.
    val shutterLongPressMs =
        maxOf(viewConfiguration.longPressTimeoutMillis.toLong(), 450L)
    val shutterHoldEnabled =
        picker.kind == MonitorPickerKind.SHUTTER && onShutterLongPress != null
    var selectedMode by
        remember(picker.kind) {
            mutableIntStateOf(picker.initialModeIndex.coerceIn(0, picker.modes.lastIndex.coerceAtLeast(0)))
        }
    // Per-tab landed drum position while this picker is open (iOS WB Kelvin↔Preset
    // restores the last value on that circuit, not the live readout from the
    // other tab). Seeded from each mode's current camera value / base.
    val lastByMode =
        remember(picker.kind) {
            androidx.compose.runtime.mutableStateListOf(
                *picker.modes.map { it.request.currentValue }.toTypedArray(),
            )
        }
    // iOS `lastApplied`: last value written per tab. Separate from drum position so
    // re-selecting the open-time value (e.g. 25p after scrolling to 30p) still writes.
    val lastAppliedByMode =
        remember(picker.kind) {
            androidx.compose.runtime.mutableStateListOf(
                *picker.modes.map { it.request.currentValue }.toTypedArray(),
            )
        }
    val modeIndex = selectedMode.coerceIn(0, picker.modes.lastIndex.coerceAtLeast(0))
    val mode = picker.modes.getOrNull(modeIndex) ?: return
    val isTintMode = mode.request.control == CameraControl.WHITE_BALANCE_TINT
    val isKelvinMode =
        picker.kind == MonitorPickerKind.WHITE_BALANCE &&
            mode.label.equals("Kelvin", ignoreCase = true)
    // Keep the drum scrollable while a write is in flight (iOS). Pending applies
    // coalesce in MonitorScreen; freezing the wheel dropped rapid settles.
    val drumInteractive = controlsEnabled && !picker.interactionLocked
    // Ignore drum-settles briefly after a ±10 nudge so scroll snap cannot
    // overwrite the fine-tuned value with a neighbouring dial step.
    var suppressDrumSettleUntil by remember(picker.kind) { mutableStateOf(0L) }

    // Always fill the host frame: header + flexible body + fixed mode bar so
    // the Tint pad can never squash the KELVIN/PRESET/TINT tabs (A12 short).
    // Tint uses tighter vertical rhythm so the full D-pad (incl. bottom M
    // chevron) clears the mode bar on short landscape panels.
    val panelVPad = if (isTintMode) 12.dp else 16.dp
    val panelGap = if (isTintMode) 8.dp else 12.dp
    Column(
        modifier =
            Modifier
                .fillMaxSize()
                .heightIn(max = frame.height.dp)
                .overlayGlass(ChromeShape)
                .border(1.dp, LiveDesign.hairlineStrong, ChromeShape)
                // iOS PickerPanel: long-press anywhere (incl. lock banner) toggles shutter
                // control lock. requireUnconsumed=false so the drum still scrolls.
                .then(
                    if (shutterHoldEnabled) {
                        Modifier.pointerInput(shutterLongPressMs, onShutterLongPress) {
                            awaitEachGesture {
                                awaitFirstDown(requireUnconsumed = false)
                                val releasedEarly =
                                    withTimeoutOrNull(shutterLongPressMs) {
                                        waitForUpOrCancellation()
                                    }
                                if (releasedEarly == null) {
                                    onShutterLongPress?.invoke()
                                    waitForUpOrCancellation()
                                }
                            }
                        }
                    } else {
                        Modifier
                    },
                )
                // Absorb plain taps so they don't fall through to the dismiss scrim.
                .pointerInput(Unit) { detectTapGestures(onTap = {}) }
                .padding(horizontal = 20.dp, vertical = panelVPad)
                .semantics { contentDescription = pickerDescription },
        verticalArrangement = Arrangement.spacedBy(panelGap),
    ) {
        // iOS `PickerHeader`: kerned heavy name + mono uppercase subtitle.
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

        // Errors / lock only — never the green "WB set to …" success line.
        // That toast stole vertical room on short landscape and clipped Tint's
        // bottom (magenta) D-pad chevron. iOS does not show apply text in-panel.
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
        picker.lockBanner?.let { banner ->
            Row(
                Modifier
                    .fillMaxWidth()
                    .background(LiveDesign.accentDim, ChromeShape)
                    .padding(horizontal = 12.dp, vertical = 8.dp),
                horizontalArrangement = Arrangement.spacedBy(8.dp),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                PadlockGlyph(
                    tint = LiveDesign.accent.copy(alpha = 0.9f),
                    filled = true,
                    modifier = Modifier.size(11.dp, 14.dp),
                )
                Text(
                    banner,
                    style = chromeStyle(11.5f, FontWeight.Medium),
                    color = LiveDesign.accent.copy(alpha = 0.9f),
                    maxLines = 2,
                )
            }
        }

        // Landed Kelvin / drum selection is owned by the panel so the fixed
        // fine-adjust row (below this weight slot) can read the same value.
        val landed =
            lastByMode.getOrNull(modeIndex)?.takeIf { it.isNotBlank() }
                ?: mode.request.currentValue
        val drumLabels =
            if (isKelvinMode) {
                WbPickerPolicy.kelvinOptions(
                    cameraAdvertised = mode.request.options,
                    liveLabel = landed,
                )
            } else {
                mode.request.options
            }
        val requestForDrum = mode.request.copy(currentValue = landed, options = drumLabels)
        val options = commandControlOptions(requestForDrum, pendingControl, drumInteractive)
        val selectedLabel =
            options.firstOrNull { it.selected }?.label
                ?: options.firstOrNull()?.label
                ?: landed

        // Flexible body — drum or tint pad only. Fine-adjust + mode bar are
        // fixed below so short landscape panels cannot clip ±10 under the wheel.
        Box(
            Modifier.fillMaxWidth().weight(1f, fill = true),
            contentAlignment = Alignment.Center,
        ) {
            if (isTintMode) {
                val tintAvailable = mode.request.options.isNotEmpty()
                val tintLabel = landed.ifBlank { "Neutral" }
                WhiteBalanceTintPad(
                    currentLabel = tintLabel,
                    available = tintAvailable,
                    interactive = drumInteractive && tintAvailable,
                    onCommit = { label ->
                        if (modeIndex in lastByMode.indices) lastByMode[modeIndex] = label
                        if (
                            modeIndex !in lastAppliedByMode.indices
                                || label != lastAppliedByMode[modeIndex]
                        ) {
                            if (modeIndex in lastAppliedByMode.indices) {
                                lastAppliedByMode[modeIndex] = label
                            }
                            onSelect(mode.request, label)
                        }
                    },
                    modifier = Modifier.fillMaxWidth(),
                )
            } else {
                val optionDescription =
                    stringResource(R.string.camera_picker_options_description, mode.label)
                key(modeIndex) {
                    AccentDrumWheel(
                        options = options.map { it.label },
                        selection = selectedLabel,
                        interactive = drumInteractive,
                        markedValues = mode.markedValues,
                        // −10 / +10 flank the gold selected Kelvin in the centre band.
                        sideAdjust =
                            if (isKelvinMode) {
                                DrumSideAdjust(
                                    minusEnabled =
                                        drumInteractive &&
                                            WbPickerPolicy.canFineAdjust(
                                                from = selectedLabel,
                                                delta = -WbPickerPolicy.FINE_STEP_KELVIN,
                                            ),
                                    plusEnabled =
                                        drumInteractive &&
                                            WbPickerPolicy.canFineAdjust(
                                                from = selectedLabel,
                                                delta = WbPickerPolicy.FINE_STEP_KELVIN,
                                            ),
                                    onMinus = {
                                        applyKelvinFineStep(
                                            modeIndex = modeIndex,
                                            lastByMode = lastByMode,
                                            lastAppliedByMode = lastAppliedByMode,
                                            current = selectedLabel,
                                            delta = -WbPickerPolicy.FINE_STEP_KELVIN,
                                            request = mode.request,
                                            onSelect = onSelect,
                                            suppressUntil = { suppressDrumSettleUntil = it },
                                        )
                                    },
                                    onPlus = {
                                        applyKelvinFineStep(
                                            modeIndex = modeIndex,
                                            lastByMode = lastByMode,
                                            lastAppliedByMode = lastAppliedByMode,
                                            current = selectedLabel,
                                            delta = WbPickerPolicy.FINE_STEP_KELVIN,
                                            request = mode.request,
                                            onSelect = onSelect,
                                            suppressUntil = { suppressDrumSettleUntil = it },
                                        )
                                    },
                                )
                            } else {
                                null
                            },
                        modifier =
                            Modifier
                                .fillMaxWidth()
                                .semantics {
                                    contentDescription =
                                        if (isKelvinMode) {
                                            "$optionDescription. Use minus 10 and plus 10 " +
                                                "beside the selected value to fine-adjust."
                                        } else {
                                            optionDescription
                                        }
                                },
                        onSettle = { settled ->
                            if (android.os.SystemClock.uptimeMillis() < suppressDrumSettleUntil) {
                                return@AccentDrumWheel
                            }
                            if (settled.isEmpty()) return@AccentDrumWheel
                            if (modeIndex in lastByMode.indices) {
                                lastByMode[modeIndex] = settled
                            }
                            // iOS: apply when settled != lastApplied (not vs open-time current).
                            val lastApplied =
                                lastAppliedByMode.getOrNull(modeIndex).orEmpty()
                            if (settled != lastApplied) {
                                if (modeIndex in lastAppliedByMode.indices) {
                                    lastAppliedByMode[modeIndex] = settled
                                }
                                onSelect(mode.request, settled)
                            }
                        },
                    )
                }
            }
        }

        // No in-panel "Applying change…" — iOS is silent while the drum rolls;
        // the bar/tile value is the feedback. Errors still render above.

        if (picker.modes.size > 1) {
            // Fixed-height mode bar (never in the weight slot) — preserves full
            // KELVIN/PRESET/TINT hit targets when the Tint pad is tall.
            val modeInteractive = drumInteractive
            Row(
                Modifier.fillMaxWidth().wrapContentHeight(),
                horizontalArrangement = Arrangement.spacedBy(10.dp),
            ) {
                picker.modes.forEachIndexed { index, candidate ->
                    val selected = index == modeIndex
                    Column(
                        Modifier
                            .weight(1f)
                            .alpha(if (modeInteractive) 1f else 0.55f)
                            .background(
                                if (selected) {
                                    LiveDesign.accentDim
                                } else {
                                    LiveDesign.background.copy(alpha = 0.28f)
                                },
                                ChromeShape,
                            )
                            .border(
                                1.5.dp,
                                if (selected) LiveDesign.accent else LiveDesign.hairline,
                                ChromeShape,
                            )
                            .chromeClickable(enabled = modeInteractive) {
                                if (index == modeIndex) return@chromeClickable
                                selectedMode = index
                                suppressDrumSettleUntil = 0L
                                candidate.activateRequest?.let { activate ->
                                    onSelect(activate, activate.currentValue)
                                }
                                // iOS: apply the mode's landed value when switching
                                // circuits (WB Kelvin↔Preset, ISO bases). Skip Tint
                                // (pad only), Focus (independent tabs), Shutter
                                // (mode write is activateRequest only), Auto ISO On
                                // (ISO auto only — no ISO write while camera owns ISO).
                                val isTint =
                                    candidate.request.control == CameraControl.WHITE_BALANCE_TINT
                                val skipApply =
                                    !candidate.applyValueOnActivate ||
                                        isTint ||
                                        picker.kind == MonitorPickerKind.FOCUS ||
                                        picker.kind == MonitorPickerKind.SHUTTER
                                if (!skipApply) {
                                    val value =
                                        lastByMode.getOrNull(index)?.takeIf { it.isNotBlank() }
                                            ?: candidate.request.currentValue
                                    if (value.isNotBlank()) {
                                        onSelect(candidate.request, value)
                                    }
                                }
                            }
                            .padding(
                                vertical =
                                    when {
                                        candidate.detail != null -> 9.dp
                                        // Compact tabs under Tint pad free D-pad clearance.
                                        isTintMode -> 8.dp
                                        else -> 12.dp
                                    },
                            ),
                        horizontalAlignment = Alignment.CenterHorizontally,
                        verticalArrangement = Arrangement.spacedBy(3.dp),
                    ) {
                        Text(
                            candidate.label.uppercase(),
                            style =
                                chromeStyle(13f, FontWeight.Bold).copy(letterSpacing = 0.5.sp),
                            color = if (selected) LiveDesign.accent else LiveDesign.muted,
                            maxLines = 1,
                        )
                        candidate.detail?.let { detail ->
                            Text(
                                detail,
                                style = chromeStyle(11f, FontWeight.Medium, mono = true),
                                color = if (selected) LiveDesign.accent else LiveDesign.muted,
                                maxLines = 1,
                            )
                        }
                    }
                }
            }
        }
    }
}

/** Canvas stand-in for iOS WB preset SF Symbols in the capture bar. */
@Composable
internal fun CaptureWbGlyph(icon: CaptureWbIcon, tint: Color, modifier: Modifier = Modifier) {
    Canvas(modifier.size(20.dp)) {
        val stroke = Stroke(width = 1.5.dp.toPx(), cap = StrokeCap.Round)
        val cx = size.width / 2f
        val cy = size.height / 2f
        when (icon) {
            CaptureWbIcon.AUTO, CaptureWbIcon.PRESET -> {
                val r = size.minDimension * 0.42f
                drawCircle(tint, radius = r, center = Offset(cx, cy), style = stroke)
                // Letter-like crossbar stand-in (A / P read as glyph mark).
                drawLine(
                    tint,
                    Offset(cx - r * 0.35f, cy + r * 0.25f),
                    Offset(cx, cy - r * 0.4f),
                    strokeWidth = stroke.width,
                    cap = StrokeCap.Round,
                )
                drawLine(
                    tint,
                    Offset(cx + r * 0.35f, cy + r * 0.25f),
                    Offset(cx, cy - r * 0.4f),
                    strokeWidth = stroke.width,
                    cap = StrokeCap.Round,
                )
                if (icon == CaptureWbIcon.AUTO) {
                    drawLine(
                        tint,
                        Offset(cx - r * 0.18f, cy + r * 0.05f),
                        Offset(cx + r * 0.18f, cy + r * 0.05f),
                        strokeWidth = stroke.width,
                        cap = StrokeCap.Round,
                    )
                }
            }
            CaptureWbIcon.SUNNY, CaptureWbIcon.NATURAL_AUTO -> {
                drawCircle(tint, radius = size.minDimension * 0.18f, center = Offset(cx, cy))
                val ray = size.minDimension * 0.42f
                val inner = size.minDimension * 0.28f
                repeat(8) { i ->
                    val a = Math.toRadians(i * 45.0)
                    val dx = cos(a).toFloat()
                    val dy = sin(a).toFloat()
                    drawLine(
                        tint,
                        Offset(cx + dx * inner, cy + dy * inner),
                        Offset(cx + dx * ray, cy + dy * ray),
                        strokeWidth = stroke.width,
                        cap = StrokeCap.Round,
                    )
                }
            }
            CaptureWbIcon.CLOUDY, CaptureWbIcon.SHADE -> {
                val path =
                    Path().apply {
                        moveTo(size.width * 0.18f, size.height * 0.58f)
                        cubicTo(
                            size.width * 0.18f,
                            size.height * 0.38f,
                            size.width * 0.38f,
                            size.height * 0.28f,
                            size.width * 0.5f,
                            size.height * 0.36f,
                        )
                        cubicTo(
                            size.width * 0.62f,
                            size.height * 0.22f,
                            size.width * 0.88f,
                            size.height * 0.32f,
                            size.width * 0.82f,
                            size.height * 0.58f,
                        )
                        close()
                    }
                drawPath(path, tint, style = stroke)
                if (icon == CaptureWbIcon.SHADE) {
                    drawCircle(
                        tint,
                        radius = size.minDimension * 0.12f,
                        center = Offset(size.width * 0.72f, size.height * 0.32f),
                    )
                }
            }
            CaptureWbIcon.INCANDESCENT -> {
                drawCircle(
                    tint,
                    radius = size.minDimension * 0.22f,
                    center = Offset(cx, size.height * 0.38f),
                    style = stroke,
                )
                drawRoundRect(
                    tint,
                    topLeft = Offset(cx - size.width * 0.12f, size.height * 0.55f),
                    size = Size(size.width * 0.24f, size.height * 0.28f),
                    cornerRadius = androidx.compose.ui.geometry.CornerRadius(2.dp.toPx()),
                    style = stroke,
                )
            }
            CaptureWbIcon.FLUORESCENT -> {
                drawRoundRect(
                    tint,
                    topLeft = Offset(size.width * 0.12f, size.height * 0.28f),
                    size = Size(size.width * 0.76f, size.height * 0.44f),
                    cornerRadius = androidx.compose.ui.geometry.CornerRadius(size.height * 0.22f),
                    style = stroke,
                )
            }
            CaptureWbIcon.FLASH -> {
                val bolt =
                    Path().apply {
                        moveTo(size.width * 0.55f, size.height * 0.08f)
                        lineTo(size.width * 0.28f, size.height * 0.52f)
                        lineTo(size.width * 0.48f, size.height * 0.52f)
                        lineTo(size.width * 0.4f, size.height * 0.92f)
                        lineTo(size.width * 0.72f, size.height * 0.42f)
                        lineTo(size.width * 0.52f, size.height * 0.42f)
                        close()
                    }
                drawPath(bolt, tint)
            }
        }
    }
}

/** ±10 buttons flanking the gold selected row of a Kelvin drum. */
internal data class DrumSideAdjust(
    val minusEnabled: Boolean,
    val plusEnabled: Boolean,
    val onMinus: () -> Unit,
    val onPlus: () -> Unit,
)

private fun applyKelvinFineStep(
    modeIndex: Int,
    lastByMode: androidx.compose.runtime.snapshots.SnapshotStateList<String>,
    lastAppliedByMode: androidx.compose.runtime.snapshots.SnapshotStateList<String>,
    current: String,
    delta: Int,
    request: CommandControlRequest,
    onSelect: (CommandControlRequest, String) -> Unit,
    suppressUntil: (Long) -> Unit,
) {
    val next = WbPickerPolicy.fineAdjust(from = current, delta = delta) ?: return
    if (next == current) return
    suppressUntil(android.os.SystemClock.uptimeMillis() + 450L)
    if (modeIndex in lastByMode.indices) {
        lastByMode[modeIndex] = next
    }
    if (modeIndex in lastAppliedByMode.indices) {
        lastAppliedByMode[modeIndex] = next
    }
    onSelect(request, next)
}

/**
 * iOS `AccentDrumWheel`: a snapping vertical drum — the centred row renders
 * large in accent between two hairlines, neighbours dim above/below behind a
 * top/bottom fade. Settling on a row calls [onSettle]; the whole wheel dims
 * and stops scrolling when not [interactive] (control lock).
 *
 * Optional [sideAdjust] draws −10 / +10 on either side of the settled row
 * (Kelvin fine-tune) without covering the value itself.
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
    sideAdjust: DrumSideAdjust? = null,
) {
    if (options.isEmpty()) return
    val selectedIndex = options.indexOf(selection).coerceAtLeast(0)
    val listState =
        androidx.compose.foundation.lazy.rememberLazyListState(
            initialFirstVisibleItemIndex = selectedIndex,
        )
    // Snap item *centers* to the viewport center (not item tops → start).
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
    // Centre on [selection] only when it is not already the settled row and the
    // user is not dragging — avoids fighting fling / rapid settles (iOS keeps
    // local drum state and only snaps when the operator is idle).
    LaunchedEffect(options, selection) {
        val index = options.indexOf(selection).coerceAtLeast(0)
        if (listState.isScrollInProgress) return@LaunchedEffect
        if (centeredIndex == index) return@LaunchedEffect
        listState.scrollToItem(index)
    }
    // Apply the row the wheel settles on (iOS applies on drum settle).
    LaunchedEffect(listState, options) {
        androidx.compose.runtime.snapshotFlow { listState.isScrollInProgress to centeredIndex }
            .collect { (scrolling, index) ->
                if (!scrolling) options.getOrNull(index)?.let(onSettle)
            }
    }
    // Prefer preferred height; parent maxHeight (landscape drop-down) may clip.
    androidx.compose.foundation.layout.BoxWithConstraints(
        modifier
            .fillMaxWidth()
            .heightIn(min = rowHeight * 3, max = wheelHeight)
            .height(wheelHeight)
            .alpha(if (interactive) 1f else 0.55f),
        contentAlignment = Alignment.Center,
    ) {
        // Always use the laid-out height so padding matches hairlines in landscape
        // short panels (previously assumed 176.dp while maxHeight was ~128.dp).
        val actualHeight = maxHeight
        val edgePadding = ((actualHeight - rowHeight) / 2).coerceAtLeast(0.dp)
        androidx.compose.foundation.lazy.LazyColumn(
            state = listState,
            flingBehavior = fling,
            userScrollEnabled = interactive,
            contentPadding =
                androidx.compose.foundation.layout.PaddingValues(vertical = edgePadding),
            modifier =
                Modifier.fillMaxWidth()
                    .height(actualHeight)
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
            items(options.size, key = { options[it] }) { index ->
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
        // Hairlines bracketing the settled row (centre of actualHeight).
        Box(
            Modifier.fillMaxWidth().height(1.dp).offset(y = -rowHeight / 2)
                .background(LiveDesign.hairlineStrong),
        )
        Box(
            Modifier.fillMaxWidth().height(1.dp).offset(y = rowHeight / 2)
                .background(LiveDesign.hairlineStrong),
        )
        // −10 / +10 on either side of the selected Kelvin — always on when set.
        sideAdjust?.let { adjust ->
            Row(
                Modifier
                    .fillMaxWidth()
                    .height(rowHeight)
                    .padding(horizontal = 4.dp),
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.SpaceBetween,
            ) {
                KelvinSideStepButton(
                    label = "−10",
                    enabled = adjust.minusEnabled,
                    contentDescription = "Decrease Kelvin by 10",
                    onClick = adjust.onMinus,
                )
                // Leave the centre open so the gold selected value stays readable.
                Box(Modifier.weight(1f))
                KelvinSideStepButton(
                    label = "+10",
                    enabled = adjust.plusEnabled,
                    contentDescription = "Increase Kelvin by 10",
                    onClick = adjust.onPlus,
                )
            }
        }
    }
}

@Composable
private fun KelvinSideStepButton(
    label: String,
    enabled: Boolean,
    contentDescription: String,
    onClick: () -> Unit,
) {
    Box(
        Modifier
            .height(40.dp)
            .width(56.dp)
            .alpha(if (enabled) 1f else 0.35f)
            .background(LiveDesign.accentDim, ChromeShape)
            .border(
                1.5.dp,
                if (enabled) LiveDesign.accent else LiveDesign.hairline,
                ChromeShape,
            )
            .chromeClickable(enabled = enabled, onClick = onClick)
            .semantics { this.contentDescription = contentDescription },
        contentAlignment = Alignment.Center,
    ) {
        Text(
            label,
            style = chromeStyle(14f, FontWeight.Bold),
            color = if (enabled) LiveDesign.accent else LiveDesign.faint,
            maxLines = 1,
        )
    }
}
