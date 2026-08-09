package com.opencapture.openzcine.relay

import android.net.nsd.NsdManager
import kotlinx.coroutines.flow.map
import kotlinx.coroutines.flow.merge
import com.opencapture.openzcine.UNAVAILABLE_MONITOR_VALUE
import com.opencapture.openzcine.monitorMediaStatus
import com.opencapture.openzcine.monitorResolutionLabel
import com.opencapture.openzcine.monitorStorageLabel
import com.opencapture.openzcine.monitorValueOrNull
import com.opencapture.openzcine.validBatteryPercent
import com.opencapture.openzcine.core.CameraFocusPoint
import com.opencapture.openzcine.core.CameraTemperatureStatus
import com.opencapture.openzcine.core.RelayEncoderProfile
import com.opencapture.openzcine.core.CameraRecordingState
import com.opencapture.openzcine.core.CameraSession
import com.opencapture.openzcine.core.CameraSessionState
import com.opencapture.openzcine.core.LiveFrameSource
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch

/** What the Sharing rows and the grant banner render. */
data class RelayBroadcastUiState(
    val isBroadcasting: Boolean = false,
    val watcherCount: Int = 0,
    val pendingControlRequestName: String? = null,
    val controlHolderName: String? = null,
    /**
     * Why the last start attempt failed (iOS "Couldn't start sharing: …"). A listener that
     * cannot bind is silent otherwise: the toggle just springs back with no explanation.
     */
    val failureReason: String? = null,
)

/**
 * Owns this device's broadcast — the Android twin of the iOS host-side model glue: taps the
 * session's live frames (JPEG passthrough, byte-for-byte — re-encoding a live-view JPEG costs a
 * generation of quality for nothing), publishes the slow-moving readouts, advertises over NSD
 * with the served-camera TXT record, and executes the control-holder's commands on the local
 * session through the same entry points the local UI uses.
 */
