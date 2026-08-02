package com.opencapture.openzcine.relay

import android.net.nsd.NsdManager
import com.opencapture.openzcine.core.CameraFocusPoint
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
) {
    private val mutableUi = MutableStateFlow(RelayBroadcastUiState())
    val ui: StateFlow<RelayBroadcastUiState> = mutableUi.asStateFlow()

    private var host: MonitorRelayHost? = null
    private var advertiser: RelayAdvertiser? = null
    private var framePump: Job? = null
    private var statePump: Job? = null

    var watcherPasscode: String = ""
        set(value) {
            field = value
            host?.watcherPasscode = value
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
        if (!host.start()) return false
        android.util.Log.i("RelayHost", "listening on ${host.boundPort}")
        this.host = host
        val advertiser = RelayAdvertiser(nsdManager)
        advertiser.register(deviceName, host.boundPort, servedCameraHost)
        this.advertiser = advertiser
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
                            sound = null,
                            codec = MonitorRelayWire.FrameCodec.JPEG,
                            isKeyframe = true,
                        ),
                        frame.jpegData,
                    )
                }
            }
        statePump =
            scope.launch {
                session.recordingState.collect { publishState() }
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
        host.broadcastState(
            MonitorRelayWire.State(
                recordState =
                    if (recording) {
                        MonitorRelayWire.State.RECORD_STATE_RECORDING
                    } else {
                        MonitorRelayWire.State.RECORD_STATE_STANDBY
                    },
                resolutionFrameRate = "",
                codec = "",
                media = "",
                liveFPS = latestFPS?.let { String.format(java.util.Locale.US, "%.1f", it) } ?: "",
                cameraBatteryPercent = 0,
                cameraName = cameraName ?: identityName ?: "",
                lens = "",
                temperature = "",
                values = emptyList(),
                mediaStatus = null,
                isRecording = recording,
                allowsControlRequests = allowsControlRequests,
            )
        )
    }

    /** Runs a watcher's command on this device's own session — same entry points as local UI. */
    private fun execute(command: MonitorRelayWire.Command) {
        val session = session ?: return
        scope.launch {
            when (command) {
                is MonitorRelayWire.Command.ToggleRecording ->
                    runCatching {
                        session.setRecording(
                            session.recordingState.value != CameraRecordingState.RECORDING
                        )
                    }
                is MonitorRelayWire.Command.FocusPoint ->
                    runCatching {
                        session.changeAfArea(
                            CameraFocusPoint(command.cameraX, command.cameraY)
                        )
                    }
                is MonitorRelayWire.Command.PickerValue ->
                    // Typed picker writes need the descriptor-checked seam; accepted on the
                    // wire (iOS sends them) and deliberately not guessed into a write here.
                    Unit
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
        val stopping = host
        host = null
        scope.launch { stopping?.stop(notifyingViewers = notifyReason) }
        session = null
        frames = null
        mutableUi.value = RelayBroadcastUiState()
    }
}
