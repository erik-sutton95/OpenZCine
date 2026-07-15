package com.opencapture.openzcine.bridge

import com.opencapture.openzcine.core.CameraControl
import com.opencapture.openzcine.core.CameraControlException
import com.opencapture.openzcine.core.CameraFocusException
import com.opencapture.openzcine.core.CameraFocusPoint
import com.opencapture.openzcine.core.CameraIdentity
import com.opencapture.openzcine.core.CameraPropertyRefreshFailure
import com.opencapture.openzcine.core.CameraPropertyRefreshStatus
import com.opencapture.openzcine.core.CameraPropertySnapshot
import com.opencapture.openzcine.core.CameraRecordingException
import com.opencapture.openzcine.core.CameraRecordingState
import com.opencapture.openzcine.core.CameraSession
import com.opencapture.openzcine.core.CameraSessionEvent
import com.opencapture.openzcine.core.CameraSessionState
import com.opencapture.openzcine.core.LiveFrameSource
import com.opencapture.openzcine.transport.UsbPtpTransport
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineDispatcher
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.channels.BufferOverflow
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableSharedFlow
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.SharedFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.asSharedFlow
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import java.util.concurrent.atomic.AtomicLong

/** Injectable JNI seam for deterministic Android session lifecycle tests. */
internal interface SwiftCoreSessionBridge {
    val isAvailable: Boolean

    fun connect(host: String, connectionOwner: Long, listener: SwiftCore.SessionListener)

    /** Starts the same Swift session layer over a platform-owned USB byte transport. */
    fun connectUsb(
        transport: UsbPtpTransport,
        host: String,
        cameraNameHint: String,
        connectionOwner: Long,
        listener: SwiftCore.SessionListener,
    ) {
        listener.onFailed("USB-C camera support is unavailable in this core build.")
    }

    fun startEventStream(listener: SwiftCore.SessionEventListener)

    fun readProperty(code: Int): String?

    fun refreshPropertySnapshot(request: Int, recording: Boolean, propertyCode: Long): String?

    /** Latest real native command RTT, or null when the active session has none. */
    fun latestRoundTripMilliseconds(): Double? = null

    fun setRecording(recording: Boolean): Int

    fun applyControl(control: CameraControl, label: String): Int

    fun changeAfArea(point: CameraFocusPoint): Int = SwiftCore.FOCUS_COMMAND_UNAVAILABLE

    fun resetFocusPoint(): Int = SwiftCore.FOCUS_COMMAND_UNAVAILABLE

    fun disconnect(connectionOwner: Long)

    data object Production : SwiftCoreSessionBridge {
        override val isAvailable: Boolean
            get() = SwiftCore.isAvailable

        override fun connect(
            host: String,
            connectionOwner: Long,
            listener: SwiftCore.SessionListener,
        ) {
            SwiftCore.sessionConnect(host, connectionOwner, listener)
        }

        override fun connectUsb(
            transport: UsbPtpTransport,
            host: String,
            cameraNameHint: String,
            connectionOwner: Long,
            listener: SwiftCore.SessionListener,
        ) {
            SwiftCore.sessionConnectUsb(transport, host, cameraNameHint, connectionOwner, listener)
        }

        override fun startEventStream(listener: SwiftCore.SessionEventListener) {
            SwiftCore.sessionStartEventStream(listener)
        }

        override fun readProperty(code: Int): String? = SwiftCore.sessionReadProperty(code)

        override fun refreshPropertySnapshot(
            request: Int,
            recording: Boolean,
            propertyCode: Long,
        ): String? = SwiftCore.sessionRefreshPropertySnapshot(request, recording, propertyCode)

        override fun latestRoundTripMilliseconds(): Double? =
            SwiftCore.sessionLatestRoundTripMilliseconds().takeIf { it.isFinite() && it > 0.0 }

        override fun setRecording(recording: Boolean): Int =
            SwiftCore.sessionSetRecording(recording)

        override fun applyControl(control: CameraControl, label: String): Int =
            SwiftCore.sessionApplyControl(control.nativeSelector, label)

        override fun changeAfArea(point: CameraFocusPoint): Int =
            SwiftCore.sessionChangeAfArea(point.x, point.y)

        override fun resetFocusPoint(): Int = SwiftCore.sessionResetFocusPoint()

        override fun disconnect(connectionOwner: Long) {
            SwiftCore.sessionDisconnect(connectionOwner)
        }
    }
}

