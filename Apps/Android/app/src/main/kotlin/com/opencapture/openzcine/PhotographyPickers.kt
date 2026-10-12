package com.opencapture.openzcine

import com.opencapture.opencine.cameracontrols.CaptureDrumWheel
import com.opencapture.opencine.nikon.StillPickerLadders
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
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
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.opencapture.opencine.nikon.CameraControl
import com.opencapture.opencine.nikon.CameraPropertySnapshot
import com.opencapture.openzcine.settings.PanelCloseButton

/**
 * Mode-aware write gates and drive rules for the photography (stills) pickers. The ladders the
 * pickers fall back to live in Core ([StillPickerLadders]); camera-advertised enums take
 * precedence at the presentation layer.
 */
internal object StillPickerPolicy {
    /**
     * The DRIVE drum's options: the body's advertised SET, in RELEASE order, minus the two
     * positions this drum does not own.
     *
     * Advertised beats invented — a body is never offered a mode it lacks (#274) — but advertised
     * ORDER is not the body's menu order. The ZR enumerates by raw value, and the raws interleave:
     * Single `0x0001`, Continuous H `0x0002`, Continuous L `0x8010`, Self-timer `0x8011`,
     * Continuous H+ `0x8019`. So the drum read Single · CH · CL · CH+, which is neither the
     * camera's wheel nor any Z body's. [StillPickerLadders.DRIVE_OPTIONS] is that release order,
     * so the advertised set is kept and this ordering applied over it.
     *
     * Anything advertised that this build does not know is kept after the modes it can order,
     * rather than dropped — a newer body's position stays reachable even when its place is a guess.
     *
     * Twin of the shared core's `StillDriveMode.driveDrumOptions`; both are tested against the same
     * table so the wheel cannot read one order on iPhone and another here.
     */
    fun driveDrumOptions(advertised: List<String>): List<String> {
        val offered = advertised.filterNot { it == SELF_TIMER_LABEL || it == "Quick" }
        if (offered.isEmpty()) return emptyList()
        val known = StillPickerLadders.DRIVE_OPTIONS.filter(offered::contains)
        return known + offered.filterNot(StillPickerLadders.DRIVE_OPTIONS::contains)
    }

    /** Drive modes that keep firing while the shutter stays pressed. */
    val CONTINUOUS_DRIVES: Set<String> =
        setOf("Continuous H", "Continuous L", "Continuous H+", "C15", "C30", "C60", "C120")

    /** The body's own self-timer release-mode label. */
    const val SELF_TIMER_LABEL: String = "Self-timer"

    private val USER_BANKS = setOf("U1", "U2", "U3", "U4")

    /**
     * Mode-aware manual gate for stills sensitivity (iOS `stillAllowsManualISO`):
     * the full-auto and scene programs own sensitivity outright, so Manual only
     * offers itself in P/S/A/M and the user banks.
     */
    fun allowsManualISO(exposureMode: String?): Boolean =
        exposureMode in listOf("P", "S", "A", "M") || exposureMode in USER_BANKS

    /** The stills program actually driving exposure: a U bank runs as its inner program. */
    fun effectiveProgram(exposureMode: String?, userModeProgram: String?): String {
        val mode = exposureMode.orEmpty()
        if (mode.startsWith("U")) return userModeProgram ?: mode
        return mode
    }

    /**
     * Mode-aware write gates for the stills exposure tiles (iOS
     * `stillAllowsShutterControl` / `stillAllowsIrisControl`): the body owns
     * shutter outside M/S and aperture outside M/A. An unknown program stays
     * enabled rather than guessing a lock. [verify-on-HW]
     */
    fun allowsShutterControl(exposureMode: String?, userModeProgram: String?): Boolean {
        val program = effectiveProgram(exposureMode, userModeProgram)
        return program.isEmpty() || program == "M" || program == "S"
    }

    fun allowsIrisControl(exposureMode: String?, userModeProgram: String?): Boolean {
        val program = effectiveProgram(exposureMode, userModeProgram)
        return program.isEmpty() || program == "M" || program == "A"
    }

