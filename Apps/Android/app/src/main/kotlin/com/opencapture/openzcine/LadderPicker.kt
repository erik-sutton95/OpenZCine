package com.opencapture.openzcine

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.unit.dp
import com.opencapture.opencine.cameracontrols.SheetHeader
import com.opencapture.monitorui.MonitorPalette
import com.opencapture.monitorui.MonitorTypography
import androidx.compose.ui.text.font.FontWeight
import com.opencapture.openzcine.pairing.StartupColors
import androidx.compose.ui.Modifier
import com.opencapture.opencine.appkit.MonitorCaptureField
import com.opencapture.opencine.appkit.MonitorControlModel
import com.opencapture.opencine.cameracontrols.CaptureFormatChoice
import com.opencapture.opencine.cameracontrols.CaptureFormatGroup
import com.opencapture.opencine.cameracontrols.CaptureFormatPicker
import com.opencapture.opencine.nikon.NikonRecordingFormatPresentation
import com.opencapture.opencine.cameracontrols.LadderSheet
import com.opencapture.opencine.cameracontrols.LadderSheetPresentation
import com.opencapture.opencine.cameracontrols.LadderStep
import com.opencapture.opencine.cameracontrols.LadderTab
import com.opencapture.opencine.cameracontrols.LadderWrite
import com.opencapture.opencine.nikon.CameraControl
import com.opencapture.opencine.nikon.NikonOpenCineSession
import com.opencapture.opencine.nikon.WbPickerPolicy
import com.opencapture.opencine.vocabulary.CaptureLadder
import com.opencapture.opencine.vocabulary.CaptureLock
import com.opencapture.opencine.vocabulary.CaptureTint

/**
 * Pickers that draw on [LadderSheet]. QUALITY stays on its own panel: the two wheels
 * compose one compression label, and the NEF chips write a different control.
 */
internal val ladderKinds: Set<MonitorPickerKind> = setOf(
    MonitorPickerKind.ISO,
    MonitorPickerKind.SHUTTER,
    MonitorPickerKind.IRIS,
    MonitorPickerKind.FOCUS,
    MonitorPickerKind.WHITE_BALANCE,
    MonitorPickerKind.RESOLUTION,
    MonitorPickerKind.CODEC,
    MonitorPickerKind.MODE,
    MonitorPickerKind.DRIVE,
    MonitorPickerKind.METER,
    MonitorPickerKind.PROFILE,
    MonitorPickerKind.SIZE,
)

/** The photo timer shot row rides on the drive tabs that ask for it. */
internal fun ladderShowsTimerShots(
    picker: MonitorPickerPresentation,
    tab: LadderTab<CameraControl>,
): Boolean = picker.modes.firstOrNull { it.label == tab.label }?.showsTimerShots == true

/**
 * A typed core drum is the ISO, shutter, iris and white-balance preset circuits.
 * Kelvin grows a label ladder (fine steps), tint draws the pad, and a locked drum
 * only mirrors the camera's label.
 */
internal fun ladderUsesCoreDrum(kind: MonitorPickerKind, mode: MonitorPickerModePresentation): Boolean {
    if (mode.drumLocked) return false
    if (mode.request.control == CameraControl.WHITE_BALANCE_TINT) return false
    if (kind == MonitorPickerKind.WHITE_BALANCE && mode.label.equals("Kelvin", ignoreCase = true)) return false
    return mode.request.control in NikonOpenCineSession.CONTROLS
}

/** The request a ladder write should travel on. The active control wins; a fine value may sit off the list. */
internal fun requestForLadderWrite(
    picker: MonitorPickerPresentation,
    write: LadderWrite<CameraControl>,
): CommandControlRequest? {
    val requests = picker.modes.flatMap { mode -> listOfNotNull(mode.request, mode.activateRequest) }
    return requests.firstOrNull { it.control == write.key && write.value in it.options }
        ?: requests.firstOrNull { it.control == write.key }
}

