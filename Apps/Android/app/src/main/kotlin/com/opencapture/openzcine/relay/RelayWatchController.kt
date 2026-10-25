package com.opencapture.openzcine.relay

import com.opencapture.opencine.nikonwire.MonitorRelayWire
import com.opencapture.opencine.nikon.CameraControl
import com.opencapture.opencine.nikon.CameraControlException
import com.opencapture.opencine.nikon.CameraFocusPoint
import com.opencapture.opencine.nikon.CameraIdentity
import com.opencapture.opencine.nikon.CameraRecordingException
import com.opencapture.opencine.nikon.CameraRecordingState
import com.opencapture.opencine.nikon.CameraSession
import com.opencapture.opencine.nikon.CameraSessionState
import com.opencapture.opencine.relayruntime.RelayViewerConfiguration
import com.opencapture.opencine.relayruntime.RelayViewerCommandAdmission
import com.opencapture.opencine.relayruntime.RelayViewerCredentials
import com.opencapture.opencine.relayruntime.RelayViewerFacts
import com.opencapture.opencine.relayruntime.RelayViewerFocusCoordinates
import com.opencapture.opencine.relayruntime.RelayViewerOwner
import com.opencapture.opencine.relayruntime.RelayViewerPolicy
import com.opencapture.opencine.relayruntime.RelayViewerRefusal
import com.opencapture.opencine.relayruntime.WatcherRelaySecrets
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.CoroutineStart
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
     * asked): the shell leaves to the camera list instead of arming the rejoin watchdog.
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

/** Store, deployed wire and Nikon session observations over the complete shared viewer owner. */
class RelayWatchController(
    scope: CoroutineScope,
    deviceName: String,
    val broadcast: RelayBroadcast,
    watcherId: String? = null,
    onJpegOnlyLatched: (() -> Unit)? = null,
    /** Where passcodes are remembered per broadcaster; null keeps them for this run only. */
    private val passcodes: RelayPasscodes? = null,
    hevcDecodeDeadlineMillis: Long = 6_000L,
    stallDeadlineMillis: Long = 8_000L,
    log: (String) -> Unit = { android.util.Log.i("RelayHEVC", it) },
) {
    private val mutableUi = MutableStateFlow(RelayWatchUiState())
    val ui: StateFlow<RelayWatchUiState> = mutableUi.asStateFlow()
    val frameSource = RelayLiveFrameSource()
    val session: RelayCameraSession = RelayCameraSession(this)
    internal val focusCoordinateSpace: Pair<Int, Int>? get() = owner.focusCoordinates?.let { it.width to it.height }
    private val owner = RelayViewerOwner(
        scope = scope,
        codec = DeployedMonitorRelayCodec(),
        configuration = RelayViewerConfiguration(broadcast.host, broadcast.port, deviceName,
            credentialKey = broadcast.name, watcherID = watcherId),
        facts = object : RelayViewerFacts<MonitorRelayWire.State, MonitorRelayWire.FrameMetadata, MonitorRelayWire.ControlToken, MonitorRelayWire.JoinDenied> {
            override fun allowsControlRequests(state: MonitorRelayWire.State): Boolean? = state.allowsControlRequests
            override fun holderName(control: MonitorRelayWire.ControlToken): String? = control.holderName
            override fun refusal(denied: MonitorRelayWire.JoinDenied): RelayViewerRefusal =
                RelayViewerRefusal(denied.reason, denied.passcodeRequired)
            override fun focusCoordinates(metadata: MonitorRelayWire.FrameMetadata): RelayViewerFocusCoordinates? =
                metadata.focus?.let { RelayViewerFocusCoordinates(it.coordinateWidth, it.coordinateHeight) }
        },
        picture = frameSource.pictureOwner,
        credentials = object : RelayViewerCredentials {
            // A failed secure migration keeps the old credential usable; new answers that the
            // store could not keep still join in this run, never in a new plaintext entry.
            override fun passcode(key: String): String? = rememberedPasscodes[key]
                ?: (passcodes?.rememberedPasscodeLookup(key) as? WatcherRelaySecrets.Lookup.Stored)?.value
            override fun rememberPasscode(key: String, code: String) {
                if (passcodes?.storeRememberedPasscode(code, key) == true) rememberedPasscodes.remove(key)
                else rememberedPasscodes[key] = code
            }
            override val jpegOnly: Boolean get() = processJpegOnly
            override fun latchJpegOnly() { processJpegOnly = true }
        },
        policy = RelayViewerPolicy(hevcDecodeDeadlineMillis = hevcDecodeDeadlineMillis,
            stallDeadlineMillis = stallDeadlineMillis, stallPollMillis = 3_000L,
            rejoinIntervalMillis = 3_000L, hevcCodec = MonitorRelayWire.FrameCodec.HEVC,
            stalledReason = "The stream stalled. Reconnecting. Make sure OpenZCine is " +
                "open on the broadcasting device."),
        onSourceBegan = { session.beginSource(it) },
        onConnected = { source, hello -> session.adopt(source, hello.cameraName ?: hello.hostName) },
        onState = { source, state -> session.applyState(source, state) },
        onJpegOnlyLatched = { onJpegOnlyLatched?.invoke() },
        log = log,
    )
    init {
        scope.launch(start = CoroutineStart.UNDISPATCHED) {
            owner.status.collect { value ->
                mutableUi.value = RelayWatchUiState(
                    phase = RelayWatchUiState.Phase.valueOf(value.phase.name),
                    hostName = value.hostName ?: "", cameraName = value.cameraName,
                    holdsControl = value.holdsControl, controlHolderName = value.controlHolderName,
                    allowsControlRequests = value.allowsControlRequests,
                    needsPasscode = value.needsPasscode, passcodeWasWrong = value.passcodeWasWrong,
                    failureReason = value.failureReason, state = value.state,
                    endedByBroadcaster = value.endedByBroadcaster,
                )
            }
        }
    }
    fun start(passcode: String? = null) { owner.start(passcode) }
    fun submitPasscode(code: String) { owner.submitPasscode(code) }
    fun retry() { owner.retry() }
    fun requestControl() { owner.requestControl() }
    fun releaseControl() { owner.releaseControl() }
    internal val holdsControl: Boolean get() = owner.status.value.holdsControl
    internal fun sendCommand(command: MonitorRelayWire.Command): Boolean = owner.sendCommand(command)
    internal fun commandAdmission(): RelayViewerCommandAdmission? = owner.commandAdmission()
    internal fun sendCommand(command: MonitorRelayWire.Command, admission: RelayViewerCommandAdmission): Boolean = owner.sendCommand(command, admission)
    suspend fun stop() { owner.stop(); session.close() }
    public companion object {
        /** The relay secrets' service: the Keystore key alias and its private file. Must not change. */
        public const val SECRETS_SERVICE: String = "openzcine.watcher-relay"
        private val rememberedPasscodes = java.util.concurrent.ConcurrentHashMap<String, String>()
        @Volatile private var processJpegOnly = false
        public fun seedJpegOnly() { processJpegOnly = true }
        internal fun resetJpegOnlyForTesting() { processJpegOnly = false }
    }
}