class RelayBroadcastController(
    private val scope: CoroutineScope,
    private val nsdManager: NsdManager,
    private val deviceName: String,
    /** Persisted preferred listener port — stale NSD records keep dialing a live listener. */
    private val loadPreferredPort: () -> Int = { 0 },
    private val savePreferredPort: (Int) -> Unit = {},
) {
    private val mutableUi = MutableStateFlow(RelayBroadcastUiState())
    val ui: StateFlow<RelayBroadcastUiState> = mutableUi.asStateFlow()

    private var host: MonitorRelayHost? = null
    private var advertiser: RelayAdvertiser? = null
    private val presence = RelayPresenceResponder()
    private var framePump: Job? = null
    private var statePump: Job? = null

    var watcherPasscode: String = ""
        set(value) {
            field = value
            host?.watcherPasscode = value
        }

    /**
     * Broadcast priority (iOS `relayEncoderProfile`). Reaches watchers as they join — see
     * [MonitorRelayHost.encoderProfile] for why a live broadcast keeps its existing lanes.
     */
    var encoderProfile: RelayEncoderProfile = RelayEncoderProfile.LOW_LATENCY
        set(value) {
            field = value
            host?.encoderProfile = value
        }

    var allowsControlRequests: Boolean = true
        set(value) {
            field = value
            host?.allowsControlRequests = value
            if (!value) scope.launch { host?.declinePendingControl() }
            scope.launch { publishState() }
        }

    private var session: CameraSession? = null
    private var frames: LiveFrameSource? = null
    private var cameraName: String? = null
    private var servedCameraHost: String? = null
    private var latestFPS: Double? = null

    fun start(
        session: CameraSession,
        frames: LiveFrameSource,
        cameraName: String?,
        servedCameraHost: String?,
    ): Boolean {
        stop(notifyReason = "The broadcast ended.")
        this.session = session
        this.frames = frames
        this.cameraName = cameraName
        this.servedCameraHost = servedCameraHost
        val host = MonitorRelayHost(scope, deviceName, cameraName)
        host.watcherPasscode = watcherPasscode
        host.allowsControlRequests = allowsControlRequests
        host.encoderProfile = encoderProfile
        host.onPeerCountChanged = { count ->
            mutableUi.value = mutableUi.value.copy(watcherCount = count)
        }
        host.onControlChanged = { pending, holder ->
            mutableUi.value =
                mutableUi.value.copy(
                    pendingControlRequestName = pending,
                    controlHolderName = holder,
                )
        }
        host.onCommand = ::execute
        // Assigned BEFORE start(), which reports a bind failure synchronously from inside it.
        host.onFailure = { reason ->
            mutableUi.value = mutableUi.value.copy(failureReason = reason)
        }
        if (!host.start(preferredPort = loadPreferredPort())) return false
        savePreferredPort(host.boundPort)
        android.util.Log.i("RelayHost", "listening on ${host.boundPort}")
        this.host = host
        val advertiser = RelayAdvertiser(nsdManager)
        advertiser.register(deviceName, host.boundPort, servedCameraHost)
        this.advertiser = advertiser
        // The unicast presence twin: on multicast-filtered networks this line is the only way
        // watchers can list this broadcast (iOS `updateRelayPresence`).
        presence.update(
            deviceName,
            watchable = true,
            servedCameraHost = servedCameraHost,
            relayPort = host.boundPort,
        )
        framePump =
            scope.launch(Dispatchers.IO) {
                frames.frames.collect { frame ->
                    latestFPS = frame.measuredFramesPerSecond
                    // The camera's own JPEG passes through untouched; its header metadata rides
                    // beside it so a watcher's AF box stays locked to the frame it measured.
                    host.broadcastFrame(
                        MonitorRelayWire.FrameMetadata(
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
                                                com.opencapture.openzcine.core.LiveFocusResult
                                                    .NOT_FOCUSED -> 1
                                                com.opencapture.openzcine.core.LiveFocusResult
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
                        ),
                        frame.jpegData,
                    )
                }
            }
        statePump =
            scope.launch {
                // Readings change far more often than the record state; collecting only the
                // latter left a watcher on whatever values happened to be current at connect.
                merge(
                    session.recordingState.map { },
                    session.cameraProperties.map { },
                ).collect { publishState() }
            }
        mutableUi.value = mutableUi.value.copy(isBroadcasting = true)
        scope.launch { publishState() }
        return true
    }

    private suspend fun publishState() {
        val host = host ?: return
        val session = session ?: return
        val identityName =
            (session.state.value as? CameraSessionState.Connected)?.identity?.name
        val recording = session.recordingState.value == CameraRecordingState.RECORDING
        // The camera's own readings, mapped through the SAME helpers the local readouts use, so a
        // watcher of an Android broadcast reads identically to one watching iOS. These were all
        // hardcoded empty, which is why an Android broadcast arrived with blank codec/media/
        // resolution pills and no camera battery.
        val snapshot = session.cameraProperties.value
        host.broadcastState(
            MonitorRelayWire.State(
                recordState =
                    if (recording) {
                        MonitorRelayWire.State.RECORD_STATE_RECORDING
                    } else {
                        MonitorRelayWire.State.RECORD_STATE_STANDBY
                    },
                resolutionFrameRate =
                    monitorResolutionLabel(
                        resolution = snapshot.resolution,
                        frameRate = snapshot.frameRate,
                        fallback = ""
                    ),
                codec = snapshot.codec.monitorValueOrNull() ?: "",
                media = monitorStorageLabel(snapshot.storage).takeIf { it != "—" } ?: "",
                liveFPS = latestFPS?.let { String.format(java.util.Locale.US, "%.1f", it) } ?: "",
                // The gauge's raw value, not a bar count — the watcher's own gauge maps it, the
                // same way this device's does. Zero reads as "no camera" on the far side.
                cameraBatteryPercent = validBatteryPercent(snapshot.batteryPercent) ?: 0,
                cameraName = cameraName ?: identityName ?: "",
                lens = snapshot.lens.monitorValueOrNull() ?: "",
                // The body's real warning state, in the same three words the core stamps
                // (`CameraWarningStatus.tileLabel`) — never a fabricated temperature number.
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
                // Every cell is always sent — a missing one reads as "this camera has no iris",
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
                            // Angle when the body is in that mode, seconds otherwise — the same
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
                // local top bar uses — null left a watcher's cell stuck on its preview value.
                mediaStatus =
                    monitorMediaStatus(
                            storage = snapshot.storage,
                            codec = snapshot.codec,
                            resolution = snapshot.resolution,
                            frameRate = snapshot.frameRate,
                        )
                        ?.let {
                            MonitorRelayWire.MediaStatus(
                                gigabytesFree = it.gigabytesFree.toInt(),
                                percentFree = it.percentFree.toInt(),
                                minutesRemaining = it.minutesRemaining,
                            )
                        },
                isRecording = recording,
                allowsControlRequests = allowsControlRequests,
            )
        )
    }

    /**
     * Runs a watcher's command on this device's own session — same entry points as local UI.
     *
     * Deliberately NOT the monitor's record control: the Record Confirmation preference belongs to
     * whoever pressed the button, and the holder already answered it on their own screen. A prompt
     * raised here would wait on an operator who is holding the other device, and the take would
     * never start (iOS shipped exactly that).
     */
    private fun execute(command: MonitorRelayWire.Command) {
        val session = session ?: return
        scope.launch {
            runCatching {
                    when (command) {
                        is MonitorRelayWire.Command.ToggleRecording ->
                            session.setRecording(
                                session.recordingState.value != CameraRecordingState.RECORDING
                            )
                        is MonitorRelayWire.Command.FocusPoint ->
                            session.changeAfArea(
                                CameraFocusPoint(command.cameraX, command.cameraY)
                            )
                        is MonitorRelayWire.Command.PickerValue -> {
                            // The holder's picker write, run on this device's own session through
                            // the same typed entry point the local drums use — so it is subject to
                            // every guard and queue a local write is. A word this side has no
                            // control for is dropped rather than guessed at
                            // (see [RelayPickerVocabulary]).
                            val write =
                                RelayPickerVocabulary.write(command.picker, command.value)
                            if (write != null) {
                                session.applyControl(write.control, write.label)
                            }
                        }
                    }
                }
                // A refusal here is invisible on BOTH devices otherwise — the holder sees its
                // control do nothing and this screen says nothing at all. Closed command
                // vocabulary only; the exception stays in local logcat, never in a report.
                .onFailure {
                    android.util.Log.w(
                        "RelayHost",
                        "watcher command refused: ${command.javaClass.simpleName}",
                    )
                }
        }
    }

    fun grantPendingControl() {
        scope.launch { host?.grantPendingControl() }
    }

    fun declinePendingControl() {
        scope.launch { host?.declinePendingControl() }
    }

    fun reclaimControl() {
        scope.launch { host?.reclaimControl() }
    }

    fun stop(notifyReason: String? = null) {
        framePump?.cancel()
        statePump?.cancel()
        advertiser?.unregister()
        advertiser = null
        presence.update(null)
        val stopping = host
        host = null
        scope.launch { stopping?.stop(notifyingViewers = notifyReason) }
        session = null
        frames = null
        mutableUi.value = RelayBroadcastUiState()
    }
}