internal fun videoLadderPresentation(
    picker: MonitorPickerPresentation,
    field: MonitorCaptureField? = null,
): LadderSheetPresentation<CameraControl> {
    val lock = when {
        picker.interactionLocked -> CaptureLock.CAMERA_CONTROL
        picker.drumInteractionLocked -> CaptureLock.AUTO
        else -> null
    }
    val banner = when {
        picker.interactionLocked -> picker.lockBanner
        picker.drumInteractionLocked -> picker.drumLockBanner
        else -> null
    }
    return LadderSheetPresentation(
        title = picker.title,
        subtitle = picker.subtitle,
        tabs = picker.modes.map { mode -> ladderTab(picker.kind, mode, field) },
        initialTab = picker.initialModeIndex,
        lock = lock,
        lockBanner = banner,
    )
}

private fun ladderTab(
    kind: MonitorPickerKind,
    mode: MonitorPickerModePresentation,
    field: MonitorCaptureField?,
): LadderTab<CameraControl> {
    val request = mode.request
    val kelvin = kind == MonitorPickerKind.WHITE_BALANCE && mode.label.equals("Kelvin", ignoreCase = true)
    val apply = mode.applyValueOnActivate &&
        request.control != CameraControl.WHITE_BALANCE_TINT &&
        kind != MonitorPickerKind.FOCUS &&
        kind != MonitorPickerKind.SHUTTER
    return LadderTab(
        label = mode.label,
        key = request.control,
        ladder = CaptureLadder(
            current = request.currentValue,
            values = request.options,
            marked = mode.markedValues,
            lock = if (mode.drumLocked) CaptureLock.AUTO else null,
        ),
        detail = mode.detail,
        activate = mode.activateRequest?.let { LadderWrite(it.control, it.currentValue) },
        applyOnActivate = apply,
        disabled = mode.disabled,
        field = coreField(kind, mode, field),
        tint = tintOf(mode),
        values = if (kelvin) {
            { landed -> WbPickerPolicy.kelvinOptions(request.options, landed) }
        } else {
            null
        },
        steps = stepsOf(mode),
    )
}

private fun coreField(
    kind: MonitorPickerKind,
    mode: MonitorPickerModePresentation,
    field: MonitorCaptureField?,
): MonitorCaptureField? {
    if (field == null || !ladderUsesCoreDrum(kind, mode)) return null
    val offered = mode.request.options.mapNotNull { NikonOpenCineSession.settingValue(mode.request.control, it) }.toSet()
    if (offered.isEmpty()) return field
    val choices = field.choices.filter { it.value in offered }
    return if (choices.isEmpty()) field else field.copy(choices = choices)
}

private fun tintOf(mode: MonitorPickerModePresentation): CaptureTint? {
    if (mode.request.control != CameraControl.WHITE_BALANCE_TINT) return null
    val (amber, green) = WhiteBalanceTintGrid.cellsFromLabel(mode.request.currentValue.ifBlank { "Neutral" })
    return CaptureTint(greenMagenta = green, amberBlue = amber, range = WhiteBalanceTintGrid.cellRange)
}

/**
 * Codec bit depth is two steps beside the codec row (the written label is the depth variant,
 * so it does not land on the drum). Kelvin is the -10/+10 pair, and that value does land.
 */