/**
 * The [CameraSession] the monitor shell needs, backed by the broadcast instead of a body. State
 * readouts arrive over the relay; the record toggle and AF taps become relay commands honoured
 * only while this watcher holds control; control is proxied, never transferred.
 */
class RelayCameraSession(private val controller: RelayWatchController) : CameraSession {
    private val observationLock = Any()
    private var source: java.util.UUID? = null
    private val mutableState =
        MutableStateFlow<CameraSessionState>(CameraSessionState.Connecting)
    override val state: StateFlow<CameraSessionState> = mutableState.asStateFlow()

    private val mutableRecording = MutableStateFlow(CameraRecordingState.STANDBY)
    private val mutableReportedRecording = MutableStateFlow<Boolean?>(null)
    override val reportedRecording: StateFlow<Boolean?> = mutableReportedRecording.asStateFlow()
    override val recordingState: StateFlow<CameraRecordingState> = mutableRecording.asStateFlow()

    internal fun beginSource(source: java.util.UUID) = synchronized(observationLock) {
        this.source = source
        mutableReportedRecording.value = null
        mutableState.value = CameraSessionState.Connecting
    }

    internal fun adopt(source: java.util.UUID, displayName: String) = synchronized(observationLock) {
        if (this.source != source) return@synchronized
        mutableState.value =
            CameraSessionState.Connected(
                CameraIdentity(name = displayName, model = displayName, serialNumber = "")
            )
    }

    internal fun applyState(source: java.util.UUID, state: MonitorRelayWire.State) = synchronized(observationLock) {
        if (this.source != source) return@synchronized
        mutableReportedRecording.value = state.isRecording
        if (this.source != source) return@synchronized
        mutableRecording.value =
            if (state.isRecording) CameraRecordingState.RECORDING else CameraRecordingState.STANDBY
    }

    internal fun close() = synchronized(observationLock) {
        source = null
        mutableReportedRecording.value = null
        mutableState.value = CameraSessionState.Disconnected
    }

    override suspend fun connect() {
        // The controller owns the socket lifecycle; the monitor never dials a broadcast.
    }

    override suspend fun disconnect() {
        // Leaving the watch surface stops the controller; nothing to do per-session.
    }

    override suspend fun setRecording(recording: Boolean) {
        // The legacy wire has only a toggle. Unknown cannot resolve an explicit target, and
        // a retry of an already reported target must never invert the host's take.
        val captured = controller.commandAdmission()
        val reported = mutableReportedRecording.value ?: throw CameraRecordingException.Unsupported
        if (reported == recording) return
        val admission = captured ?: throw CameraRecordingException.CommandRejected
        if (!controller.holdsControl) throw CameraRecordingException.CommandRejected
        if (!controller.sendCommand(MonitorRelayWire.Command.ToggleRecording, admission)) throw CameraRecordingException.CommandRejected
    }

    /**
     * A control-holding watcher's picker write goes out as the command iOS already sends and
     * executes (`applyPickerValue` on `videoSource == .relay`) rather than to a camera this
     * device does not have. Without this the interface default refused EVERY control, so no
     * watcher write ever left the device. A word the wire has no name for still refuses, which
     * the monitor's write loop already reports.
     */
    override suspend fun applyControl(control: CameraControl, label: String) {
        val captured = controller.commandAdmission()
        val command =
            RelayPickerVocabulary.command(control, label)
                ?: throw CameraControlException.UnsupportedSelection
        val admission = captured ?: throw CameraControlException.CommandRejected
        if (!controller.sendCommand(command, admission)) throw CameraControlException.CommandRejected
    }

    override suspend fun changeAfArea(point: CameraFocusPoint): Boolean {
        val admission = controller.commandAdmission() ?: return false
        val (width, height) = controller.focusCoordinateSpace ?: return false
        return controller.sendCommand(
            MonitorRelayWire.Command.FocusPoint(
                cameraX = point.x,
                cameraY = point.y,
                coordinateWidth = width,
                coordinateHeight = height,
            ), admission,
        )
    }
}
