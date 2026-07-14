package com.opencapture.openzcine.bridge

import com.opencapture.openzcine.core.CameraIdentity
import com.opencapture.openzcine.core.CameraSession
import com.opencapture.openzcine.core.CameraSessionState
import com.opencapture.openzcine.core.LiveFrameSource
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.withContext

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
class SwiftCoreCameraSession(
    private val host: String,
    private val phaseLogger: (String, String) -> Unit = { _, _ -> },
) : CameraSession {
    private val _state = MutableStateFlow<CameraSessionState>(CameraSessionState.Disconnected)
    override val state: StateFlow<CameraSessionState> = _state.asStateFlow()

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
        if (!SwiftCore.isAvailable) return
        if (_state.value !is CameraSessionState.Disconnected) return
        _state.value = CameraSessionState.Connecting
        SwiftCore.sessionConnect(
            host,
            object : SwiftCore.SessionListener {
                override fun onPhase(phase: String, detail: String) = phaseLogger(phase, detail)

                override fun onConnected(name: String, model: String, serialNumber: String) {
                    _state.value =
                        CameraSessionState.Connected(CameraIdentity(name, model, serialNumber))
                }

                override fun onFailed(message: String) {
                    phaseLogger("failed", message)
                    _state.value = CameraSessionState.Disconnected
                }
            },
        )
        _state.first { it !is CameraSessionState.Connecting }
    }

    /**
     * Reads one camera property (see `SwiftCore.PROP_*`), decoded by the Swift
     * core. Null until connected or when the camera rejects the read.
     */
    suspend fun readProperty(code: Int): String? =
        if (_state.value is CameraSessionState.Connected) {
            withContext(Dispatchers.IO) { SwiftCore.sessionReadProperty(code) }
        } else {
            null
        }

    override suspend fun disconnect() {
        if (SwiftCore.isAvailable) {
            withContext(Dispatchers.IO) { SwiftCore.sessionDisconnect() }
        }
        _state.value = CameraSessionState.Disconnected
    }
}