/** Stable semantic selector mirrored by `AndroidCameraControlWire` in Swift. */
private val CameraControl.nativeSelector: Int
    get() =
        when (this) {
            CameraControl.ISO -> 0
            CameraControl.SHUTTER -> 1
            CameraControl.IRIS -> 2
            CameraControl.WHITE_BALANCE -> 3
            CameraControl.FOCUS_MODE -> 4
            CameraControl.FOCUS_AREA -> 5
            CameraControl.FOCUS_SUBJECT -> 6
            CameraControl.EXPOSURE_MODE -> 7
            CameraControl.AUDIO_SENSITIVITY -> 8
            CameraControl.AUDIO_INPUT -> 9
            CameraControl.WIND_FILTER -> 10
            CameraControl.ATTENUATOR -> 11
            CameraControl.AUDIO_32_BIT_FLOAT -> 12
            CameraControl.BASE_ISO -> 13
            CameraControl.SHUTTER_MODE -> 14
            CameraControl.SHUTTER_LOCK -> 15
            CameraControl.WHITE_BALANCE_TINT -> 16
            CameraControl.RESOLUTION_FRAMERATE -> 17
            CameraControl.CODEC -> 18
            CameraControl.VIBRATION_REDUCTION -> 19
            CameraControl.ELECTRONIC_VR -> 20
        }

/**
 * Production [CameraSession] backed by the shared Swift core's PTP-IP
 * protocol/session layer over JNI: connect drives the Init handshake plus the
 * Nikon open/pair/identify sequence inside the `.so`, and property reads are
 * decoded by the core's codecs. This class is only state plumbing — no
 * protocol logic lives on the Kotlin side.
 *
 * @property host Numeric IPv4 camera address (from NSD discovery, the fixed
 *   camera-AP host, or a debug intent extra), or a privacy-safe USB host key.
 * @property phaseLogger Optional sink for progress phases (name + detail),
 *   e.g. logcat in the debug probe. Called on a background thread.
 */