private fun stepsOf(mode: MonitorPickerModePresentation): ((String) -> Pair<LadderStep, LadderStep>?)? {
    val request = mode.request
    if (request.control == CameraControl.CODEC) {
        return { selected ->
            val depths = request.bitDepths.filter { it.codec == selected }
            if (depths.size != 2) {
                null
            } else {
                val low = depths[0]
                val high = depths[1]
                LadderStep(
                    low.label, low.writeValue, "Record $selected at ${low.label}",
                    selected = request.bitDepthSelection == low.label,
                ) to LadderStep(
                    high.label, high.writeValue, "Record $selected at ${high.label}",
                    selected = request.bitDepthSelection == high.label,
                )
            }
        }
    }
    if (request.control == CameraControl.WHITE_BALANCE && mode.label.equals("Kelvin", ignoreCase = true)) {
        return { selected ->
            fun step(delta: Int, label: String, description: String) = LadderStep(
                label = label,
                value = WbPickerPolicy.fineAdjust(selected, delta),
                description = description,
                lands = true,
            )
            step(-WbPickerPolicy.FINE_STEP_KELVIN, "\u221210", "Decrease Kelvin by 10") to
                step(WbPickerPolicy.FINE_STEP_KELVIN, "+10", "Increase Kelvin by 10")
        }
    }
    return null
}

@Composable
internal fun VideoLadderBody(
    picker: MonitorPickerPresentation,
    field: MonitorCaptureField?,
    control: MonitorControlModel?,
    controlsEnabled: Boolean,
    error: String?,
    unavailable: String?,
    fromTop: Boolean,
    onWrite: (CommandControlRequest, String) -> Unit,
    onClose: () -> Unit,
    onHold: (() -> Unit)?,
    tintLabel: (CaptureTint) -> String,
    tintHelp: String?,
    footer: @Composable (LadderTab<CameraControl>) -> Unit,
    modifier: Modifier = Modifier,
    chromeless: Boolean = false,
) {
    if (picker.kind == MonitorPickerKind.RESOLUTION) {
        val request = picker.modes.singleOrNull()?.request ?: return
        val source = control?.state?.collectAsState()?.value?.snapshot?.let { it.session to it.epoch }
        val choices = request.options.map { token ->
            val format = NikonRecordingFormatPresentation.fromToken(token)
            CaptureFormatChoice(value = token, title = token,
                imageArea = format.imageArea?.let { CaptureFormatGroup(it, it) },
                resolution = format.resolution?.let { CaptureFormatGroup(it, it) },
                frameRate = format.frameRate?.let { CaptureFormatGroup(it, it) })
        }
        Column(modifier.testTag("ladder_sheet"), verticalArrangement = Arrangement.spacedBy(8.dp)) {
            if (!chromeless) SheetHeader(picker.title, picker.subtitle, onClose)
            if (!error.isNullOrBlank()) Text(error, style = MonitorTypography.text(11f, FontWeight.Medium), color = StartupColors.destructive, maxLines = 2)
            if (!controlsEnabled && !unavailable.isNullOrBlank()) Text(unavailable, style = MonitorTypography.text(11f, FontWeight.Medium), color = MonitorPalette.muted, maxLines = 2)
            val banner = if (picker.interactionLocked) picker.lockBanner else if (picker.drumInteractionLocked) picker.drumLockBanner else null
            if (!banner.isNullOrBlank()) Text(banner, style = MonitorTypography.text(11.5f, FontWeight.Medium), color = MonitorPalette.accent, maxLines = 2)
            CaptureFormatPicker(choices = choices, current = request.currentValue,
            enabled = controlsEnabled && !picker.interactionLocked && !picker.drumInteractionLocked,
            sourceIdentity = source ?: request, isCurrent = {
                control?.state?.value?.snapshot?.let { it.session to it.epoch } == source
            }) { choice ->
            if (choice.value in request.options) onWrite(request, choice.value)
            }
        }
        return
    }
    LadderSheet(
        presentation = videoLadderPresentation(picker, field),
        enabled = controlsEnabled,
        onWrite = { write ->
            val request = requestForLadderWrite(picker, write) ?: return@LadderSheet
            onWrite(request, write.value)
        },
        onClose = onClose,
        modifier = modifier,
        control = control,
        fromTop = fromTop,
        chromeless = chromeless,
        error = error,
        unavailable = if (controlsEnabled) null else unavailable,
        onHold = onHold,
        tintLabel = tintLabel,
        tintHelp = tintHelp,
        footer = footer,
    )
}
