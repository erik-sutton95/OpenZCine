package com.opencapture.openzcine.bridge

import com.opencapture.openzcine.core.CameraControl
import com.opencapture.openzcine.core.CameraControlException
import com.opencapture.openzcine.core.CameraConnectionPhase
import com.opencapture.openzcine.core.CameraConnectionProgress
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

private val legacyPtpIpInitiatorGuid: ByteArray = "OpenZCineAndroid".encodeToByteArray()

/**
 * The Nikon connection sequence selected by the Android startup flow.
 *
 * An unknown Wi-Fi camera must use [FIRST_TIME_PAIRING] directly. A saved
 * profile may use [SAVED_PROFILE]; [RESTORE_PROFILE_THEN_PAIRING] is reserved
 * for USB-C, where an app-control probe cannot disturb a Wi-Fi pairing wizard.
 */
public enum class PtpIpConnectionStrategy(internal val nativeValue: Int) {
    /** Reopen a camera-side profile that already knows this Android install. */
    SAVED_PROFILE(0),

    /** Create a Nikon profile without an app-control preflight probe. */
    FIRST_TIME_PAIRING(1),

    /** Restore a profile first, then pair only when it was specifically rejected. */
    RESTORE_PROFILE_THEN_PAIRING(2),
}

/** Injectable JNI seam for deterministic Android session lifecycle tests. */
internal interface SwiftCoreSessionBridge {
    val isAvailable: Boolean

    fun connect(host: String, connectionOwner: Long, listener: SwiftCore.SessionListener)

    /** Starts PTP-IP with an explicit core-owned pairing strategy and initiator GUID. */
    fun connect(
        host: String,
        connectionOwner: Long,
        connectionStrategy: PtpIpConnectionStrategy,
        initiatorGuid: ByteArray,
        listener: SwiftCore.SessionListener,
    ) {
        connect(host, connectionOwner, listener)
    }

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

    /** Starts USB PTP using the same strategy vocabulary as Wi-Fi PTP-IP. */
    fun connectUsb(
        transport: UsbPtpTransport,
        host: String,
        cameraNameHint: String,
        connectionOwner: Long,
        connectionStrategy: PtpIpConnectionStrategy,
        listener: SwiftCore.SessionListener,
    ) {
        connectUsb(transport, host, cameraNameHint, connectionOwner, listener)
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
            connect(
                host = host,
                connectionOwner = connectionOwner,
                connectionStrategy = PtpIpConnectionStrategy.RESTORE_PROFILE_THEN_PAIRING,
                initiatorGuid = legacyPtpIpInitiatorGuid,
                listener = listener,
            )
        }

        override fun connect(
            host: String,
            connectionOwner: Long,
            connectionStrategy: PtpIpConnectionStrategy,
            initiatorGuid: ByteArray,
            listener: SwiftCore.SessionListener,
        ) {
            SwiftCore.sessionConnect(
                host,
                connectionOwner,
                connectionStrategy.nativeValue,
                initiatorGuid,
                listener,
            )
        }

        override fun connectUsb(
            transport: UsbPtpTransport,
            host: String,
            cameraNameHint: String,
            connectionOwner: Long,
            listener: SwiftCore.SessionListener,
        ) {
            connectUsb(
                transport = transport,
                host = host,
                cameraNameHint = cameraNameHint,
                connectionOwner = connectionOwner,
                connectionStrategy = PtpIpConnectionStrategy.RESTORE_PROFILE_THEN_PAIRING,
                listener = listener,
            )
        }

