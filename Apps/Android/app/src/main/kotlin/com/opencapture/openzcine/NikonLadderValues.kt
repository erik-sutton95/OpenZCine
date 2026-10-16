package com.opencapture.openzcine

import com.opencapture.opencine.cameracontrols.CaptureFormatChoice
import com.opencapture.opencine.cameracontrols.CaptureFormatGroup
import com.opencapture.opencine.nikon.CameraControl
import com.opencapture.opencine.nikon.NikonCapturePopupKind
import com.opencapture.opencine.nikon.NikonCapturePopupState
import com.opencapture.opencine.nikon.NikonControlSetting
import com.opencapture.opencine.nikon.NikonLadderControl
import com.opencapture.opencine.nikon.NikonLadderMode
import com.opencapture.opencine.nikon.NikonRecordingFormatPresentation
import com.opencapture.opencine.nikon.WhiteBalanceTint
import com.opencapture.opencine.nikon.bitDepth
import com.opencapture.opencine.vocabulary.LadderSheetPresentation
import com.opencapture.opencine.vocabulary.LadderTab
import com.opencapture.opencine.vocabulary.LadderWrite

// The Z pickers as the shared Nikon capture popup (OpenCine NikonCapturePopupState): this file
// only hands the session's values to the shared rules and routes the sheet's writes back.

/**
 * Pickers that draw on the shared LadderSheet. QUALITY stays on its own panel: the two wheels
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
    tab: LadderTab<NikonLadderControl>,
): Boolean = (tab.key as? NikonLadderControl.Value)?.let { picker.modes.getOrNull(it.index)?.showsTimerShots } == true

/**
 * The shared popup state for [picker]. Builders that know the body's circuits (ISO, shutter,
 * white balance) attach their facts as [MonitorPickerPresentation.popup]; every other picker is
 * one setting, or independent settings when no tab writes on activation.
 */
internal fun nikonCapturePopup(picker: MonitorPickerPresentation): NikonCapturePopupState {
    val first = picker.modes.firstOrNull()?.request
    val facts = picker.popup ?: NikonCapturePopupState(
        kind = when {
            picker.kind == MonitorPickerKind.IRIS -> NikonCapturePopupKind.APERTURE
            picker.kind == MonitorPickerKind.CODEC -> NikonCapturePopupKind.CODEC
            picker.kind == MonitorPickerKind.WHITE_BALANCE -> NikonCapturePopupKind.WHITE_BALANCE
            picker.kind == MonitorPickerKind.DRIVE -> NikonCapturePopupKind.DRIVE
            picker.kind == MonitorPickerKind.FOCUS || picker.modes.none { it.applyValueOnActivate } ->
                NikonCapturePopupKind.INDEPENDENT_TABS
            else -> NikonCapturePopupKind.SETTINGS
        },
        title = picker.title,
        subtitle = picker.subtitle,
        modes = emptyList(),
        seededTab = picker.initialModeIndex,
        codecDepths = first?.bitDepths.orEmpty(),
        activeCodecDepth = first?.bitDepths?.firstOrNull { it.label == first.bitDepthSelection }?.bitDepth,
        tintCells = picker.modes.firstOrNull { it.request.control == CameraControl.WHITE_BALANCE_TINT }
            ?.let { WhiteBalanceTint.cells(it.request.currentValue.ifBlank { "Neutral" }) }
            ?: (0 to 0),
        tintAvailable = true,
    )
    return facts.copy(
        title = picker.title,
        subtitle = picker.subtitle,
        modes = picker.modes.mapIndexed { index, mode ->
            NikonLadderMode(
                index = index,
                title = mode.label,
                detail = mode.detail,
                options = mode.request.options,
                base = mode.markedValues.singleOrNull().orEmpty(),
                current = mode.request.currentValue,
                disabled = mode.disabled,
            )
        },
        typed = facts.typed ?: NikonControlSetting.entries.firstOrNull { it.control == first?.control },
    )
}

internal fun videoLadderPresentation(picker: MonitorPickerPresentation): LadderSheetPresentation<NikonLadderControl> =
    nikonCapturePopup(picker).presentation

/** The control a circuit write drives, so it travels on the tab's own activation request. */
private fun circuitControls(key: NikonLadderControl): Set<CameraControl> = when (key) {
    NikonLadderControl.BaseIso -> setOf(CameraControl.BASE_ISO)
    NikonLadderControl.AutoIso -> setOf(CameraControl.ISO_AUTO)
    NikonLadderControl.StillAutoIso -> setOf(CameraControl.STILL_ISO_AUTO)
    NikonLadderControl.ShutterMode -> setOf(CameraControl.SHUTTER_MODE)
    NikonLadderControl.Tint -> setOf(CameraControl.WHITE_BALANCE_TINT)
    is NikonLadderControl.Value -> emptySet()
}

/**
 * The request and camera label a ladder write travels on: a value write uses its own tab's
 * request (tabs can share a control, as the three DRIVE tabs do), a circuit write the matching
 * activation request, spelled the way that request offers it ("On" is the body's "ON").
 */
internal fun requestForLadderWrite(
    picker: MonitorPickerPresentation,
    write: LadderWrite<NikonLadderControl>,
): Pair<CommandControlRequest, String>? {
    val key = write.key
    if (key is NikonLadderControl.Value) {
        return picker.modes.getOrNull(key.index)?.request?.let { it to write.value }
    }
    val controls = circuitControls(key)
    val request = picker.modes.flatMap { listOfNotNull(it.activateRequest, it.request) }
        .firstOrNull { it.control in controls } ?: return null
    return request to (request.options.firstOrNull { it.equals(write.value, ignoreCase = true) } ?: write.value)
}

/**
 * A recording-format picker's choices for the shared format picker; null for every other picker.
 * The body's reported formats group each token; a token it does not describe stays unclassified.
 */
internal fun ladderFormats(
    picker: MonitorPickerPresentation,
    recordingFormats: List<NikonRecordingFormatPresentation> = emptyList(),
): List<CaptureFormatChoice<String>>? =
    if (picker.kind == MonitorPickerKind.RESOLUTION) {
        picker.modes.firstOrNull()?.request?.options?.map { token ->
            nikonFormatChoice(recordingFormats.firstOrNull { it.token == token }
                ?: NikonRecordingFormatPresentation(token, null, null, null))
        }
    } else {
        null
    }

/** One Nikon recording format as the shared format picker's area / size / rate choice. */
internal fun nikonFormatChoice(format: NikonRecordingFormatPresentation): CaptureFormatChoice<String> {
    val token = format.token
    return CaptureFormatChoice(value = token, title = token,
        imageArea = format.imageArea?.let { CaptureFormatGroup(it, it) },
        resolution = format.resolution?.let { CaptureFormatGroup(it, it) },
        frameRate = format.frameRate?.let { CaptureFormatGroup(it, it) })
}