    /** Whether the U banks' inner-program tab is settable (iOS `pickerModeDisabled`). */
    fun allowsUserModeProgram(exposureMode: String?): Boolean = exposureMode in USER_BANKS
}

/** The Timer tab's display value ("Off" / "5s") — iOS `photoTimerLabel`. */
internal fun photoTimerLabel(delaySeconds: Int): String =
    if (delaySeconds > 0) "${delaySeconds}s" else "Off"

/** Parses an App-timer label back to seconds ("Off" → 0). */
internal fun photoTimerSeconds(label: String): Int =
    label.removeSuffix("s").toIntOrNull() ?: 0

/**
 * The Image-quality drum pair decomposed from / composed into the camera's
 * compression label (Kotlin mirror of core `StillQualityConfiguration`, keyed
 * on the label the snapshot already carries instead of the raw code).
 */
internal data class StillQualityConfig(
    val rawEnabled: Boolean,
    val tier: String,
    val starred: Boolean,
) {
    /** The write label for this pair; null for the unwritable both-off state. */
    fun compressionLabel(): String? {
        val star = if (starred && tier != TIER_OFF) "★" else ""
        return when {
            rawEnabled && tier == TIER_OFF -> "RAW"
            rawEnabled -> "RAW+JPEG $tier$star"
            tier != TIER_OFF -> "JPEG $tier$star"
            else -> null
        }
    }

    companion object {
        const val TIER_OFF = "Off"
        val TIER_OPTIONS: List<String> = listOf(TIER_OFF, "Basic", "Normal", "Fine")

        /** Decodes a snapshot compression label; null for TIFF/unknown forms. */
        fun parse(label: String?): StillQualityConfig? {
            if (label == null) return null
            if (label == "RAW") return StillQualityConfig(true, TIER_OFF, starred = false)
            val raw = label.startsWith("RAW+JPEG ")
            val jpeg = label.startsWith("JPEG ")
            if (!raw && !jpeg) return null
            val suffix = label.substringAfter(' ').substringAfter("JPEG ").ifEmpty { return null }
            val starred = suffix.endsWith("★")
            val tier = suffix.removeSuffix("★")
            if (tier !in TIER_OPTIONS || tier == TIER_OFF) return null
            return StillQualityConfig(rawEnabled = raw, tier = tier, starred = starred)
        }
    }
}

/**
 * Projects the photography capture strip's nine tiles with their stills
 * pickers (iOS `photographyCaptureValues` + the stills `CameraPicker` set):
 * MODE · ISO · SHUTTER · IRIS · DRIVE · FOCUS · WB · METER · PROFILE, in the
 * shared `MonitorCaptureSettingPresentation` shape so the movie strip's cells,
 * active states, and picker panel all reuse unchanged.
 *
 * The camera is source of truth: currents come from the polled snapshot,
 * camera-advertised enums (stills shutter, lens apertures) take precedence
 * over the iOS fallback ladders, and gating derives from the body's program.
 */