        override fun connectUsb(
            transport: UsbPtpTransport,
            host: String,
            cameraNameHint: String,
            connectionOwner: Long,
            connectionStrategy: PtpIpConnectionStrategy,
            listener: SwiftCore.SessionListener,
        ) {
            SwiftCore.sessionConnectUsb(
                transport,
                host,
                cameraNameHint,
                connectionOwner,
                connectionStrategy.nativeValue,
                listener,
            )
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
            CameraControl.ISO_AUTO -> 21
            CameraControl.STILL_ISO -> 22
            CameraControl.STILL_ISO_AUTO -> 23
            CameraControl.STILL_SHUTTER -> 24
            CameraControl.STILL_IRIS -> 25
            CameraControl.STILL_DRIVE -> 26
            CameraControl.STILL_FOCUS_MODE -> 27
            CameraControl.STILL_FOCUS_AREA -> 28
            CameraControl.STILL_FOCUS_SUBJECT -> 29
            CameraControl.STILL_METER -> 30
            CameraControl.STILL_IMAGE_AREA -> 31
            CameraControl.STILL_IMAGE_SIZE -> 32
            CameraControl.STILL_QUALITY -> 33
            CameraControl.STILL_RAW_COMPRESSION -> 34
            CameraControl.STILL_USER_MODE_PROGRAM -> 35
            CameraControl.STILL_PICTURE_CONTROL -> 36
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
    private val evIndicatorPollIntervalMillis: Long = EV_INDICATOR_POLL_INTERVAL_MILLIS,
    private val propertyEventDebounceMillis: Long = PROPERTY_EVENT_DEBOUNCE_MILLIS,
    private val automaticallyRefreshProperties: Boolean = true,
    private val usbTransport: UsbPtpTransport? = null,
    private val cameraNameHint: String? = null,
    private val connectionStrategy: PtpIpConnectionStrategy =
        PtpIpConnectionStrategy.RESTORE_PROFILE_THEN_PAIRING,
    initiatorGuid: ByteArray = legacyPtpIpInitiatorGuid,
) : CameraSession {
    private val initiatorGuid: ByteArray = initiatorGuid.copyOf()

    init {
        require(initiatorGuid.size == INITIATOR_GUID_BYTE_COUNT) {
            "A PTP-IP initiator GUID must contain exactly $INITIATOR_GUID_BYTE_COUNT bytes."
        }
    }

    /** Production session binding the Kotlin shell to the shared Swift facade. */
    public constructor(
        host: String,
        phaseLogger: (String, String) -> Unit = { _, _ -> },
    ) : this(host, phaseLogger, SwiftCoreSessionBridge.Production)

    /** Production Wi-Fi session with an explicit Android pairing strategy and initiator GUID. */
    public constructor(
        host: String,
        connectionStrategy: PtpIpConnectionStrategy,
        initiatorGuid: ByteArray,
        phaseLogger: (String, String) -> Unit = { _, _ -> },
    ) : this(
        host = host,
        phaseLogger = phaseLogger,
        core = SwiftCoreSessionBridge.Production,
        connectionStrategy = connectionStrategy,
        initiatorGuid = initiatorGuid,
    )

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

    /** Production USB-C session with an explicit profile-restoration strategy. */
    public constructor(
        host: String,
        cameraNameHint: String,
        usbTransport: UsbPtpTransport,
        connectionStrategy: PtpIpConnectionStrategy,
        phaseLogger: (String, String) -> Unit = { _, _ -> },
    ) : this(
        host = host,
        phaseLogger = phaseLogger,
        core = SwiftCoreSessionBridge.Production,
        usbTransport = usbTransport,
        cameraNameHint = cameraNameHint,
        connectionStrategy = connectionStrategy,
    )

    private val _state = MutableStateFlow<CameraSessionState>(CameraSessionState.Disconnected)
    override val state: StateFlow<CameraSessionState> = _state.asStateFlow()

    private val _connectionProgress = MutableStateFlow(CameraConnectionProgress())
    override val connectionProgress: StateFlow<CameraConnectionProgress> =
        _connectionProgress.asStateFlow()

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

    private val _initialMonitorPropertiesReady = MutableStateFlow(false)
    override val initialMonitorPropertiesReady: StateFlow<Boolean> =
        _initialMonitorPropertiesReady.asStateFlow()

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
    /** Throttles LV hot-path RTT publishes (see [updateRoundTripMeasurement]). */
    @Volatile private var lastRoundTripPublishNanos: Long = 0L

    /** Incremented only by authoritative camera record events. */
    @Volatile private var cameraRecordingEventVersion: Long = 0L

    /** True while the monitor's EV meter tool wants fast needle reads. */
    @Volatile private var evIndicatorFastPolling = false

    override fun setExposureIndicatorFastPolling(active: Boolean) {
        evIndicatorFastPolling = active
    }

    /**
     * Live-view frames from the Swift core's pump. Collect only while the
     * session is [CameraSessionState.Connected]; collection starts live view
     * on the camera and cancelling it sends `EndLiveView` (never leave the
     * body streaming to a hidden feed — the heat-audit rule).
     */
    val liveFrames: LiveFrameSource =
        SwiftCoreLiveFrameSource(
            onRecordingState = ::applyCameraRecordingState,
            onCommandRoundTrip = { updateRoundTripMeasurement() },
            onStreamExhausted = ::markLiveViewStreamExhausted,
            onFailurePhase = { phase -> phaseLogger(phase, "") },
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
                        if (isCurrentAttempt(attempt)) {
                            publishNativeConnectionPhase(phase, detail)
                        }
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
                            _connectionProgress.value =
                                CameraConnectionProgress(CameraConnectionPhase.CONNECTED, name)
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
                            _connectionProgress.value =
                                CameraConnectionProgress(CameraConnectionPhase.FAILED, message)
                            // Closed failure token only — free-form [message] never enters
                            // the diagnostic event store (mapped by AndroidDiagnosticEvent.fromPhase).
                            phaseLogger(sessionFailurePhaseToken(), message)
                        }
                    }
            }
            if (usbTransport == null) {
                core.connect(host, connectionOwner, connectionStrategy, initiatorGuid, listener)
            } else {
                core.connectUsb(
                    transport = usbTransport,
                    host = host,
                    cameraNameHint = cameraNameHint.orEmpty(),
                    connectionOwner = connectionOwner,
                    connectionStrategy = connectionStrategy,
                    listener = listener,
                )
            }
            _state.first { it !is CameraSessionState.Connecting || !isCurrentAttempt(attempt) }
            clearCompletedConnectionAttempt(attempt)
        } catch (error: CancellationException) {
            cancelAttempt(attempt)
            throw error
        } catch (error: Exception) {
            val message = error.message ?: "Camera connection failed."
            _connectionProgress.value = CameraConnectionProgress(CameraConnectionPhase.FAILED, message)
            phaseLogger(sessionFailurePhaseToken(), message)
            cancelAttempt(attempt)
        }
    }

    /** Closed phase token distinguishing USB PTP vs Wi‑Fi PTP-IP session failures. */
    private fun sessionFailurePhaseToken(): String =
        if (usbTransport != null) "failed.usb" else "failed.ptp"

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
                updateRoundTripMeasurement(force = true)
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
                updateRoundTripMeasurement(force = true)
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
                updateRoundTripMeasurement(force = true)
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
                updateRoundTripMeasurement(force = true)
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
                    _connectionProgress.value = CameraConnectionProgress()
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
                        if (message == null) return
                        if (usbTransport == null) {
                            reportEventChannelDegraded(attempt, message)
                        } else {
                            markTerminalEventChannelEnded(attempt, message)
                        }
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
     * Records a PTP-IP event-channel loss without dropping a still-healthy
     * command or live-view socket. PTP-IP owns those sockets independently,
     * matching the iOS session behavior; a later command or frame failure
     * remains responsible for recovery.
     */
    private fun reportEventChannelDegraded(attempt: Long, message: String) {
        if (isCurrentAttempt(attempt)) phaseLogger("eventChannelEnded", message)
    }

    /**
     * Live-view pump exhausted its restart budget (iOS stall escalate). Tear
     * down the active attempt so [MonitorSessionRecovery] can full-reconnect
     * instead of spinning a Connected session with a dead feed forever.
     */
    private fun markLiveViewStreamExhausted() {
        val attempt =
            synchronized(attemptLock) {
                if (_state.value !is CameraSessionState.Connected) return
                activeAttempt
            } ?: return
        markTerminalEventChannelEnded(
            attempt,
            "Live view stopped after repeated pump failures.",
        )
    }

    /**
     * Tears down a USB session after an interrupt-endpoint failure. USB events
     * share the claimed transport with commands, so this is terminal unlike a
     * PTP-IP event-socket failure.
     */
    private fun markTerminalEventChannelEnded(attempt: Long, message: String) {
        val connectionOwner =
            synchronized(attemptLock) {
                if (activeAttempt != attempt) return@synchronized null
                activeAttempt = null
                val owner = activeConnectionOwner
                activeConnectionOwner = null
                // Keep monitor recovery paused until teardown releases the
                // claimed USB transport. A reconnect before that point can
                // contend for the body while its previous PTP slot is live.
                _state.value = CameraSessionState.Connecting
                owner
            }
        if (connectionOwner == null) return
        ignoreLiveRecordingStateUntilNanos = 0L
        cameraRecordingEventVersion = 0L
        _recordingState.value = CameraRecordingState.STANDBY
        stopPropertyRefresh(clearSnapshot = true)
        _connectionProgress.value = CameraConnectionProgress(CameraConnectionPhase.FAILED, message)
        phaseLogger("eventChannelEnded", message)
        propertyRefreshScope.launch {
            try {
                // The native event reader marks itself inactive before this
                // callback, so this owned teardown cannot wait for its own
                // reader thread. Match normal disconnect ownership: wait for
                // any in-flight command, use IO for JNI, and only then allow
                // monitor recovery to begin another USB attempt.
                withContext(NonCancellable) {
                    cameraCommandMutex.withLock {
                        if (core.isAvailable) {
                            withContext(propertyRefreshDispatcher) {
                                core.disconnect(connectionOwner)
                            }
                        }
                    }
                }
            } catch (error: Throwable) {
                phaseLogger(
                    "eventChannelCleanupFailed",
                    error.message ?: "Camera event-channel cleanup failed.",
                )
            } finally {
                synchronized(attemptLock) {
                    if (activeAttempt == null && _state.value is CameraSessionState.Connecting) {
                        _state.value = CameraSessionState.Disconnected
                    }
                }
            }
        }
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

    /** Starts one full property burst, then conservative round-robin reads. */
    private fun startPropertyRefresh(attempt: Long) {
        stopPropertyRefresh(clearSnapshot = false)
        _initialMonitorPropertiesReady.value = false
        _propertyRefreshStatus.value = CameraPropertyRefreshStatus.Refreshing
        val job =
            propertyRefreshScope.launch {
                // Full live-order burst (no 1.5 s gaps). The monitor holds live
                // view until [initialMonitorPropertiesReady] so this owns the
                // command channel without competing with GetLiveViewImageEx.
                try {
                    refreshCameraProperties(
                        attempt = attempt,
                        request = SwiftCore.PROPERTY_REFRESH_BOOTSTRAP,
                        propertyCode = 0L,
                    )
                } finally {
                    // Always open the feed — even a degraded/partial bootstrap
                    // is better than an infinite loader.
                    if (ownsConnectedAttempt(attempt)) {
                        _initialMonitorPropertiesReady.value = true
                    }
                }
                var fastTick = 0
                while (isActive && ownsConnectedAttempt(attempt)) {
                    // While the EV meter tool is visible (and not recording),
                    // the needle reads at its own fast cadence between the
                    // regular ticks — one full-cycle visit lags the meter by
                    // minutes. Every [EV_TICKS_PER_PROPERTY_POLL]th fast tick
                    // still runs the normal round-robin so nothing starves.
                    val evFast =
                        evIndicatorFastPolling &&
                            _recordingState.value != CameraRecordingState.RECORDING
                    if (evFast) {
                        delay(evIndicatorPollIntervalMillis.coerceAtLeast(1L))
                        if (!isActive || !ownsConnectedAttempt(attempt)) break
                        refreshCameraProperties(
                            attempt = attempt,
                            request = SwiftCore.PROPERTY_REFRESH_EV_INDICATOR,
                            propertyCode = 0L,
                        )
                        fastTick += 1
                        if (fastTick % EV_TICKS_PER_PROPERTY_POLL != 0) continue
                    } else {
                        delay(propertyPollIntervalMillis.coerceAtLeast(1L))
                    }
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
        _initialMonitorPropertiesReady.value = false
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
            // Only bootstrap (and degraded recoveries) surface "Refreshing" in
            // the shell. Steady-state NEXT polls used to flip Refreshing→Ready
            // every interval and recompose monitor chrome on top of the feed hitch.
            val isBootstrap = request == SwiftCore.PROPERTY_REFRESH_BOOTSTRAP
            if (isBootstrap) {
                _propertyRefreshStatus.value = CameraPropertyRefreshStatus.Refreshing
            }
            cameraCommandMutex.withLock {
                if (!ownsConnectedAttempt(attempt)) return
                val readback = readNativePropertySnapshot(request, propertyCode)
                updateRoundTripMeasurement()
                if (!ownsConnectedAttempt(attempt)) return
                if (
                    readback.isValid &&
                        readback.result != NativePropertyRefreshResult.NO_SESSION
                ) {
                    // Avoid rewriting an equal snapshot — property StateFlow
                    // collectors recompose the whole property bar otherwise.
                    val next = readback.snapshot
                    if (next != _cameraProperties.value) {
                        _cameraProperties.value = next
                    }
                }
                val nextStatus = readback.result.toRefreshStatus()
                if (
                    isBootstrap ||
                        nextStatus !is CameraPropertyRefreshStatus.Ready ||
                        _propertyRefreshStatus.value !is CameraPropertyRefreshStatus.Ready
                ) {
                    _propertyRefreshStatus.value = nextStatus
                }
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

    /**
     * Publishes the latest native command RTT into [latestCommandRoundTripMilliseconds].
     *
     * Live-view calls this every frame, so the default path is rate-limited to
     * avoid JNI + StateFlow churn. Explicit control / recording / focus commands
     * pass [force] so the operator-facing sample is never dropped behind a recent
     * frame sample (or the post-connect seed).
     */
    private fun updateRoundTripMeasurement(force: Boolean = false) {
        if (_state.value !is CameraSessionState.Connected) {
            _latestCommandRoundTripMilliseconds.value = null
            lastRoundTripPublishNanos = 0L
            return
        }
        val now = System.nanoTime()
        if (
            !force &&
                lastRoundTripPublishNanos != 0L &&
                now - lastRoundTripPublishNanos < ROUND_TRIP_PUBLISH_INTERVAL_NANOS
        ) {
            return
        }
        lastRoundTripPublishNanos = now
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
        /**
         * Steady-state property poll gap. Live view and property reads share
         * one PTP `transactionLock`; 1.5 s left a visible hitch every ~30–45
         * frames. 3 s keeps battery/ISO fresh enough without punching the feed.
         */
        const val PROPERTY_POLL_INTERVAL_MILLIS: Long = 3_000L
        /**
         * Fast EV-needle gap while the meter tool is visible. A single-byte
         * indicator read is the cheapest possible transaction, but it still
         * shares the live-view `transactionLock` — keep it well below the
         * feed's hitch-visibility threshold.
         */
        const val EV_INDICATOR_POLL_INTERVAL_MILLIS: Long = 750L
        /** Fast EV ticks per regular round-robin property poll (750 ms × 4 = 3 s). */
        const val EV_TICKS_PER_PROPERTY_POLL: Int = 4
        const val PROPERTY_EVENT_DEBOUNCE_MILLIS: Long = 250L
        /** Max rate for command RTT StateFlow updates (LV frames fire every present). */
        const val ROUND_TRIP_PUBLISH_INTERVAL_NANOS: Long = 250_000_000L
        const val MAX_EVENT_PROPERTY_REFRESHES: Int = 4
        const val EVENT_BUFFER_CAPACITY: Int = 64
        const val EVENT_CODE_MASK: Int = 0xFFFF
        const val UINT32_MASK: Long = 0xFFFF_FFFFL
        const val DEVICE_PROPERTY_CHANGED: Int = 0x4006
        const val MOVIE_RECORD_INTERRUPTED: Int = 0xC105
        const val MOVIE_RECORD_COMPLETE: Int = 0xC108
        const val MOVIE_RECORD_STARTED: Int = 0xC10A
        const val INITIATOR_GUID_BYTE_COUNT: Int = 16
    }

    private fun beginAttempt(): Long? {
        val attempt =
            synchronized(attemptLock) {
                if (_state.value !is CameraSessionState.Disconnected) return@synchronized null
                nextAttempt += 1
                activeAttempt = nextAttempt
                activeConnectionOwner = nextConnectionOwner.incrementAndGet()
                _state.value = CameraSessionState.Connecting
                _connectionProgress.value =
                    CameraConnectionProgress(CameraConnectionPhase.HANDSHAKING)
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
            _connectionProgress.value = CameraConnectionProgress()
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
                _connectionProgress.value = CameraConnectionProgress()
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

    /** Publishes only stable facade phase names across the Kotlin/Swift boundary. */
    private fun publishNativeConnectionPhase(phase: String, detail: String) {
        val mapped =
            when (phase) {
                "handshaking" -> CameraConnectionPhase.HANDSHAKING
                "pairing" -> CameraConnectionPhase.PAIRING
                "confirmOnCamera" -> CameraConnectionPhase.CONFIRM_ON_CAMERA
                "connected" -> CameraConnectionPhase.CONNECTED
                "failed" -> CameraConnectionPhase.FAILED
                else -> null
            }
        if (mapped != null) {
            _connectionProgress.value = CameraConnectionProgress(mapped, detail)
        }
        phaseLogger(phase, detail)
    }
}
