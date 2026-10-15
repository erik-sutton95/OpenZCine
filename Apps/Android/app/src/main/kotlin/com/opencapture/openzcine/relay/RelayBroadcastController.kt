package com.opencapture.openzcine.relay

import android.net.nsd.NsdManager
import com.opencapture.opencine.nikon.CameraCommandAdmission
import com.opencapture.opencine.nikon.CameraFocusPoint
import com.opencapture.opencine.nikon.CameraRecordingState
import com.opencapture.opencine.nikon.CameraSession
import com.opencapture.opencine.nikon.CameraSessionState
import com.opencapture.opencine.nikon.CameraTemperatureStatus
import com.opencapture.opencine.nikon.LiveFocusResult
import com.opencapture.opencine.nikon.LiveFrame
import com.opencapture.opencine.nikon.LiveFrameSource
import com.opencapture.opencine.nikon.MediaStatus
import com.opencapture.opencine.nikon.MonitorTextFormat
import com.opencapture.opencine.nikonwire.MonitorRelayWire
import com.opencapture.opencine.relay.RelayHostControl
import com.opencapture.opencine.relayruntime.RelayBroadcastAnnouncer
import com.opencapture.opencine.relayruntime.RelayBroadcastDispatch
import com.opencapture.opencine.relayruntime.RelayBroadcastFrame
import com.opencapture.opencine.relayruntime.RelayBroadcastOwner
import com.opencapture.openzcine.UNAVAILABLE_MONITOR_VALUE
import com.opencapture.openzcine.core.RelayEncoderProfile
import com.opencapture.openzcine.monitorStorageLabel
import com.opencapture.openzcine.monitorValueOrNull
import com.opencapture.openzcine.validBatteryPercent
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.flow.map
import kotlinx.coroutines.flow.merge

typealias RelayBroadcastUiState = com.opencapture.opencine.relayruntime.RelayBroadcastStatus