internal fun photographyCaptureSettings(
    properties: CameraPropertySnapshot,
    wbPicker: MonitorPickerPresentation?,
    photoTimerDelaySeconds: Int,
): List<MonitorCaptureSettingPresentation> {
    val exposureMode = properties.exposureMode
    val userProgram = properties.userModeProgram

    /**
     * The connected body's advertised values for a control, in the body's order, falling back to
     * the conservative ladder only while the descriptor has not landed. The whole of #274 is that
     * these lists must come from the body, not from a union of the Z lineup.
     */
    fun advertised(control: CameraControl, fallback: List<String>): List<String> =
        properties.controlCapabilities.options(control).ifEmpty { fallback }

    fun flat(
        kind: MonitorPickerKind,
        title: String,
        subtitle: String,
        control: CameraControl,
        options: List<String>,
        current: String?,
        showsPicker: Boolean = true,
    ): MonitorPickerPresentation? {
        if (!showsPicker || options.isEmpty()) return null
        // Unknown stays blank: the drum seats on its first label without claiming it.
        val value = current?.takeIf { it in options }.orEmpty()
        return MonitorPickerPresentation(
            kind = kind,
            title = title,
            subtitle = subtitle,
            modes =
                listOf(
                    MonitorPickerModePresentation(
                        label = title,
                        request =
                            CommandControlRequest(
                                title = title,
                                control = control,
                                currentValue = value,
                                options = options,
                            ),
                    ),
                ),
        )
    }

    // MODE — the main program drum plus the U banks' inner program (iOS stillMode).
    val modeOptions =
        advertised(CameraControl.EXPOSURE_MODE, StillPickerLadders.MODE_OPTIONS)
    val userModeOptions =
        advertised(CameraControl.STILL_USER_MODE_PROGRAM, StillPickerLadders.USER_MODE_OPTIONS)
    val modePicker =
        MonitorPickerPresentation(
            kind = MonitorPickerKind.MODE,
            title = "MODE",
            subtitle = "Exposure program",
            modes =
                listOf(
                    MonitorPickerModePresentation(
                        label = "Mode",
                        request =
                            CommandControlRequest(
                                title = "MODE",
                                control = CameraControl.EXPOSURE_MODE,
                                currentValue = exposureMode?.takeIf { it in modeOptions }.orEmpty(),
                                options = modeOptions,
                            ),
                        applyValueOnActivate = false,
                    ),
                    MonitorPickerModePresentation(
                        label = "U Mode",
                        request =
                            CommandControlRequest(
                                title = "MODE",
                                control = CameraControl.STILL_USER_MODE_PROGRAM,
                                currentValue = userProgram.orEmpty(),
                                options = userModeOptions,
                            ),
                        applyValueOnActivate = false,
                        // A bank's inner program is settable only while that bank is active —
                        // and only on a body that has banks at all.
                        disabled = !StillPickerPolicy.allowsUserModeProgram(exposureMode),
                    ),
                ),
        )

    // ISO — Auto hands sensitivity to the body (drum tracks its live pick,
    // locked); Manual writes the stills ladder, mode-aware (iOS stillISO).
    val liveISO = properties.iso?.toString()
    val isoOptions =
        if (liveISO != null && liveISO !in StillPickerLadders.ISO_OPTIONS) {
            (StillPickerLadders.ISO_OPTIONS + liveISO)
                .sortedBy { it.toLongOrNull() ?: Long.MAX_VALUE }
        } else {
            StillPickerLadders.ISO_OPTIONS
        }
    val isoCurrent = liveISO?.takeIf { it in isoOptions }.orEmpty()
    val allowsManualISO = StillPickerPolicy.allowsManualISO(exposureMode)
    fun isoMode(auto: Boolean) =
        MonitorPickerModePresentation(
            label = if (auto) "Auto" else "Manual",
            request =
                CommandControlRequest(
                    title = "ISO",
                    control = CameraControl.STILL_ISO,
                    currentValue = isoCurrent,
                    options = isoOptions,
                ),
            activateRequest =
                CommandControlRequest(
                    title = "ISO",
                    control = CameraControl.STILL_ISO_AUTO,
                    currentValue = if (auto) "On" else "Off",
                    options = listOf("On", "Off"),
                ),
            // Auto: no ISO write on activate (the body owns the value).
            // Manual: iOS applies the drum value right after Auto Off.
            applyValueOnActivate = !auto,
            drumLocked = auto,
            disabled = !auto && !allowsManualISO,
        )
    val isoPicker =
        MonitorPickerPresentation(
            kind = MonitorPickerKind.ISO,
            title = "ISO",
            subtitle = "Sensitivity",
            modes = listOf(isoMode(auto = true), isoMode(auto = false)),
            // Camera truth: the body's Auto-ISO readback picks the open tab.
            initialModeIndex = if (properties.isoAuto == true) 0 else 1,
            drumLockBanner =
                if (allowsManualISO) {
                    "Auto ISO is on — the camera sets sensitivity. " +
                        "Switch to Manual to choose a value."
                } else {
                    "Manual ISO needs a P/S/A/M program. The camera is setting sensitivity."
                },
        )

    // SHUTTER — the body's stills speed enum with the iOS ladder fallback;
    // grayed while the program owns shutter (outside M/S).
    val allowsShutter =
        StillPickerPolicy.allowsShutterControl(exposureMode, userProgram)
    val cameraShutter =
        properties.controlCapabilities.options(CameraControl.STILL_SHUTTER)
            .takeIf { it.size > 1 }
    val shutterPicker =
        flat(
            kind = MonitorPickerKind.SHUTTER,
            title = "SHUTTER",
            subtitle = "Speed",
            control = CameraControl.STILL_SHUTTER,
            options = cameraShutter ?: StillPickerLadders.SHUTTER_OPTIONS,
            current = properties.shutterSpeed,
            showsPicker = allowsShutter,
        )

    // IRIS — lens-aware apertures; grayed while the program owns aperture (outside M/A).
    val allowsIris = StillPickerPolicy.allowsIrisControl(exposureMode, userProgram)
    val cameraApertures =
        properties.controlCapabilities.options(CameraControl.STILL_IRIS)
            .takeIf { it.isNotEmpty() }
    val irisPicker =
        flat(
            kind = MonitorPickerKind.IRIS,
            title = "IRIS",
            subtitle = "Aperture",
            control = CameraControl.STILL_IRIS,
            options = cameraApertures ?: StillPickerLadders.IRIS_OPTIONS,
            current = properties.iris,
            showsPicker = allowsIris,
        )

    // DRIVE — release mode plus the two mutually-exclusive timers (iOS stillDrive).
    val builtInTimerOn = properties.stillCaptureMode == StillPickerPolicy.SELF_TIMER_LABEL
    // The body's own release-mode order (Z6III: Single, CL, CH, CH+, …), minus the two positions
    // the app owns: Quick is dial-only and Self-timer belongs to the Built-in Timer tab.
    val driveOptions =
        StillPickerPolicy.driveDrumOptions(
                advertised(CameraControl.STILL_DRIVE, StillPickerLadders.DRIVE_OPTIONS))
            .ifEmpty { StillPickerLadders.DRIVE_OPTIONS }
    val drivePicker =
        MonitorPickerPresentation(
            kind = MonitorPickerKind.DRIVE,
            title = "DRIVE",
            subtitle = "Release mode",
            modes =
                listOf(
                    MonitorPickerModePresentation(
                        label = "Drive",
                        request =
                            CommandControlRequest(
                                title = "DRIVE",
                                control = CameraControl.STILL_DRIVE,
                                currentValue =
                                    properties.stillCaptureMode?.takeIf { it in driveOptions }.orEmpty(),
                                options = driveOptions,
                            ),
                        applyValueOnActivate = false,
                        // An engaged body timer owns the release mode.
                        disabled = builtInTimerOn,
                    ),
                    MonitorPickerModePresentation(
                        label = "Built-in Timer",
                        request =
                            CommandControlRequest(
                                // The title routes this tab's writes to the
                                // engage/restore logic, never a raw drive write.
                                title = "Built-in Timer",
                                control = CameraControl.STILL_DRIVE,
                                currentValue =
                                    when (properties.stillCaptureMode) {
                                        null -> ""
                                        StillPickerPolicy.SELF_TIMER_LABEL -> "On"
                                        else -> "Off"
                                    },
                                options = listOf("Off", "On"),
                            ),
                        applyValueOnActivate = false,
                        disabled = photoTimerDelaySeconds > 0,
                        showsTimerShots = true,
                    ),
                    MonitorPickerModePresentation(
                        label = "App-timer",
                        request =
                            CommandControlRequest(
                                title = "App-timer",
                                control = CameraControl.STILL_DRIVE,
                                currentValue = photoTimerLabel(photoTimerDelaySeconds),
                                options = StillPickerLadders.APP_TIMER_OPTIONS,
                            ),
                        applyValueOnActivate = false,
                        disabled = builtInTimerOn,
                        showsTimerShots = true,
                    ),
                ),
        )

    // FOCUS — Mode | Area | Subject, three independent stills settings. In photo mode the facade
    // describes the STILLS focus properties into these lists, so Area carries the body's
    // dynamic-area and 3D-tracking positions rather than the movie set.
    val focusModeOptions =
        advertised(CameraControl.STILL_FOCUS_MODE, StillPickerLadders.FOCUS_MODE_OPTIONS)
    val focusAreaOptions =
        advertised(CameraControl.STILL_FOCUS_AREA, StillPickerLadders.FOCUS_AREA_OPTIONS)
    val focusSubjectOptions =
        advertised(CameraControl.STILL_FOCUS_SUBJECT, StillPickerLadders.FOCUS_SUBJECT_OPTIONS)
    val focusPicker =
        MonitorPickerPresentation(
            kind = MonitorPickerKind.FOCUS,
            title = "FOCUS",
            subtitle = "AF mode",
            modes =
                listOf(
                    MonitorPickerModePresentation(
                        label = "Mode",
                        request =
                            CommandControlRequest(
                                title = "FOCUS",
                                control = CameraControl.STILL_FOCUS_MODE,
                                currentValue =
                                    properties.activeFocusMode(photography = true)
                                        ?.takeIf { it in focusModeOptions }.orEmpty(),
                                options = focusModeOptions,
                            ),
                        applyValueOnActivate = false,
                    ),
                    MonitorPickerModePresentation(
                        label = "Area",
                        request =
                            CommandControlRequest(
                                title = "FOCUS",
                                control = CameraControl.STILL_FOCUS_AREA,
                                currentValue =
                                    properties.focusArea?.takeIf { it in focusAreaOptions }.orEmpty(),
                                options = focusAreaOptions,
                            ),
                        applyValueOnActivate = false,
                    ),
                    MonitorPickerModePresentation(
                        label = "Subject",
                        request =
                            CommandControlRequest(
                                title = "FOCUS",
                                control = CameraControl.STILL_FOCUS_SUBJECT,
                                currentValue =
                                    properties.focusSubject?.takeIf { it in focusSubjectOptions }.orEmpty(),
                                options = focusSubjectOptions,
                            ),
                        applyValueOnActivate = false,
                    ),
                ),
        )

    val meterPicker =
        flat(
            kind = MonitorPickerKind.METER,
            title = "METER",
            subtitle = "Metering pattern",
            control = CameraControl.STILL_METER,
            options = advertised(CameraControl.STILL_METER, StillPickerLadders.METER_OPTIONS),
            current = properties.meteringMode,
        )

    val profilePicker =
        flat(
            kind = MonitorPickerKind.PROFILE,
            title = "PROFILE",
            subtitle = "Picture control",
            control = CameraControl.STILL_PICTURE_CONTROL,
            options =
                advertised(
                    CameraControl.STILL_PICTURE_CONTROL, StillPickerLadders.PICTURE_OPTIONS),
            current = properties.pictureControl,
        )

    fun tile(
        kind: MonitorPickerKind,
        label: String,
        value: String?,
        widestValue: String,
        picker: MonitorPickerPresentation?,
        dimmed: Boolean = false,
    ) = MonitorCaptureSettingPresentation(
        kind = kind,
        label = label,
        value = captureBarDisplayValue(value ?: "—"),
        widestValue = widestValue,
        picker = picker,
        unavailableReason = null,
        dimmed = dimmed,
    )

    // iOS `photographyCaptureValues`: same tiles, same order, same width pins.
    return listOf(
        tile(MonitorPickerKind.MODE, "MODE", properties.exposureMode, "Auto", modePicker),
        tile(MonitorPickerKind.ISO, "ISO", properties.iso?.toString(), "25600", isoPicker),
        tile(
            MonitorPickerKind.SHUTTER,
            "SHUTTER",
            properties.shutterSpeed,
            "1/16000",
            shutterPicker,
            // The program owns shutter outside M/S — live readout, grayed tile.
            dimmed = !allowsShutter,
        ),
        tile(
            MonitorPickerKind.IRIS,
            "IRIS",
            properties.iris,
            "f/2.8",
            irisPicker,
            dimmed = !allowsIris,
        ),
        tile(
            MonitorPickerKind.DRIVE,
            "DRIVE",
            compactDriveLabel(properties.stillCaptureMode),
            "Single",
            drivePicker,
        ),
        tile(
            MonitorPickerKind.FOCUS,
            "FOCUS",
            // Stills AF mode only — leftover movie AF-F on this tile is #272.
            properties.activeFocusMode(photography = true),
            "Wide-L",
            focusPicker,
        ),
        tile(
            MonitorPickerKind.WHITE_BALANCE,
            "WB",
            stillWhiteBalanceValue(properties),
            "5560K",
            wbPicker,
        ),
        tile(MonitorPickerKind.METER, "METER", properties.meteringMode, "Matrix", meterPicker),
        tile(
            MonitorPickerKind.PROFILE,
            "PROFILE",
            compactPictureControlLabel(properties.pictureControl),
            "Auto",
            profilePicker,
        ),
    )
}

