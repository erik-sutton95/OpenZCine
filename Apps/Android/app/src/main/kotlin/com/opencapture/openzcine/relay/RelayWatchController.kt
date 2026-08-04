package com.opencapture.openzcine.relay

import com.opencapture.openzcine.core.CameraFocusPoint
import com.opencapture.openzcine.core.CameraIdentity
import com.opencapture.openzcine.core.CameraRecordingState
import com.opencapture.openzcine.core.CameraSession
import com.opencapture.openzcine.core.CameraSessionState
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch

/** Everything the watch surface renders, in one observable bundle. */
data class RelayWatchUiState(
    val phase: Phase = Phase.CONNECTING,
    val hostName: String = "",
    val cameraName: String? = null,
    val holdsControl: Boolean = false,
    val controlHolderName: String? = null,
    val allowsControlRequests: Boolean = true,
    val needsPasscode: Boolean = false,
    val passcodeWasWrong: Boolean = false,
    val failureReason: String? = null,
    val state: MonitorRelayWire.State? = null,
    /**
     * The broadcaster ended the session deliberately (a denial while watching, no passcode
     * asked) — the shell leaves to the camera list instead of arming the rejoin watchdog.
     */
    val endedByBroadcaster: Boolean = false,
) {
    enum class Phase {
        CONNECTING,
        WATCHING,
        DENIED,
        FAILED,
    }
}

/**
 * Owns one watch session — the Android twin of the iOS viewer model: joins, feeds the shared
 * monitor pipeline via [frameSource], carries the ask/give-back control token, asks for a
 * passcode when refused, and rejoins through drops while the broadcast is still advertised.
 */
class RelayWatchController(
    private val scope: CoroutineScope,
    private val deviceName: String,
    val broadcast: RelayBroadcast,
) {
    private val mutableUi = MutableStateFlow(RelayWatchUiState())
    val ui: StateFlow<RelayWatchUiState> = mutableUi.asStateFlow()

    val frameSource = RelayLiveFrameSource()

    /**
     * Latched once this device's HEVC decoders have exhausted their attempts on the stream:
     * every later join declares `codecs=["jpeg"]` and the host serves JPEG instead — codec
     * negotiation for hardware the stream defeats (no Main10 decode on low-end chipsets).
     */
    private var jpegOnly = false
    val session: RelayCameraSession = RelayCameraSession(this)

    private var client: MonitorRelayClient? = null
    private var eventsJob: Job? = null
    private var rejoinJob: Job? = null
    private var passcode: String? = null
    /** Latest frame's camera coordinate space, for focus commands. */
    internal var focusCoordinateSpace: Pair<Int, Int>? = null

    fun start(passcode: String? = null) {
        this.passcode = passcode
        join()
    }

    private fun join() {
        eventsJob?.cancel()
        val client = MonitorRelayClient(scope)
        this.client = client
        mutableUi.value =
            mutableUi.value.copy(
                phase = RelayWatchUiState.Phase.CONNECTING,
                needsPasscode = false,
                failureReason = null,
            )
        eventsJob =
            scope.launch(Dispatchers.IO) {
                client.events.collect { event ->
                    when (event) {
                        is MonitorRelayClient.Event.Connected -> {
                            mutableUi.value =
                                mutableUi.value.copy(
                                    phase = RelayWatchUiState.Phase.WATCHING,
                                    hostName = event.hostName,
                                    cameraName = event.cameraName,
                                )
                            session.adopt(event.cameraName ?: event.hostName)
                        }
                        is MonitorRelayClient.Event.StateReceived -> {
                            mutableUi.value =
                                mutableUi.value.copy(
                                    state = event.state,
                                    allowsControlRequests =
                                        event.state.allowsControlRequests ?: true,
                                )
                            session.applyState(event.state)
                        }
                        is MonitorRelayClient.Event.FrameReceived -> {
                            event.metadata.focus?.let {
                                focusCoordinateSpace = it.coordinateWidth to it.coordinateHeight
                            }
                            frameSource.submit(event.metadata, event.image)
                        }
                        is MonitorRelayClient.Event.ControlChanged -> {
                            mutableUi.value =
                                mutableUi.value.copy(
                                    holdsControl = event.token.holderIsRecipient,
                                    controlHolderName = event.token.holderName,
                                )
                        }
                        is MonitorRelayClient.Event.JoinDenied -> {
                            val watching =
                                mutableUi.value.phase == RelayWatchUiState.Phase.WATCHING
                            if (watching && !event.denied.passcodeRequired) {
                                // The operator ended the broadcast — not a refused join.
                                rejoinJob?.cancel()
                                mutableUi.value =
                                    mutableUi.value.copy(
                                        endedByBroadcaster = true,
                                        failureReason = event.denied.reason,
                                    )
                            } else {
                                mutableUi.value =
                                    mutableUi.value.copy(
                                        phase = RelayWatchUiState.Phase.DENIED,
                                        needsPasscode = event.denied.passcodeRequired,
                                        passcodeWasWrong = passcode != null,
                                        failureReason = event.denied.reason,
                                    )
                            }
                        }
                        is MonitorRelayClient.Event.Closed -> {
                            val current = mutableUi.value
                            if (current.endedByBroadcaster) return@collect
                            // A refused join already explains itself; a drop mid-watch arms
                            // the rejoin watchdog, which stands down while a passcode entry
                            // is on screen (auto-rejoining would unmount the field).
                            if (current.phase == RelayWatchUiState.Phase.WATCHING) {
                                mutableUi.value =
                                    mutableUi.value.copy(
                                        phase = RelayWatchUiState.Phase.FAILED,
                                        failureReason =
                                            event.reason ?: "The broadcast dropped.",
                                    )
                                armRejoin()
                            } else if (current.phase == RelayWatchUiState.Phase.CONNECTING) {
                                mutableUi.value =
                                    mutableUi.value.copy(
                                        phase = RelayWatchUiState.Phase.FAILED,
                                        failureReason =
                                            event.reason
                                                ?: "Couldn't reach the broadcast.",
                                    )
                                armRejoin()
                            }
                        }
                    }
                }
            }
        frameSource.onHevcExhausted = {
            if (!jpegOnly) {
                jpegOnly = true
                android.util.Log.i(
                    "RelayHEVC", "decoders exhausted; rejoining for JPEG frames")
                retry()
            }
        }
        client.connect(
            broadcast.host,
            broadcast.port,
            deviceName,
            passcode,
            codecs = if (jpegOnly) listOf("jpeg") else null,
        )
    }

    fun submitPasscode(code: String) {
        passcode = code
        retry()
    }

    /** Manual rejoin with the current credentials — the failure surface's Try again. */
    fun retry() {
        scope.launch {
            client?.stop()
            join()
        }
    }

    fun requestControl() = client?.requestControl() ?: Unit

    fun releaseControl() = client?.releaseControl() ?: Unit

    internal fun sendCommand(command: MonitorRelayWire.Command) {
        if (mutableUi.value.holdsControl) client?.sendCommand(command)
    }

    private fun armRejoin() {
        if (rejoinJob?.isActive == true) return
        rejoinJob =
            scope.launch {
                while (true) {
                    delay(REJOIN_INTERVAL_MILLIS)
                    val current = mutableUi.value
                    if (current.phase != RelayWatchUiState.Phase.FAILED) return@launch
                    if (current.needsPasscode) continue
                    client?.stop()
                    join()
                    return@launch
                }
            }
    }

    suspend fun stop() {
        rejoinJob?.cancel()
        eventsJob?.cancel()
        client?.stop()
        frameSource.release()
        session.close()
    }

    private companion object {
        const val REJOIN_INTERVAL_MILLIS = 3_000L
    }
}