/** Only camera facts, deployed wire conversion and host stores compose the shared owner. */
class RelayBroadcastController(
    scope: CoroutineScope,
    nsdManager: NsdManager,
    deviceName: String,
    loadPreferredPort: () -> Int = { 0 },
    savePreferredPort: (Int) -> Unit = {},
) {
    private class Source(val session: CameraSession, val frames: LiveFrameSource, val cameraName: String?)
    private val owner = RelayBroadcastOwner<Source, LiveFrame, MonitorRelayWire.State,
        MonitorRelayWire.FrameMetadata, MonitorRelayWire.Command, MonitorRelayWire.ControlToken,
        MonitorRelayWire.JoinDenied>(
        scope = scope, codec = DeployedMonitorRelayCodec(), hostName = deviceName,
        frames = { it.frames.frames },
        stateChanges = { merge(it.session.recordingState.map { }, it.session.cameraProperties.map { }) },
        frame = ::encodedFrame, readState = ::readState, dispatch = ::execute,
        makeAnnouncement = {
            RelayBroadcastAnnouncer(nsdManager, DeployedMonitorRelayCodec().profile, deviceName,
                presenceLine = { host, port ->
                    MonitorRelayWire.relayPresenceLine(deviceName, true, host, port).toByteArray(Charsets.UTF_8)
                },
                onPresenceBindFailure = { android.util.Log.w("RelayHost", "presence responder bind failed") })
        },
        loadPreferredPort = loadPreferredPort, savePreferredPort = savePreferredPort,
        onListening = { android.util.Log.i("RelayHost", "listening on $it") },
        onCommandRefused = {
            android.util.Log.w("RelayHost", "watcher command refused: ${it.javaClass.simpleName}")
        },
    )
    val ui get() = owner.status
    var watcherPasscode: String
        get() = owner.watcherPasscode
        set(value) { owner.watcherPasscode = value }
    var encoderProfile: RelayEncoderProfile
        get() = owner.encoderProfile
        set(value) { owner.encoderProfile = value }
    var allowsControlRequests: Boolean
        get() = owner.allowsControlRequests
        set(value) { owner.allowsControlRequests = value }
    fun start(session: CameraSession, frames: LiveFrameSource, cameraName: String?, servedCameraHost: String?) =
        owner.start(Source(session, frames, cameraName), cameraName, servedCameraHost)
    fun grantPendingControl() = owner.grantPendingControl()
    fun declinePendingControl() = owner.declinePendingControl()
    val pendingRequest: RelayHostControl.PendingRequest? get() = owner.pendingRequest
    fun grantPendingControl(request: RelayHostControl.PendingRequest) = owner.grantPendingControl(request)
    fun declinePendingControl(request: RelayHostControl.PendingRequest) = owner.declinePendingControl(request)
    fun reclaimControl() = owner.reclaimControl()
    fun stop(notifyReason: String? = null) = owner.stop(notifyReason)

    private suspend fun execute(source: Source, command: MonitorRelayWire.Command, dispatch: RelayBroadcastDispatch) {
        val session = source.session
        val admission = CameraCommandAdmission(session, dispatch::isCurrent)
        when (command) {
            is MonitorRelayWire.Command.ToggleRecording ->
                session.setRecording(session.recordingState.value != CameraRecordingState.RECORDING, admission)
            is MonitorRelayWire.Command.FocusPoint ->
                session.changeAfArea(CameraFocusPoint(command.cameraX, command.cameraY), admission)
            is MonitorRelayWire.Command.PickerValue -> {
                val write = RelayPickerVocabulary.write(command.picker, command.value)
                if (write != null) session.applyControl(write.control, write.label, admission)
            }
        }
    }

    private fun encodedFrame(frame: LiveFrame): RelayBroadcastFrame<MonitorRelayWire.FrameMetadata> =
        RelayBroadcastFrame(metadata = MonitorRelayWire.FrameMetadata(
            timecode =
                frame.timecode?.let {
                    MonitorRelayWire.Timecode(
                        it.on, it.hour, it.minute, it.second, it.frame
                    )
                },
            isRecording = frame.isRecording,
            focus =
                frame.focus?.let { focus ->
                    MonitorRelayWire.Focus(
                        coordinateWidth = focus.coordinateWidth,
                        coordinateHeight = focus.coordinateHeight,
                        focusResult =
                            when (focus.result) {
                                LiveFocusResult
                                    .NOT_FOCUSED -> 1
                                LiveFocusResult
                                    .FOCUSED -> 2
                                else -> 0
                            },
                        subjectDetectionActive = focus.subjectDetectionActive,
                        trackingAFActive = focus.trackingAFActive,
                        selectedBoxIndex = focus.selectedBoxIndex,
                        boxes =
                            focus.boxes.map {
                                MonitorRelayWire.FocusBox(
                                    it.centerX, it.centerY, it.width, it.height
                                )
                            },
                    )
                },
            levelRoll = frame.level?.rollDegrees,
            levelPitch = frame.level?.pitchDegrees,
            // Back to the body's own meter segments, which is what the wire
            // carries and what a watcher's meters are mapped from; sending null
            // mounted the meter and never moved it.
            sound = frame.audioLevels?.let(RelayAudioMeter::sound),
            codec = MonitorRelayWire.FrameCodec.JPEG,
            isKeyframe = true,
            // Vertical mode travels: a watcher rotates the picture upright the
            // same way this device does, instead of rendering it sideways.
            rotation = relayRotationWireValue(frame.rotation),
        ), image = frame.jpegData, measuredFramesPerSecond = frame.measuredFramesPerSecond)

    private fun readState(source: Source, latestFPS: Double?, allowsControlRequests: Boolean): MonitorRelayWire.State {
        val session = source.session
        val cameraName = source.cameraName
        val identityName =
            (session.state.value as? CameraSessionState.Connected)?.identity?.name
        val recording = session.recordingState.value == CameraRecordingState.RECORDING
        // The camera's own readings, mapped through the SAME helpers the local readouts use, so a
        // watcher of an Android broadcast reads identically to one watching iOS. These were all
        // hardcoded empty, which is why an Android broadcast arrived with blank codec/media/
        // resolution pills and no camera battery.
        val snapshot = session.cameraProperties.value
        return MonitorRelayWire.State(
            recordState =
                if (recording) {
                    MonitorRelayWire.State.RECORD_STATE_RECORDING
                } else {
                    MonitorRelayWire.State.RECORD_STATE_STANDBY
                },
            resolutionFrameRate =
                MonitorTextFormat.resolutionLabel(snapshot.resolution.monitorValueOrNull(), snapshot.frameRate ?: 0, ""),
            codec = snapshot.codec.monitorValueOrNull() ?: "",
            media = monitorStorageLabel(snapshot.storage).takeIf { it != "\u2014" } ?: "",
            liveFPS = latestFPS?.let { String.format(java.util.Locale.US, "%.1f", it) } ?: "",
            // The gauge's raw value, not a bar count, the watcher's own gauge maps it, the
            // same way this device's does. Zero reads as "no camera" on the far side.
            cameraBatteryPercent = validBatteryPercent(snapshot.batteryPercent) ?: 0,
            cameraName = cameraName ?: identityName ?: "",
            lens = snapshot.lens.monitorValueOrNull() ?: "",
            // The body's real warning state, in the same three words the core stamps
            // (`CameraWarningStatus.tileLabel`), never a fabricated temperature number.
            // Empty until the body has been polled, which reads as "not known yet".
            temperature =
                when (snapshot.temperatureStatus) {
                    CameraTemperatureStatus.HOT -> "HOT"
                    CameraTemperatureStatus.WARNING -> "CHECK"
                    CameraTemperatureStatus.NORMAL -> "OK"
                    null -> ""
                },
            // The capture bar's five cells. Labels are a wire contract, not copy: the
            // watcher's strip is built against exactly ISO / SHUTTER / IRIS / WB / FOCUS
            // (core `CameraDisplayState`), so a different word here renders an empty cell.
            // Every cell is always sent, a missing one reads as "this camera has no iris",
            // where a dash reads as "not known yet", which is the truth while properties
            // are still settling.
            values =
                listOf(
                    MonitorRelayWire.StateValue(
                        "ISO",
                        snapshot.iso?.toString() ?: UNAVAILABLE_MONITOR_VALUE
                    ),
                    MonitorRelayWire.StateValue(
                        "SHUTTER",
                        // Angle when the body is in that mode, seconds otherwise , the same
                        // preference the local capture bar shows.
                        snapshot.shutterAngle.monitorValueOrNull()
                            ?: snapshot.shutterSpeed.monitorValueOrNull()
                            ?: UNAVAILABLE_MONITOR_VALUE
                    ),
                    MonitorRelayWire.StateValue(
                        "IRIS",
                        snapshot.iris.monitorValueOrNull() ?: UNAVAILABLE_MONITOR_VALUE
                    ),
                    MonitorRelayWire.StateValue(
                        "WB",
                        snapshot.whiteBalanceKelvin?.let { "${it}K" }
                            ?: snapshot.whiteBalanceMode.monitorValueOrNull()
                            ?: UNAVAILABLE_MONITOR_VALUE
                    ),
                    MonitorRelayWire.StateValue(
                        "FOCUS",
                        snapshot.focusMode.monitorValueOrNull() ?: UNAVAILABLE_MONITOR_VALUE
                    ),
                ),
            // The MEDIA cell's capacity/duration flip-side, through the SAME estimator the
            // local top bar uses , null left a watcher's cell stuck on its preview value.
            mediaStatus =
                MediaStatus.from(snapshot.storage, snapshot.codec, snapshot.resolution, snapshot.frameRate)
                    ?.let { MonitorRelayWire.MediaStatus(it.gigabytesFree, it.percentFree, it.minutesRemaining, it.estimatedMinutesRemaining, it.freeBytes) },
            isRecording = recording,
            allowsControlRequests = allowsControlRequests,
        )
    }
}