class SwiftCoreCameraSession internal constructor(
    private val host: String,
    private val phaseLogger: (String, String) -> Unit,
    private val core: SwiftCoreSessionBridge,
    private val propertyRefreshScope: CoroutineScope =
        CoroutineScope(SupervisorJob() + Dispatchers.Default),
    private val propertyRefreshDispatcher: CoroutineDispatcher = Dispatchers.IO,
    private val propertyPollIntervalMillis: Long = PROPERTY_POLL_INTERVAL_MILLIS,
    private val propertyEventDebounceMillis: Long = PROPERTY_EVENT_DEBOUNCE_MILLIS,
    private val automaticallyRefreshProperties: Boolean = true,
    private val usbTransport: UsbPtpTransport? = null,
    private val cameraNameHint: String? = null,
) : CameraSession {
    /** Production session binding the Kotlin shell to the shared Swift facade. */
    public constructor(
        host: String,
        phaseLogger: (String, String) -> Unit = { _, _ -> },
    ) : this(host, phaseLogger, SwiftCoreSessionBridge.Production)

    /** Production USB-C session using a claimed Android PTP byte transport. */
    public constructor(
        host: String,
        cameraNameHint: String,
        usbTransport: UsbPtpTransport,
        phaseLogger: (String, String) -> Unit = { _, _ -> },
    ) : this(
        host = host,
        phaseLogger = phaseLogger,
        core = SwiftCoreSessionBridge.Production,
        usbTransport = usbTransport,
        cameraNameHint = cameraNameHint,
    )

    private val _state = MutableStateFlow<CameraSessionState>(CameraSessionState.Disconnected)
    override val state: StateFlow<CameraSessionState> = _state.asStateFlow()
    private val attemptLock = Any()
    private var nextAttempt = 0L
    private var activeAttempt: Long? = null
    /** Opaque native owner for [activeAttempt], unique across session instances. */
    private var activeConnectionOwner: Long? = null

    private val _recordingState = MutableStateFlow(CameraRecordingState.STANDBY)
    override val recordingState: StateFlow<CameraRecordingState> = _recordingState.asStateFlow()

    private val _cameraProperties = MutableStateFlow(CameraPropertySnapshot())
    override val cameraProperties: StateFlow<CameraPropertySnapshot> = _cameraProperties.asStateFlow()

    private val _propertyRefreshStatus =
        MutableStateFlow<CameraPropertyRefreshStatus>(CameraPropertyRefreshStatus.Idle)
    override val propertyRefreshStatus: StateFlow<CameraPropertyRefreshStatus> =
        _propertyRefreshStatus.asStateFlow()

    private val _latestCommandRoundTripMilliseconds = MutableStateFlow<Double?>(null)
    override val latestCommandRoundTripMilliseconds: StateFlow<Double?> =
        _latestCommandRoundTripMilliseconds.asStateFlow()

    /** Serializes poll, manual, and event-triggered refresh work into one JNI call at a time. */
    private val propertyRefreshMutex = Mutex()

    /** Guards refresh job replacement and the coalesced event property queue. */
    private val propertyRefreshJobLock = Any()
    private var propertyPollingJob: Job? = null
    private var eventPropertyRefreshJob: Job? = null
    private val pendingEventPropertyCodes = LinkedHashSet<Long>()

    private val _events =
        MutableSharedFlow<CameraSessionEvent>(
            replay = 0,
            extraBufferCapacity = EVENT_BUFFER_CAPACITY,
            onBufferOverflow = BufferOverflow.DROP_OLDEST,
        )
    override val events: SharedFlow<CameraSessionEvent> = _events.asSharedFlow()

    /**
     * Serializes camera-changing commands with each other and with disconnect,
     * so an in-flight JNI call never races teardown or a competing record /
     * property-control transaction.
     */
    private val cameraCommandMutex = Mutex()

    /** Newer tap generations invalidate coordinates still waiting for native work. */
    private val focusRequestVersion = AtomicLong()

    /**
     * The iOS shell defers camera-header readback for 1.5 seconds after an app
     * record command. The Android facade does the same: some bodies publish a
     * stale live-view header for a few frames after accepting the operation.
     */
    @Volatile private var ignoreLiveRecordingStateUntilNanos: Long = 0L

    /** Incremented only by authoritative camera record events. */
    @Volatile private var cameraRecordingEventVersion: Long = 0L

    /**
     * Live-view frames from the Swift core's pump. Collect only while the
     * session is [CameraSessionState.Connected]; collection starts live view
     * on the camera and cancelling it sends `EndLiveView` (never leave the
     * body streaming to a hidden feed — the heat-audit rule).
     */
    val liveFrames: LiveFrameSource =
        SwiftCoreLiveFrameSource(
            onRecordingState = ::applyCameraRecordingState,
            onCommandRoundTrip = ::updateRoundTripMeasurement,
        )

    /**
     * Connects and suspends until the session is [CameraSessionState.Connected]
     * or back at [CameraSessionState.Disconnected]. A missing native library
     * (APK built without `just android-core`) stays disconnected without
     * crashing.
     */
    override suspend fun connect() {
        if (!core.isAvailable) return
        val attempt = beginAttempt() ?: return
        val connectionOwner = connectionOwnerFor(attempt) ?: return
        try {
            val listener =
                object : SwiftCore.SessionListener {
                    override fun onPhase(phase: String, detail: String) {
                        if (isCurrentAttempt(attempt)) phaseLogger(phase, detail)
                    }

                    override fun onConnected(name: String, model: String, serialNumber: String) {
                        if (
                            updateAttempt(
                                attempt,
                                CameraSessionState.Connected(
                                    CameraIdentity(name, model, serialNumber),
                                ),
                            )
                        ) {
                            ignoreLiveRecordingStateUntilNanos = 0L
                            cameraRecordingEventVersion = 0L
                            _recordingState.value = CameraRecordingState.STANDBY
                            _cameraProperties.value = CameraPropertySnapshot()
                            _propertyRefreshStatus.value = CameraPropertyRefreshStatus.Idle
                            updateRoundTripMeasurement()
                            startEventStream(attempt)
                            if (automaticallyRefreshProperties) {
                                startPropertyRefresh(attempt)
                            }
                        }
                    }

                    override fun onFailed(message: String) {
                        if (updateAttempt(attempt, CameraSessionState.Disconnected)) {
                            ignoreLiveRecordingStateUntilNanos = 0L
                            cameraRecordingEventVersion = 0L
                            _recordingState.value = CameraRecordingState.STANDBY
                            stopPropertyRefresh(clearSnapshot = true)
                            _latestCommandRoundTripMilliseconds.value = null
                            phaseLogger("failed", message)
                        }
                    }
            }
            if (usbTransport == null) {
                core.connect(host, connectionOwner, listener)
            } else {
                core.connectUsb(
                    transport = usbTransport,
                    host = host,
                    cameraNameHint = cameraNameHint.orEmpty(),
                    connectionOwner = connectionOwner,
                    listener = listener,
                )
            }
            _state.first { it !is CameraSessionState.Connecting || !isCurrentAttempt(attempt) }
            clearCompletedConnectionAttempt(attempt)
        } catch (error: CancellationException) {
            cancelAttempt(attempt)
            throw error
        } catch (error: Exception) {
            phaseLogger("failed", error.message ?: "Camera connection failed.")
            cancelAttempt(attempt)
        }
    }

    /**
     * Reads one camera property (see `SwiftCore.PROP_*`), decoded by the Swift
     * core. Null until connected or when the camera rejects the read.
     */
    suspend fun readProperty(code: Int): String? =
        if (_state.value is CameraSessionState.Connected) {
            withContext(Dispatchers.IO) { core.readProperty(code) }
        } else {
            null
        }

    /**
     * Requests a bounded immediate semantic camera-property refresh. Existing
     * values survive a body-specific unsupported field; inspect
     * [propertyRefreshStatus] for that non-terminal result.
     */
    override suspend fun refreshProperties() {
        val attempt = connectedAttempt()
        if (attempt == null) {
            _propertyRefreshStatus.value =
                CameraPropertyRefreshStatus.Degraded(CameraPropertyRefreshFailure.NOT_CONNECTED)
            return
        }
        refreshCameraProperties(
            attempt = attempt,
            request = SwiftCore.PROPERTY_REFRESH_BOOTSTRAP,
            propertyCode = 0L,
        )
    }

    /**
     * Sends the Nikon movie-record operation through Swift and updates the
     * state flow only after that command is accepted by the camera. Once a
     * command begins it runs non-cancellably: cancelling the Compose scope
     * cannot leave the shell reporting an old state after a native operation
     * already reached the body.
     */
    override suspend fun setRecording(recording: Boolean) {
        cameraCommandMutex.withLock {
            if (_state.value !is CameraSessionState.Connected) {
                throw CameraRecordingException.NotConnected
            }
            if (!core.isAvailable) {
                throw CameraRecordingException.CoreUnavailable
            }

            val target = if (recording) CameraRecordingState.RECORDING else CameraRecordingState.STANDBY
            if (_recordingState.value == target) return

            val rollback = if (recording) CameraRecordingState.STANDBY else CameraRecordingState.RECORDING
            val eventVersionAtCommandStart = cameraRecordingEventVersion
            _recordingState.value =
                if (recording) CameraRecordingState.STARTING else CameraRecordingState.STOPPING
            // Suppress a stale live-view header both while the command is
            // queued behind a frame read and during the body handoff after it.
            ignoreLiveRecordingStateUntilNanos = Long.MAX_VALUE

            try {
                val nativeResult =
                    withContext(Dispatchers.IO + NonCancellable) {
                        core.setRecording(recording)
                    }
                updateRoundTripMeasurement()
                nativeResult.throwIfRecordingCommandFailed()
                if (
                    cameraRecordingEventVersion == eventVersionAtCommandStart &&
                        _state.value is CameraSessionState.Connected
                ) {
                    _recordingState.value = target
                    ignoreLiveRecordingStateUntilNanos =
                        System.nanoTime() + RECORDING_READBACK_GRACE_NANOS
                } else {
                    // A PTP event arrived while the command crossed JNI. It
                    // is more authoritative than this local command result.
                    ignoreLiveRecordingStateUntilNanos = 0L
                }
            } catch (error: CameraRecordingException) {
                if (
                    cameraRecordingEventVersion == eventVersionAtCommandStart &&
                        _state.value is CameraSessionState.Connected
                ) {
                    _recordingState.value = rollback
                }
                ignoreLiveRecordingStateUntilNanos = 0L
                throw error
            } catch (_: Throwable) {
                if (
                    cameraRecordingEventVersion == eventVersionAtCommandStart &&
                        _state.value is CameraSessionState.Connected
                ) {
                    _recordingState.value = rollback
                }
                ignoreLiveRecordingStateUntilNanos = 0L
                throw CameraRecordingException.TransportFailed
            }
        }
    }

    /**
     * Applies a typed human-readable camera-control selection through the Swift
     * core. Kotlin passes no PTP property bytes: Swift validates [label],
     * selects the Nikon property write(s), and serializes them with live view.
     */
    override suspend fun applyControl(control: CameraControl, label: String) {
        cameraCommandMutex.withLock {
            if (_state.value !is CameraSessionState.Connected) {
                throw CameraControlException.NotConnected
            }
            if (!core.isAvailable) {
                throw CameraControlException.CoreUnavailable
            }

            try {
                val nativeResult =
                    withContext(Dispatchers.IO + NonCancellable) {
                        core.applyControl(control, label)
                    }
                updateRoundTripMeasurement()
                nativeResult.throwIfControlCommandFailed()
            } catch (error: CameraControlException) {
                throw error
            } catch (_: Throwable) {
                throw CameraControlException.TransportFailed
            }
        }
    }

    /**
     * Sends at most the newest waiting AF coordinate. A command already inside
     * native I/O is allowed to finish, while every superseded waiter becomes a
     * no-op instead of replaying stale taps afterward.
     */
    override suspend fun changeAfArea(point: CameraFocusPoint): Boolean {
        val requestVersion = focusRequestVersion.incrementAndGet()
        return cameraCommandMutex.withLock {
            if (_state.value !is CameraSessionState.Connected) {
                throw CameraFocusException.NotConnected
            }
            if (!core.isAvailable) {
                throw CameraFocusException.CoreUnavailable
            }
            if (requestVersion != focusRequestVersion.get()) return@withLock false

            try {
                val nativeResult =
                    withContext(Dispatchers.IO + NonCancellable) {
                        core.changeAfArea(point)
                    }
                updateRoundTripMeasurement()
                nativeResult.throwIfFocusCommandFailed()
                true
            } catch (error: CameraFocusException) {
                throw error
            } catch (_: Throwable) {
                throw CameraFocusException.TransportFailed
            }
        }
    }

    /** Runs the shared camera-authoritative recenter sequence on native I/O. */
    override suspend fun resetFocusPoint() {
        focusRequestVersion.incrementAndGet()
        cameraCommandMutex.withLock {
            if (_state.value !is CameraSessionState.Connected) {
                throw CameraFocusException.NotConnected
            }
            if (!core.isAvailable) {
                throw CameraFocusException.CoreUnavailable
            }

            try {
                val nativeResult =
                    withContext(Dispatchers.IO + NonCancellable) {
                        core.resetFocusPoint()
                    }
                updateRoundTripMeasurement()
                nativeResult.throwIfFocusCommandFailed()
            } catch (error: CameraFocusException) {
                throw error
            } catch (_: Throwable) {
                throw CameraFocusException.TransportFailed
            }
        }
    }

    override suspend fun disconnect() {
        focusRequestVersion.incrementAndGet()
        // A manual refresh is not owned by either cancellable refresh job, so
        // clear state only after this mutex waits for any such JNI call. That
        // prevents its final readback from repopulating a disconnected session.
        stopPropertyRefresh(clearSnapshot = false)
        val connectionOwner = invalidateAttempt()
        withContext(NonCancellable) {
            cameraCommandMutex.withLock {
                try {
                    if (core.isAvailable && connectionOwner != null) {
                        withContext(Dispatchers.IO) { core.disconnect(connectionOwner) }
                    }
                } finally {
                    ignoreLiveRecordingStateUntilNanos = 0L
                    cameraRecordingEventVersion = 0L
                    _recordingState.value = CameraRecordingState.STANDBY
                    _cameraProperties.value = CameraPropertySnapshot()
                    _propertyRefreshStatus.value = CameraPropertyRefreshStatus.Idle
                    _latestCommandRoundTripMilliseconds.value = null
                    _state.value = CameraSessionState.Disconnected
                }
            }
        }
    }

    /** Applies camera-authoritative record state from a decoded live-view frame. */
    private fun applyCameraRecordingState(recording: Boolean, force: Boolean = false) {
        if (_state.value !is CameraSessionState.Connected) return
        if (!force && System.nanoTime() < ignoreLiveRecordingStateUntilNanos) return
        _recordingState.value =
            if (recording) CameraRecordingState.RECORDING else CameraRecordingState.STANDBY
    }

    /** Starts the native event drain after the current connection is established. */
    private fun startEventStream(attempt: Long) {
        try {
            core.startEventStream(
                object : SwiftCore.SessionEventListener {
                    override fun onEvent(
                        rawEventCode: Int,
                        transactionId: Long,
                        rawParameters: LongArray,
                    ) {
                        applyCameraEvent(attempt, rawEventCode, transactionId, rawParameters)
                    }

                    override fun onEnded(message: String?) {
                        if (message != null) markEventChannelEnded(attempt, message)
                    }
                },
            )
        } catch (error: Throwable) {
            if (isCurrentAttempt(attempt)) {
                phaseLogger("eventChannelEnded", error.message ?: "Camera event channel failed.")
            }
        }
    }

    /**
     * Makes an unexpected event-channel loss terminal for this session. The
     * native reader has already closed the command socket before this callback,
     * so dropping to disconnected cannot leave a hidden, usable control link.
     */
    private fun markEventChannelEnded(attempt: Long, message: String) {
        val ownsAttempt =
            synchronized(attemptLock) {
                if (activeAttempt != attempt) return@synchronized false
                activeAttempt = null
                activeConnectionOwner = null
                _state.value = CameraSessionState.Disconnected
                true
            }
        if (!ownsAttempt) return
        ignoreLiveRecordingStateUntilNanos = 0L
        cameraRecordingEventVersion = 0L
        _recordingState.value = CameraRecordingState.STANDBY
        stopPropertyRefresh(clearSnapshot = true)
        phaseLogger("eventChannelEnded", message)
    }

    /** Maps only established event codes; all other camera data remains raw. */
    private fun applyCameraEvent(
        attempt: Long,
        rawEventCode: Int,
        transactionId: Long,
        rawParameters: LongArray,
    ) {
        if (!isCurrentAttempt(attempt) || _state.value !is CameraSessionState.Connected) return
        val code = rawEventCode and EVENT_CODE_MASK
        val parameters = rawParameters.map { it and UINT32_MASK }
        val event =
            when (code) {
                MOVIE_RECORD_STARTED ->
                    CameraSessionEvent.RecordingStarted(
                        code,
                        transactionId and UINT32_MASK,
                        parameters,
                    )
                MOVIE_RECORD_COMPLETE ->
                    CameraSessionEvent.RecordingStopped(
                        code,
                        transactionId and UINT32_MASK,
                        parameters,
                    )
                MOVIE_RECORD_INTERRUPTED ->
                    CameraSessionEvent.RecordingInterrupted(
                        code,
                        transactionId and UINT32_MASK,
                        parameters,
                        parameters.firstOrNull(),
                    )
                DEVICE_PROPERTY_CHANGED ->
                    CameraSessionEvent.PropertyChanged(
                        code,
                        transactionId and UINT32_MASK,
                        parameters,
                        parameters.firstOrNull(),
                    )
                else ->
                    CameraSessionEvent.Unknown(
                        code,
                        transactionId and UINT32_MASK,
                        parameters,
                    )
            }
        _events.tryEmit(event)

        when (event) {
            is CameraSessionEvent.RecordingStarted -> {
                cameraRecordingEventVersion += 1
                applyCameraRecordingState(recording = true, force = true)
            }
            is CameraSessionEvent.RecordingStopped -> {
                cameraRecordingEventVersion += 1
                applyCameraRecordingState(recording = false, force = true)
            }
            is CameraSessionEvent.RecordingInterrupted -> {
                cameraRecordingEventVersion += 1
                applyCameraRecordingState(recording = false, force = true)
            }
            is CameraSessionEvent.PropertyChanged -> {
                scheduleEventPropertyRefresh(attempt, event.propertyCode)
            }
            is CameraSessionEvent.Unknown -> Unit
        }
    }

    /** Starts one initial property burst followed by conservative round-robin reads. */
    private fun startPropertyRefresh(attempt: Long) {
        stopPropertyRefresh(clearSnapshot = false)
        _propertyRefreshStatus.value = CameraPropertyRefreshStatus.Refreshing
        val job =
            propertyRefreshScope.launch {
                refreshCameraProperties(
                    attempt = attempt,
                    request = SwiftCore.PROPERTY_REFRESH_BOOTSTRAP,
                    propertyCode = 0L,
                )
                while (isActive && ownsConnectedAttempt(attempt)) {
                    delay(propertyPollIntervalMillis.coerceAtLeast(1L))
                    if (!isActive || !ownsConnectedAttempt(attempt)) break
                    refreshCameraProperties(
                        attempt = attempt,
                        request = SwiftCore.PROPERTY_REFRESH_NEXT,
                        propertyCode = 0L,
                    )
                }
            }
        synchronized(propertyRefreshJobLock) {
            if (ownsConnectedAttempt(attempt)) {
                propertyPollingJob = job
            } else {
                job.cancel()
            }
        }
    }

    /** Cancels polling and pending event work before connection teardown/retry. */
    private fun stopPropertyRefresh(clearSnapshot: Boolean) {
        synchronized(propertyRefreshJobLock) {
            propertyPollingJob?.cancel()
            propertyPollingJob = null
            eventPropertyRefreshJob?.cancel()
            eventPropertyRefreshJob = null
            pendingEventPropertyCodes.clear()
        }
        if (clearSnapshot) {
            _cameraProperties.value = CameraPropertySnapshot()
        }
        _propertyRefreshStatus.value = CameraPropertyRefreshStatus.Idle
    }

    /** Coalesces a burst of camera property events into a bounded delayed refresh. */
    private fun scheduleEventPropertyRefresh(attempt: Long, propertyCode: Long?) {
        val rawPropertyCode = guardPropertyCode(propertyCode) ?: return
        if (!ownsConnectedAttempt(attempt)) return
        synchronized(propertyRefreshJobLock) {
            if (!ownsConnectedAttempt(attempt)) return
            pendingEventPropertyCodes += rawPropertyCode
            eventPropertyRefreshJob?.cancel()
            eventPropertyRefreshJob =
                propertyRefreshScope.launch {
                    delay(propertyEventDebounceMillis.coerceAtLeast(1L))
                    val propertyCodes =
                        synchronized(propertyRefreshJobLock) {
                            if (!ownsConnectedAttempt(attempt)) {
                                pendingEventPropertyCodes.clear()
                                emptyList()
                            } else {
                                pendingEventPropertyCodes
                                    .take(MAX_EVENT_PROPERTY_REFRESHES)
                                    .also { pendingEventPropertyCodes.clear() }
                            }
                        }
                    for (rawCode in propertyCodes) {
                        if (!isActive || !ownsConnectedAttempt(attempt)) break
                        refreshCameraProperties(
                            attempt = attempt,
                            request = SwiftCore.PROPERTY_REFRESH_EVENT,
                            propertyCode = rawCode,
                        )
                    }
                }
        }
    }

    /** Rejects invalid raw-event values without inventing a property identifier. */
    private fun guardPropertyCode(propertyCode: Long?): Long? =
        propertyCode?.takeIf { it >= 0L && it <= UINT32_MASK }

    /**
     * Runs one native semantic readback at a time and never lets a failed
     * noncritical read overwrite last-known values or connection state.
     */
    private suspend fun refreshCameraProperties(
        attempt: Long,
        request: Int,
        propertyCode: Long,
    ) {
        propertyRefreshMutex.withLock {
            if (!ownsConnectedAttempt(attempt)) return
            if (!core.isAvailable) {
                _propertyRefreshStatus.value =
                    CameraPropertyRefreshStatus.Degraded(
                        CameraPropertyRefreshFailure.CORE_UNAVAILABLE,
                    )
                return
            }
            _propertyRefreshStatus.value = CameraPropertyRefreshStatus.Refreshing
            cameraCommandMutex.withLock {
                if (!ownsConnectedAttempt(attempt)) return
                val readback = readNativePropertySnapshot(request, propertyCode)
                updateRoundTripMeasurement()
                if (!ownsConnectedAttempt(attempt)) return
                if (
                    readback.isValid &&
                        readback.result != NativePropertyRefreshResult.NO_SESSION
                ) {
                    _cameraProperties.value = readback.snapshot
                }
                _propertyRefreshStatus.value = readback.result.toRefreshStatus()
            }
        }
    }

    /** Performs one blocking semantic readback and maps bridge failures to a typed result. */
    private suspend fun readNativePropertySnapshot(
        request: Int,
        propertyCode: Long,
    ): CameraPropertyRefreshWireResult {
        val payload =
            try {
                withContext(propertyRefreshDispatcher) {
                    core.refreshPropertySnapshot(
                        request = request,
                        recording = _recordingState.value == CameraRecordingState.RECORDING,
                        propertyCode = propertyCode,
                    )
                }
            } catch (error: CancellationException) {
                throw error
            } catch (_: Throwable) {
                null
            }
        return CameraPropertySnapshotWire.decode(payload)
    }

    /** Resolves a native non-terminal result to the public Android state model. */
    private fun NativePropertyRefreshResult.toRefreshStatus(): CameraPropertyRefreshStatus =
        when (this) {
            NativePropertyRefreshResult.ACCEPTED -> CameraPropertyRefreshStatus.Ready
            NativePropertyRefreshResult.NO_SESSION ->
                CameraPropertyRefreshStatus.Degraded(CameraPropertyRefreshFailure.NOT_CONNECTED)
            NativePropertyRefreshResult.MEDIA_BUSY ->
                CameraPropertyRefreshStatus.Degraded(CameraPropertyRefreshFailure.MEDIA_BUSY)
            NativePropertyRefreshResult.UNSUPPORTED ->
                CameraPropertyRefreshStatus.Degraded(
                    CameraPropertyRefreshFailure.UNSUPPORTED_PROPERTY,
                )
            NativePropertyRefreshResult.TRANSPORT_FAILED ->
                CameraPropertyRefreshStatus.Degraded(
                    CameraPropertyRefreshFailure.TRANSPORT_FAILED,
                )
        }

    private fun Int.throwIfRecordingCommandFailed() {
        when (this) {
            SwiftCore.RECORDING_COMMAND_ACCEPTED -> Unit
            SwiftCore.RECORDING_COMMAND_NO_SESSION -> throw CameraRecordingException.NotConnected
            SwiftCore.RECORDING_COMMAND_MEDIA_BUSY -> throw CameraRecordingException.MediaBusy
            SwiftCore.RECORDING_COMMAND_REJECTED -> throw CameraRecordingException.CommandRejected
            SwiftCore.RECORDING_COMMAND_TRANSPORT_FAILED ->
                throw CameraRecordingException.TransportFailed
            else -> throw CameraRecordingException.TransportFailed
        }
    }

    private fun Int.throwIfControlCommandFailed() {
        when (this) {
            SwiftCore.CONTROL_COMMAND_ACCEPTED -> Unit
            SwiftCore.CONTROL_COMMAND_NO_SESSION -> throw CameraControlException.NotConnected
            SwiftCore.CONTROL_COMMAND_MEDIA_BUSY -> throw CameraControlException.MediaBusy
            SwiftCore.CONTROL_COMMAND_UNSUPPORTED -> throw CameraControlException.UnsupportedSelection
            SwiftCore.CONTROL_COMMAND_REJECTED -> throw CameraControlException.CommandRejected
            SwiftCore.CONTROL_COMMAND_READBACK_MISMATCH ->
                throw CameraControlException.ReadbackMismatch
            SwiftCore.CONTROL_COMMAND_TRANSPORT_FAILED ->
                throw CameraControlException.TransportFailed
            else -> throw CameraControlException.TransportFailed
        }
    }

    private fun updateRoundTripMeasurement() {
        if (_state.value !is CameraSessionState.Connected) {
            _latestCommandRoundTripMilliseconds.value = null
            return
        }
        _latestCommandRoundTripMilliseconds.value = core.latestRoundTripMilliseconds()
    }

    private fun Int.throwIfFocusCommandFailed() {
        when (this) {
            SwiftCore.FOCUS_COMMAND_ACCEPTED -> Unit
            SwiftCore.FOCUS_COMMAND_NO_SESSION -> throw CameraFocusException.NotConnected
            SwiftCore.FOCUS_COMMAND_MEDIA_BUSY -> throw CameraFocusException.MediaBusy
            SwiftCore.FOCUS_COMMAND_UNAVAILABLE -> throw CameraFocusException.Unavailable
            SwiftCore.FOCUS_COMMAND_REJECTED -> throw CameraFocusException.CommandRejected
            SwiftCore.FOCUS_COMMAND_TRANSPORT_FAILED ->
                throw CameraFocusException.TransportFailed
            else -> throw CameraFocusException.TransportFailed
        }
    }

    private companion object {
        val nextConnectionOwner = AtomicLong()
        const val RECORDING_READBACK_GRACE_NANOS: Long = 1_500_000_000L
        const val PROPERTY_POLL_INTERVAL_MILLIS: Long = 1_500L
        const val PROPERTY_EVENT_DEBOUNCE_MILLIS: Long = 250L
        const val MAX_EVENT_PROPERTY_REFRESHES: Int = 4
        const val EVENT_BUFFER_CAPACITY: Int = 64
        const val EVENT_CODE_MASK: Int = 0xFFFF
        const val UINT32_MASK: Long = 0xFFFF_FFFFL
        const val DEVICE_PROPERTY_CHANGED: Int = 0x4006
        const val MOVIE_RECORD_INTERRUPTED: Int = 0xC105
        const val MOVIE_RECORD_COMPLETE: Int = 0xC108
        const val MOVIE_RECORD_STARTED: Int = 0xC10A
    }

    private fun beginAttempt(): Long? {
        val attempt =
            synchronized(attemptLock) {
                if (_state.value !is CameraSessionState.Disconnected) return@synchronized null
                nextAttempt += 1
                activeAttempt = nextAttempt
                activeConnectionOwner = nextConnectionOwner.incrementAndGet()
                _state.value = CameraSessionState.Connecting
                nextAttempt
            }
        if (attempt != null) {
            stopPropertyRefresh(clearSnapshot = true)
            _latestCommandRoundTripMilliseconds.value = null
        }
        return attempt
    }

    private fun isCurrentAttempt(attempt: Long): Boolean =
        synchronized(attemptLock) { activeAttempt == attempt }

    /** Returns the native ownership token only while [attempt] is still current. */
    private fun connectionOwnerFor(attempt: Long): Long? =
        synchronized(attemptLock) {
            activeConnectionOwner?.takeIf { activeAttempt == attempt }
        }

    private fun connectedAttempt(): Long? =
        synchronized(attemptLock) {
            activeAttempt?.takeIf { _state.value is CameraSessionState.Connected }
        }

    private fun ownsConnectedAttempt(attempt: Long): Boolean =
        synchronized(attemptLock) {
            activeAttempt == attempt && _state.value is CameraSessionState.Connected
        }

    private fun updateAttempt(attempt: Long, state: CameraSessionState): Boolean =
        synchronized(attemptLock) {
            if (activeAttempt != attempt) return@synchronized false
            _state.value = state
            true
        }

    /**
     * Keeps a successful attempt current for its event stream, while releasing
     * a failed attempt so a new connection can begin immediately.
     */
    private fun clearCompletedConnectionAttempt(attempt: Long) {
        synchronized(attemptLock) {
            if (activeAttempt == attempt && _state.value !is CameraSessionState.Connected) {
                activeAttempt = null
                activeConnectionOwner = null
            }
        }
    }

    /** Invalidates the current attempt and returns its native teardown owner. */
    private fun invalidateAttempt(): Long? =
        synchronized(attemptLock) {
            val connectionOwner = activeConnectionOwner
            activeAttempt = null
            activeConnectionOwner = null
            _state.value = CameraSessionState.Disconnected
            connectionOwner
        }

    private suspend fun cancelAttempt(attempt: Long) {
        val connectionOwner =
            synchronized(attemptLock) {
                if (activeAttempt != attempt) return@synchronized null
                val owner = activeConnectionOwner
                activeAttempt = null
                activeConnectionOwner = null
                _state.value = CameraSessionState.Disconnected
                owner
            }
        if (connectionOwner != null) {
            stopPropertyRefresh(clearSnapshot = true)
        }
        if (connectionOwner != null && core.isAvailable) {
            withContext(NonCancellable) {
                cameraCommandMutex.withLock {
                    withContext(Dispatchers.IO) { core.disconnect(connectionOwner) }
                }
            }
        }
    }
}
