package com.opencapture.openzcine.bridge

import com.opencapture.openzcine.core.CameraIdentity
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

/** Injectable JNI seam for deterministic Android session lifecycle tests. */
internal interface SwiftCoreSessionBridge {
    val isAvailable: Boolean

    fun connect(host: String, listener: SwiftCore.SessionListener)

    fun readProperty(code: Int): String?

    fun disconnect()

    data object Production : SwiftCoreSessionBridge {
        override val isAvailable: Boolean
            get() = SwiftCore.isAvailable

        override fun connect(host: String, listener: SwiftCore.SessionListener) {
            SwiftCore.sessionConnect(host, listener)
        }

        override fun readProperty(code: Int): String? = SwiftCore.sessionReadProperty(code)

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

    /**
     * Live-view frames from the Swift core's pump. Collect only while the
     * session is [CameraSessionState.Connected]; collection starts live view
     * on the camera and cancelling it sends `EndLiveView` (never leave the
     * body streaming to a hidden feed — the heat-audit rule).
     */
    val liveFrames: LiveFrameSource = SwiftCoreLiveFrameSource()

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
                        updateAttempt(
                            attempt,
                            CameraSessionState.Connected(CameraIdentity(name, model, serialNumber)),
                        )
                    }

                    override fun onFailed(message: String) {
                        if (updateAttempt(attempt, CameraSessionState.Disconnected)) {
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

    override suspend fun disconnect() {
        invalidateAttempt()
        if (core.isAvailable) {
            withContext(Dispatchers.IO) { core.disconnect() }
        }
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
