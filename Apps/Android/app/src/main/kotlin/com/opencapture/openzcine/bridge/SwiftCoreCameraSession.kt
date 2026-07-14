package com.opencapture.openzcine.bridge

import com.opencapture.openzcine.core.CameraIdentity
import com.opencapture.openzcine.core.CameraRecordingException
import com.opencapture.openzcine.core.CameraRecordingState
import com.opencapture.openzcine.core.CameraSession
import com.opencapture.openzcine.core.CameraSessionState
import com.opencapture.openzcine.core.LiveFrameSource
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.withContext
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock

/** Injectable JNI seam for deterministic Android session lifecycle tests. */
internal interface SwiftCoreSessionBridge {
    val isAvailable: Boolean

    fun connect(host: String, listener: SwiftCore.SessionListener)

    fun readProperty(code: Int): String?

    fun setRecording(recording: Boolean): Int

    fun disconnect()

    data object Production : SwiftCoreSessionBridge {
        override val isAvailable: Boolean
            get() = SwiftCore.isAvailable

        override fun connect(host: String, listener: SwiftCore.SessionListener) {
            SwiftCore.sessionConnect(host, listener)
        }

        override fun readProperty(code: Int): String? = SwiftCore.sessionReadProperty(code)

        override fun setRecording(recording: Boolean): Int =
            SwiftCore.sessionSetRecording(recording)

        override fun disconnect() {
            SwiftCore.sessionDisconnect()
        }
    }
}

/**
 * Production [CameraSession] backed by the shared Swift core's PTP-IP
 * protocol/session layer over JNI: connect drives the Init handshake plus the
 * Nikon open/pair/identify sequence inside the `.so`, and property reads are
 * decoded by the core's codecs. This class is only state plumbing — no
 * protocol logic lives on the Kotlin side.
 *
 * @property host Numeric IPv4 camera address (from NSD discovery, the fixed
 *   camera-AP host, or a debug intent extra).
 * @property phaseLogger Optional sink for progress phases (name + detail),
 *   e.g. logcat in the debug probe. Called on a background thread.
 */