/**
 * The [CameraSession] the monitor shell needs, backed by the broadcast instead of a body. State
 * readouts arrive over the relay; the record toggle and AF taps become relay commands honoured
 * only while this watcher holds control — control is proxied, never transferred.
 */
class RelayCameraSession(private val controller: RelayWatchController) : CameraSession {
    private val mutableState =
        MutableStateFlow<CameraSessionState>(CameraSessionState.Connecting)
    override val state: StateFlow<CameraSessionState> = mutableState.asStateFlow()

    private val mutableRecording = MutableStateFlow(CameraRecordingState.STANDBY)
    override val recordingState: StateFlow<CameraRecordingState> = mutableRecording.asStateFlow()

    internal fun adopt(displayName: String) {
        mutableState.value =
            CameraSessionState.Connected(
                CameraIdentity(name = displayName, model = displayName, serialNumber = "")
            )
    }

    internal fun applyState(state: MonitorRelayWire.State) {
        mutableRecording.value =
            if (state.isRecording) CameraRecordingState.RECORDING else CameraRecordingState.STANDBY
    }

    internal fun close() {
        mutableState.value = CameraSessionState.Disconnected
    }

    override suspend fun connect() {
        // The controller owns the socket lifecycle; the monitor never dials a broadcast.
    }

    override suspend fun disconnect() {
        // Leaving the watch surface stops the controller; nothing to do per-session.
    }

    override suspend fun setRecording(recording: Boolean) {
        controller.sendCommand(MonitorRelayWire.Command.ToggleRecording)
    }

    override suspend fun changeAfArea(point: CameraFocusPoint): Boolean {
        val (width, height) = controller.focusCoordinateSpace ?: return false
        controller.sendCommand(
            MonitorRelayWire.Command.FocusPoint(
                cameraX = point.x,
                cameraY = point.y,
                coordinateWidth = width,
                coordinateHeight = height,
            )
        )
        return true
    }
}
