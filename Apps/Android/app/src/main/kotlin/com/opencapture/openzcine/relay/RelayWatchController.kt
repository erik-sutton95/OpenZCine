package com.opencapture.openzcine.relay

import com.opencapture.openzcine.core.CameraControl
import com.opencapture.openzcine.core.CameraControlException
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
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.launch
import kotlinx.coroutines.withTimeoutOrNull

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
    /** Fired once when this device latches jpeg-only — the shell persists the verdict. */
    private val onJpegOnlyLatched: (() -> Unit)? = null,
    /** Fired when a passcode is accepted for [broadcast] — the shell persists it per host. */
    private val onPasscodeRemembered: ((String) -> Unit)? = null,
    /** Wall-clock budget for the first decoded HEVC frame; injectable for tests. */
    private val hevcDecodeDeadlineMillis: Long = HEVC_DECODE_DEADLINE_MILLIS,
    /** Wall-clock budget for a connected-but-silent broadcast; injectable for tests. */
    private val stallDeadlineMillis: Long = STALL_DEADLINE_MILLIS,
    /** Log seam so JVM unit tests can run the latch paths (android.util.Log is a stub there). */
    private val log: (String) -> Unit = { android.util.Log.i("RelayHEVC", it) },
) {
    private val mutableUi = MutableStateFlow(RelayWatchUiState())
    val ui: StateFlow<RelayWatchUiState> = mutableUi.asStateFlow()

    val frameSource = RelayLiveFrameSource()

    /**
     * Latched once this device's HEVC decoders have exhausted their attempts on the stream:
     * every later join declares `codecs=["jpeg"]` and the host serves JPEG instead — codec
     * negotiation for hardware the stream defeats (no Main10 decode on low-end chipsets).
     * Process-wide, not per-join: the chipset does not change between joins, and re-probing
     * costs ~45 s of black feed every time. A fresh launch re-probes, so a stream the
     * hardware CAN decode is never locked out for good.
     */
    private var jpegOnly: Boolean
        get() = processJpegOnly
        set(value) {
            processJpegOnly = value
        }
    val session: RelayCameraSession = RelayCameraSession(this)

    private var client: MonitorRelayClient? = null
    private var eventsJob: Job? = null
    private var rejoinJob: Job? = null
    private var hevcDeadlineJob: Job? = null
    private var stallJob: Job? = null
    private var passcode: String? = null
    private var lastFrameAtMillis: Long = 0
    /** Latest frame's camera coordinate space, for focus commands. */
    internal var focusCoordinateSpace: Pair<Int, Int>? = null

    fun start(passcode: String? = null) {
        // A remembered code joins without asking again — the controller is rebuilt per join, so
        // holding it in the instance meant every rejoin re-prompted (iOS remembers per
        // broadcaster in `storedRelayPasscode(forHost:)`).
        this.passcode = passcode ?: rememberedPasscodes[broadcast.name]
        join()
    }

    private fun join() {
        eventsJob?.cancel()
        stallJob?.cancel()
        lastFrameAtMillis = System.currentTimeMillis()
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
                            lastFrameAtMillis = System.currentTimeMillis()
                            event.metadata.focus?.let {
                                focusCoordinateSpace = it.coordinateWidth to it.coordinateHeight
                            }
                            frameSource.submit(event.metadata, event.image)
                            if (event.metadata.codec == MonitorRelayWire.FrameCodec.HEVC) {
                                armHevcDecodeDeadline()
                            }
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
                onJpegOnlyLatched?.invoke()
                log("decoders exhausted; rejoining for JPEG frames")
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
        armStallWatchdog()
    }

    fun submitPasscode(code: String) {
        val trimmed = code.trim()
        passcode = trimmed
        rememberedPasscodes[broadcast.name] = trimmed
        onPasscodeRemembered?.invoke(trimmed)
        retry()
    }

    /** Manual rejoin with the current credentials — the failure surface's Try again. */
    fun retry() {
        scope.launch {
            client?.stop()
            join()
        }
    }

    /**
     * Bounds the first-watch HEVC probe by wall clock. The decoder's own exhaustion path
     * (hardware fed-frame threshold, then the software rebuild bound, each gated on keyframe
     * arrivals) is evidence-complete but costs tens of seconds of black feed — longer than any
     * operator waits before backing out, and backing out discards the per-watch decoder state,
     * so across impatient retries the jpeg-only latch never got the chance to stick. HEVC
     * frames arriving with nothing decoded for [hevcDecodeDeadlineMillis] is already the
     * verdict: latch, persist, rejoin declaring `codecs=["jpeg"]`.
     *
     * Armed once, on the first received HEVC frame — the host only starts a joiner on a
     * keyframe, so the clock never starts mid-GOP. The frames flow replays its newest
     * emission, so a source that EVER decoded satisfies the wait instantly and a mid-stream
     * stall can never demote a working decoder.
     */
    private fun armHevcDecodeDeadline() {
        if (jpegOnly || hevcDeadlineJob != null) return
        hevcDeadlineJob =
            scope.launch {
                val decoded =
                    withTimeoutOrNull(hevcDecodeDeadlineMillis) { frameSource.frames.first() }
                if (decoded != null || jpegOnly) return@launch
                jpegOnly = true
                onJpegOnlyLatched?.invoke()
                log(
                    "no decoded frame within ${hevcDecodeDeadlineMillis} ms; " +
                        "rejoining for JPEG frames")
                retry()
            }
    }

    /**
     * The other dead shape of a viewer session: connected, but nothing arriving — what a
     * suspended or wedged broadcaster looks like from here. `Event.Closed` never fires for it
     * (the socket is fine), so without this the operator keeps a frozen frame and no message
     * forever. iOS's viewer watchdog rejoins on the same budget.
     *
     * Armed on RECEIPT, not on a decoded frame: a stream this device cannot decode is already
     * the jpeg-only latch's business ([armHevcDecodeDeadline]), and counting decodes here would
     * make the two paths race to rejoin for different reasons.
     *
     * A stall lands on the SAME surface a dropped socket does — reason, Try again, Leave — and
     * behind the same [armRejoin] ladder, because to the operator it is the same event.
     */
    private fun armStallWatchdog() {
        stallJob =
            scope.launch {
                while (true) {
                    // Never sleep past the budget being policed, so the verdict lands ON it
                    // rather than a poll later.
                    delay(minOf(STALL_POLL_MILLIS, stallDeadlineMillis))
                    if (mutableUi.value.phase != RelayWatchUiState.Phase.WATCHING) continue
                    if (System.currentTimeMillis() - lastFrameAtMillis < stallDeadlineMillis) {
                        continue
                    }
                    mutableUi.value =
                        mutableUi.value.copy(
                            phase = RelayWatchUiState.Phase.FAILED,
                            failureReason =
                                "The stream stalled — reconnecting. Make sure OpenZCine is " +
                                    "open on the broadcasting device.",
                        )
                    armRejoin()
                    return@launch
                }
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
        hevcDeadlineJob?.cancel()
        stallJob?.cancel()
        eventsJob?.cancel()
        client?.stop()
        frameSource.release()
        session.close()
    }

    public companion object {
        private const val REJOIN_INTERVAL_MILLIS = 3_000L

        /** iOS's viewer watchdog cadence and stall budget, to the second. */
        private const val STALL_POLL_MILLIS = 3_000L
        private const val STALL_DEADLINE_MILLIS = 8_000L

        /**
         * Watcher passcodes, remembered per broadcaster so a set's code is typed once per
         * device (iOS `relayWatcherPasscodes`). Process-wide because the controller is rebuilt
         * on every join — that is the whole bug.
         *
         * Persisting them across launches (what iOS does) is the shell's job, through the same
         * pair of seams the jpeg-only latch uses: [seedPasscodes] on the way in,
         * [onPasscodeRemembered] on the way out.
         */
        private val rememberedPasscodes = java.util.concurrent.ConcurrentHashMap<String, String>()

        /** Seeds remembered codes from whatever the shell persisted (empty = nothing stored). */
        public fun seedPasscodes(stored: Map<String, String>) {
            rememberedPasscodes.putAll(stored)
        }

        /**
         * Comfortably above a healthy first decode (the first received frame is a keyframe and
         * hardware pipelines emit within a handful of frames), far below the exhaustion path's
         * tens of seconds.
         */
        private const val HEVC_DECODE_DEADLINE_MILLIS = 6_000L

        /** See [jpegOnly] — one probe per process, not per join. */
        @Volatile private var processJpegOnly = false

        /**
         * Seeds the latch from a persisted verdict so a relaunch skips the decode probe
         * entirely. The shell scopes what it persists to the exact install — a new build may
         * carry a stream profile the hardware CAN decode, and must re-probe.
         */
        public fun seedJpegOnly() {
            processJpegOnly = true
        }

        /** Test-only: clears the process-wide latch so latch tests are order-independent. */
        internal fun resetJpegOnlyForTesting() {
            processJpegOnly = false
        }
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

    /**
     * A control-holding watcher's picker write goes out as the command iOS already sends and
     * executes (`applyPickerValue` on `videoSource == .relay`) rather than to a camera this
     * device does not have. Without this the interface default refused EVERY control, so no
     * watcher write ever left the device. A word the wire has no name for still refuses, which
     * the monitor's write loop already reports.
     */
    override suspend fun applyControl(control: CameraControl, label: String) {
        val command =
            RelayPickerVocabulary.command(control, label)
                ?: throw CameraControlException.UnsupportedSelection
        controller.sendCommand(command)
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
