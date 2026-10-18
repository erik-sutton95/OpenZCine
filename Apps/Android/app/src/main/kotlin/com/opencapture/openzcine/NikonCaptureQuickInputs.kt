package com.opencapture.openzcine

import com.opencapture.monitorui.MonitorQuickControl
import com.opencapture.opencine.appkit.MonitorOperatorCaptureInputs
import com.opencapture.opencine.appkit.MonitorOperatorLiveReadout
import com.opencapture.opencine.appkit.MonitorOperatorNativeCaptureQuick
import com.opencapture.opencine.cameracontrols.MonitorOperatorLiveIdentity
import com.opencapture.opencine.nikon.CameraControl
import com.opencapture.opencine.nikon.CameraPropertySnapshot
import com.opencapture.opencine.nikon.CameraShutterMode
import java.util.concurrent.atomic.AtomicReference

/** Captured native write and the property circuits that gave its options meaning. */
internal data class NikonCaptureQuickIdentity(
    val source: MonitorOperatorLiveIdentity,
    val context: NikonCaptureQuickContext,
    val request: CommandControlRequest,
    val marked: Set<String>,
    val domain: List<String>,
)

internal data class NikonCaptureQuickContext(
    val selector: String?,
    val codec: String?,
    val tone: String?,
    val format: String?,
    val shutterMode: CameraShutterMode?,
    val shutterLocked: Boolean?,
    val baseIso: String?,
    val isoAuto: Boolean?,
    val exposureMode: String?,
    val recording: Boolean?,
)

/** The transport queue reads this immutable receipt without accessing Compose state. */
internal class NikonCaptureQuickOwner {
    private val current = AtomicReference<Map<String, NikonCaptureQuickIdentity>>(emptyMap())

    fun publish(values: Map<String, NikonCaptureQuickIdentity>) { current.set(values) }
    fun retire() { current.set(emptyMap()) }
    fun matches(key: String, captured: NikonCaptureQuickIdentity): Boolean = current.get()[key] == captured

    /** A native session may publish its own optimistic selection before its final admission check. */
    fun admits(key: String, captured: NikonCaptureQuickIdentity, target: String): Boolean {
        val latest = current.get()[key] ?: return false
        if (target !in captured.request.options) return false
        return latest == captured || latest == captured.copy(request = captured.request.copy(currentValue = target))
    }
}

/** Recheck native readback at the transport queue boundary, including before recomposition. */
internal fun NikonCaptureQuickIdentity.admitsReported(
    properties: CameraPropertySnapshot, recording: Boolean?, target: String,
): Boolean {
    val control = request.control
    if (properties.captureSelector != context.selector || properties.controlCapabilities.options(control) != domain) return false
    if (captureQuickContext(properties, control, recording) != context) return false
    return request.currentValue in request.options && target in request.options &&
        (confirmsQuickSelection(properties, control, request.currentValue) || confirmsQuickSelection(properties, control, target))
}