class SwiftCoreCameraSession internal constructor(
    private val host: String,
    private val phaseLogger: (String, String) -> Unit,
    private val core: SwiftCoreSessionBridge,
) : CameraSession {
    /** Production session binding the Kotlin shell to the shared Swift facade. */
    public constructor(
        host: String,
        phaseLogger: (String, String) -> Unit = { _, _ -> },
    ) : this(host, phaseLogger, SwiftCoreSessionBridge.Production)

    private val _state = MutableStateFlow<CameraSessionState>(CameraSessionState.Disconnected)
    override val state: StateFlow<CameraSessionState> = _state.asStateFlow()
    private val attemptLock = Any()
    private var nextAttempt = 0L
    private var activeAttempt: Long? = null

    private val _recordingState = MutableStateFlow(CameraRecordingState.STANDBY)
    override val recordingState: StateFlow<CameraRecordingState> = _recordingState.asStateFlow()

    /** Serializes record commands with disconnect so an in-flight JNI call never races teardown. */
    private val recordingCommandMutex = Mutex()

    /**
     * The iOS shell defers camera-header readback for 1.5 seconds after an app
     * record command. The Android facade does the same: some bodies publish a
     * stale live-view header for a few frames after accepting the operation.
     */
    @Volatile private var ignoreLiveRecordingStateUntilNanos: Long = 0L

    /**
     * Live-view frames from the Swift core's pump. Collect only while the
     * session is [CameraSessionState.Connected]; collection starts live view
     * on the camera and cancelling it sends `EndLiveView` (never leave the
     * body streaming to a hidden feed — the heat-audit rule).
     */
    val liveFrames: LiveFrameSource =
        SwiftCoreLiveFrameSource(onRecordingState = ::applyCameraRecordingState)

    /**
     * Connects and suspends until the session is [CameraSessionState.Connected]
     * or back at [CameraSessionState.Disconnected]. A missing native library
     * (APK built without `just android-core`) stays disconnected without
     * crashing.
     */
    override suspend fun connect() {
        if (!core.isAvailable) return
        val attempt = beginAttempt() ?: return
        try {
            core.connect(
                host,
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
                            _recordingState.value = CameraRecordingState.STANDBY
                        }
                    }

                    override fun onFailed(message: String) {
                        if (updateAttempt(attempt, CameraSessionState.Disconnected)) {
                            ignoreLiveRecordingStateUntilNanos = 0L
                            _recordingState.value = CameraRecordingState.STANDBY
                            phaseLogger("failed", message)
                        }
                    }
                },
            )
            _state.first { it !is CameraSessionState.Connecting || !isCurrentAttempt(attempt) }
            clearAttempt(attempt)
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
     * Sends the Nikon movie-record operation through Swift and updates the
     * state flow only after that command is accepted by the camera. Once a
     * command begins it runs non-cancellably: cancelling the Compose scope
     * cannot leave the shell reporting an old state after a native operation
     * already reached the body.
     */
    override suspend fun setRecording(recording: Boolean) {
        recordingCommandMutex.withLock {
            if (_state.value !is CameraSessionState.Connected) {
                throw CameraRecordingException.NotConnected
            }
            if (!core.isAvailable) {
                throw CameraRecordingException.CoreUnavailable
            }

            val target = if (recording) CameraRecordingState.RECORDING else CameraRecordingState.STANDBY
            if (_recordingState.value == target) return

            val rollback = if (recording) CameraRecordingState.STANDBY else CameraRecordingState.RECORDING
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
                nativeResult.throwIfRecordingCommandFailed()
                _recordingState.value = target
                ignoreLiveRecordingStateUntilNanos =
                    System.nanoTime() + RECORDING_READBACK_GRACE_NANOS
            } catch (error: CameraRecordingException) {
                _recordingState.value = rollback
                ignoreLiveRecordingStateUntilNanos = 0L
                throw error
            } catch (_: Throwable) {
                _recordingState.value = rollback
                ignoreLiveRecordingStateUntilNanos = 0L
                throw CameraRecordingException.TransportFailed
            }
        }
    }

    override suspend fun disconnect() {
        recordingCommandMutex.withLock {
            invalidateAttempt()
            if (core.isAvailable) {
                withContext(Dispatchers.IO + NonCancellable) { core.disconnect() }
            }
            ignoreLiveRecordingStateUntilNanos = 0L
            _recordingState.value = CameraRecordingState.STANDBY
            _state.value = CameraSessionState.Disconnected
        }
    }

    /** Applies camera-authoritative record state from a decoded live-view frame. */
    private fun applyCameraRecordingState(recording: Boolean) {
        if (_state.value !is CameraSessionState.Connected) return
        if (System.nanoTime() < ignoreLiveRecordingStateUntilNanos) return
        _recordingState.value =
            if (recording) CameraRecordingState.RECORDING else CameraRecordingState.STANDBY
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

    private companion object {
        const val RECORDING_READBACK_GRACE_NANOS: Long = 1_500_000_000L
    }

    private fun beginAttempt(): Long? =
        synchronized(attemptLock) {
            if (_state.value !is CameraSessionState.Disconnected) return@synchronized null
            nextAttempt += 1
            activeAttempt = nextAttempt
            _state.value = CameraSessionState.Connecting
            nextAttempt
        }

    private fun isCurrentAttempt(attempt: Long): Boolean =
        synchronized(attemptLock) { activeAttempt == attempt }

    private fun updateAttempt(attempt: Long, state: CameraSessionState): Boolean =
        synchronized(attemptLock) {
            if (activeAttempt != attempt) return@synchronized false
            _state.value = state
            true
        }

    private fun clearAttempt(attempt: Long) {
        synchronized(attemptLock) {
            if (activeAttempt == attempt) activeAttempt = null
        }
    }

    private fun invalidateAttempt() {
        synchronized(attemptLock) {
            activeAttempt = null
            _state.value = CameraSessionState.Disconnected
        }
    }

    private suspend fun cancelAttempt(attempt: Long) {
        val ownsAttempt =
            synchronized(attemptLock) {
                if (activeAttempt != attempt) return@synchronized false
                activeAttempt = null
                _state.value = CameraSessionState.Disconnected
                true
            }
        if (ownsAttempt && core.isAvailable) {
            withContext(NonCancellable + Dispatchers.IO) { core.disconnect() }
        }
    }
}