/**
 * The photo top-deck pill pickers (iOS `CameraPicker.isTopBar` stills set):
 * SIZE (Area | Size tabs) and QUALITY (the dual-drum panel).
 */
internal fun photographyTopBarPickers(
    properties: CameraPropertySnapshot,
): Map<MonitorPickerKind, MonitorPickerPresentation> {
    val cameraSizes =
        properties.controlCapabilities.options(CameraControl.STILL_IMAGE_SIZE)
            .takeIf { it.isNotEmpty() }
    val sizePicker =
        MonitorPickerPresentation(
            kind = MonitorPickerKind.SIZE,
            title = "SIZE",
            subtitle = "Area · size",
            modes =
                listOf(
                    MonitorPickerModePresentation(
                        label = "Area",
                        request =
                            CommandControlRequest(
                                title = "SIZE",
                                control = CameraControl.STILL_IMAGE_AREA,
                                currentValue =
                                    properties.imageArea
                                        ?.takeIf { it in StillPickerLadders.AREA_OPTIONS }.orEmpty(),
                                options = StillPickerLadders.AREA_OPTIONS,
                            ),
                        applyValueOnActivate = false,
                    ),
                    MonitorPickerModePresentation(
                        label = "Size",
                        request =
                            CommandControlRequest(
                                title = "SIZE",
                                control = CameraControl.STILL_IMAGE_SIZE,
                                currentValue =
                                    (cameraSizes ?: StillPickerLadders.SIZE_OPTIONS).let { all ->
                                        properties.imageSize?.takeIf { it in all }.orEmpty()
                                    },
                                options = cameraSizes ?: StillPickerLadders.SIZE_OPTIONS,
                            ),
                        applyValueOnActivate = false,
                    ),
                ),
        )
    val qualityPicker =
        MonitorPickerPresentation(
            kind = MonitorPickerKind.QUALITY,
            title = "QUALITY",
            subtitle = "RAW · JPEG/HEIF",
            modes =
                listOf(
                    MonitorPickerModePresentation(
                        label = "QUALITY",
                        request =
                            CommandControlRequest(
                                title = "QUALITY",
                                control = CameraControl.STILL_QUALITY,
                                currentValue = properties.compression.orEmpty(),
                                options = StillPickerLadders.QUALITY_OPTIONS,
                            ),
                    ),
                ),
        )
    return mapOf(
        MonitorPickerKind.SIZE to sizePicker,
        MonitorPickerKind.QUALITY to qualityPicker,
    )
}