/** Same shared strip, drawer and recognizer as the other apps; this adapter supplies only facts. */
internal fun <S> nikonCaptureInputs(
    readouts: List<MonitorOperatorLiveReadout<String, S>>,
    headerReadouts: List<MonitorOperatorLiveReadout<String, S>>,
    panel: com.opencapture.opencine.appkit.MonitorOperatorCameraPanel<String>?,
    pickers: Map<MonitorPickerKind, MonitorPickerPresentation>,
    properties: CameraPropertySnapshot,
    source: MonitorOperatorLiveIdentity,
    recording: Boolean?,
    commandsEnabled: Boolean,
    owner: NikonCaptureQuickOwner,
    columns: Int?,
    open: (String) -> Unit,
    dismiss: () -> Unit,
    commit: (String, NikonCaptureQuickIdentity, String) -> Unit,
): Pair<MonitorOperatorCaptureInputs<String, S, NikonCaptureQuickIdentity>, Map<String, NikonCaptureQuickIdentity>> {
    val native = if (!commandsEnabled) emptyMap() else (readouts + headerReadouts).mapNotNull { readout ->
        if (readout.field != null || !readout.quickEnabled) return@mapNotNull null
        val kind = MonitorPickerKind.entries.firstOrNull { it.name == readout.id } ?: return@mapNotNull null
        val picker = pickers[kind] ?: return@mapNotNull null
        nativeCaptureQuick(picker, properties, source, recording)?.let { readout.id to it }
    }.toMap()
    val inputs = MonitorOperatorCaptureInputs(readouts, panel,
        fields = headerReadouts.mapNotNull { value -> value.field?.let { value.id to it } }.toMap(),
        columns = columns, open = open, dismiss = dismiss,
        isTop = { key -> headerReadouts.any { it.id == key } },
        nativeQuick = { key -> native[key]?.let { captured -> MonitorOperatorNativeCaptureQuick(captured,
            MonitorQuickControl(captured.request.options, captured.request.currentValue, captured.marked, identity = captured)) } },
        nativeCurrent = owner::matches,
        nativeCommit = { key, captured, target ->
            if (owner.matches(key, captured) && target in captured.request.options) commit(key, captured, target)
        },
        commitAdmission = { commandsEnabled && panel == null }, retireNative = owner::retire)
    return inputs to native
}

private fun nativeCaptureQuick(picker: MonitorPickerPresentation, properties: CameraPropertySnapshot,
    source: MonitorOperatorLiveIdentity, recording: Boolean?): NikonCaptureQuickIdentity? {
    if (properties.captureSelector !in setOf("video", "photo")) return null
    if (picker.interactionLocked || picker.drumInteractionLocked) return null
    val mode = if (picker.kind == MonitorPickerKind.SIZE) {
        picker.modes.firstOrNull { it.request.control == CameraControl.STILL_IMAGE_SIZE }
    } else picker.modes.getOrNull(picker.initialModeIndex)
    if (mode == null || mode.disabled || mode.drumLocked) return null
    val control = mode.request.control
    if (control in setOf(CameraControl.RESOLUTION_FRAMERATE, CameraControl.CODEC) && recording != false) return null
    // The full sheets retain their inspection fallbacks; a gesture only uses the current
    // Swift-authorized property domain, never a fabricated ladder or another tab's activation.
    val options = properties.controlCapabilities.options(control).filter { it in mode.request.options }.distinct()
    if (options.isEmpty()) return null
    val selection = options.filter { confirmsQuickSelection(properties, control, it) }.singleOrNull() ?: return null
    val context = captureQuickContext(properties, control, recording)
    return NikonCaptureQuickIdentity(source, context, mode.request.copy(currentValue = selection, options = options),
        mode.markedValues.intersect(options.toSet()), properties.controlCapabilities.options(control))
}

private fun confirmsQuickSelection(properties: CameraPropertySnapshot, control: CameraControl, value: String): Boolean {
    if (control != CameraControl.WHITE_BALANCE) return cameraPropertyConfirmsSelection(properties, control, value)
    val reported = properties.activeWhiteBalanceMode(properties.captureSelector == "photo")
    return if (value.endsWith("K")) reported == "Color temp" && properties.whiteBalanceKelvin?.let { "${it}K" } == value
        else reported == value
}

private fun captureQuickContext(properties: CameraPropertySnapshot,
    control: CameraControl, recording: Boolean?): NikonCaptureQuickContext = NikonCaptureQuickContext(
        selector = properties.captureSelector,
        codec = if (control == CameraControl.CODEC) null else properties.codecSelection ?: properties.codec,
        tone = properties.tone,
        format = if (control == CameraControl.RESOLUTION_FRAMERATE) null else properties.resolutionFrameRate,
        shutterMode = properties.shutterMode, shutterLocked = properties.shutterLocked,
        baseIso = properties.baseIso, isoAuto = properties.isoAuto,
        exposureMode = if (control == CameraControl.EXPOSURE_MODE) null else properties.exposureMode,
        recording = recording)