/** `[−] n [+]` stepper for the photo timers' shot count (iOS `timerShotsRow`). */
@Composable
internal fun TimerShotsRow(
    count: Int,
    enabled: Boolean,
    onAdjust: (Int) -> Unit,
) {
    Row(
        Modifier
            .fillMaxWidth()
            .background(LiveDesign.background.copy(alpha = 0.28f), ChromeShape)
            .border(1.dp, LiveDesign.hairline, ChromeShape)
            .padding(horizontal = 12.dp, vertical = 6.dp)
            .alpha(if (enabled) 1f else 0.35f),
        horizontalArrangement = Arrangement.spacedBy(12.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Text(
            "SHOTS",
            style = chromeStyle(12f, FontWeight.SemiBold).copy(letterSpacing = 1.sp),
            color = LiveDesign.muted,
        )
        Box(Modifier.weight(1f))
        TimerShotsStepButton("−", enabled = enabled && count > 1) { onAdjust(-1) }
        Text(
            "$count",
            style = chromeStyle(17f, FontWeight.SemiBold, mono = true),
            color = LiveDesign.text,
            modifier = Modifier.width(28.dp),
            maxLines = 1,
        )
        TimerShotsStepButton("+", enabled = enabled && count < 9) { onAdjust(1) }
    }
}

@Composable
private fun TimerShotsStepButton(
    symbol: String,
    enabled: Boolean,
    onClick: () -> Unit,
) {
    Box(
        Modifier
            .size(32.dp)
            .background(LiveDesign.background.copy(alpha = 0.4f), CircleShape)
            .border(1.dp, LiveDesign.hairline, CircleShape)
            .chromeClickable(enabled = enabled, onClick = onClick)
            .alpha(if (enabled) 1f else 0.4f),
        contentAlignment = Alignment.Center,
    ) {
        Text(
            symbol,
            style = chromeStyle(13f, FontWeight.Bold),
            color = if (enabled) LiveDesign.accent else LiveDesign.faint,
        )
    }
}

/**
 * The Image-quality dual-drum panel (iOS `QualityPickerPanel`, on the shared value drum): a RAW
 * On/Off drum with the NEF compression chips beneath, beside a JPEG/HEIF tier wheel
 * with the ★ optimal-quality toggle. The pair composes one image-quality
 * write; NEF compression writes its own property. Turning the last active
 * half off bounces the other half back on.
 */
@Composable
internal fun QualityPickerPanelBody(
    picker: MonitorPickerPresentation,
    nefCompression: String?,
    onSelect: (CommandControlRequest, String) -> Unit,
    onDismiss: () -> Unit,
    /** The body's advertised NEF compressions; the ladder is only a fallback (#274). */
    nefOptions: List<String> = StillPickerLadders.NEF_OPTIONS,
    controlsEnabled: Boolean = true,
    chromeless: Boolean = false,
) {
    val qualityRequest = picker.modes.first().request
    // Seed once from the camera (never re-read per frame — the wheels would
    // jog mid-spin like every other drum).
    var config by remember(picker.kind) {
        mutableStateOf(
            StillQualityConfig.parse(qualityRequest.currentValue)
                ?: StillQualityConfig(rawEnabled = true, tier = "Fine", starred = false),
        )
    }
    var lastApplied by remember(picker.kind) {
        mutableStateOf(qualityRequest.currentValue)
    }

    fun applyIfChanged() {
        if (!controlsEnabled) return
        val label = config.compressionLabel() ?: return
        if (label == lastApplied) return
        lastApplied = label
        onSelect(qualityRequest, label)
    }

    Column(
        Modifier
            .then(if (chromeless) Modifier.fillMaxWidth() else Modifier.fillMaxSize()
                .overlayGlass(ChromeShape)
                .border(1.dp, LiveDesign.hairlineStrong, ChromeShape)
                .padding(horizontal = 20.dp, vertical = 14.dp)),
        verticalArrangement = Arrangement.spacedBy(10.dp),
    ) {
        if (!chromeless) {
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
        }
        Row(
            Modifier
                .fillMaxWidth()
                // Short landscape panels scroll rather than clipping the chips.
                .then(if (chromeless) Modifier else Modifier.verticalScroll(rememberScrollState())),
            horizontalArrangement = Arrangement.spacedBy(16.dp),
        ) {
            // RAW half: On/Off drum + NEF compression, parked while RAW is off.
            Column(
                Modifier.weight(1f),
                verticalArrangement = Arrangement.spacedBy(8.dp),
                horizontalAlignment = Alignment.CenterHorizontally,
            ) {
                QualityColumnCaption("RAW")
                CaptureDrumWheel(
                    options = listOf("On", "Off"),
                    selection = if (config.rawEnabled) "On" else "Off",
                    interactive = controlsEnabled,
                    onSelect = { settled ->
                        if (!controlsEnabled) return@CaptureDrumWheel
                        val enabled = settled == "On"
                        if (enabled == config.rawEnabled) return@CaptureDrumWheel
                        config =
                            if (!enabled && config.tier == StillQualityConfig.TIER_OFF) {
                                // Dropping RAW with the tier off would select
                                // nothing — bounce the tier on.
                                config.copy(rawEnabled = false, tier = "Fine")
                            } else {
                                config.copy(rawEnabled = enabled)
                            }
                        applyIfChanged()
                    },
                )
                Column(
                    Modifier
                        .fillMaxWidth()
                        .alpha(if (config.rawEnabled) 1f else 0.35f),
                    verticalArrangement = Arrangement.spacedBy(6.dp),
                ) {
                    nefOptions.forEach { option ->
                        QualityOptionChip(
                            label = option,
                            active = nefCompression == option,
                            enabled = controlsEnabled && config.rawEnabled,
                        ) {
                            onSelect(
                                CommandControlRequest(
                                    title = "NEF",
                                    control = CameraControl.STILL_RAW_COMPRESSION,
                                    currentValue = nefCompression ?: option,
                                    options = nefOptions,
                                ),
                                option,
                            )
                        }
                    }
                }
            }
            // JPEG/HEIF half: tier drum + the ★ optimal-quality toggle.
            Column(
                Modifier.weight(1f),
                verticalArrangement = Arrangement.spacedBy(8.dp),
                horizontalAlignment = Alignment.CenterHorizontally,
            ) {
                QualityColumnCaption("JPEG · HEIF")
                CaptureDrumWheel(
                    options = StillQualityConfig.TIER_OPTIONS,
                    selection = config.tier,
                    interactive = controlsEnabled,
                    onSelect = { settled ->
                        if (!controlsEnabled) return@CaptureDrumWheel
                        if (settled == config.tier) return@CaptureDrumWheel
                        config =
                            if (settled == StillQualityConfig.TIER_OFF) {
                                if (!config.rawEnabled) {
                                    // Tier off with RAW off — bounce RAW on.
                                    config.copy(
                                        rawEnabled = true,
                                        tier = settled,
                                        starred = false,
                                    )
                                } else {
                                    config.copy(tier = settled, starred = false)
                                }
                            } else {
                                config.copy(tier = settled)
                            }
                        applyIfChanged()
                    },
                )
                val starEnabled = controlsEnabled && config.tier != StillQualityConfig.TIER_OFF
                Box(Modifier.fillMaxWidth().alpha(if (starEnabled) 1f else 0.35f)) {
                    QualityOptionChip(
                        label = "★ Optimal quality",
                        active = config.starred,
                        enabled = starEnabled,
                    ) {
                        config = config.copy(starred = !config.starred)
                        applyIfChanged()
                    }
                }
            }
        }
    }
}

@Composable
private fun QualityColumnCaption(caption: String) {
    Text(
        caption,
        style = chromeStyle(11f, FontWeight.SemiBold, mono = true).copy(letterSpacing = 1.5.sp),
        color = LiveDesign.faint,
        maxLines = 1,
    )
}

@Composable
private fun QualityOptionChip(
    label: String,
    active: Boolean,
    enabled: Boolean,
    onClick: () -> Unit,
) {
    Box(
        Modifier
            .fillMaxWidth()
            .background(
                if (active) LiveDesign.accentDim else LiveDesign.background.copy(alpha = 0.28f),
                ChromeShape,
            )
            .border(
                1.dp,
                if (active) LiveDesign.accent else LiveDesign.hairline,
                ChromeShape,
            )
            .chromeClickable(enabled = enabled, onClick = onClick)
            .padding(vertical = 8.dp),
        contentAlignment = Alignment.Center,
    ) {
        Text(
            label,
            style = chromeStyle(12f, FontWeight.SemiBold),
            color = if (active) LiveDesign.accent else LiveDesign.muted,
            maxLines = 1,
        )
    }
}
