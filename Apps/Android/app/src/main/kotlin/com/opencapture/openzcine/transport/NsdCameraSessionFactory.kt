package com.opencapture.openzcine.transport

import com.opencapture.openzcine.core.CameraIdentity
import com.opencapture.openzcine.core.CameraRecordingException
import com.opencapture.openzcine.core.CameraRecordingState
import com.opencapture.openzcine.core.CameraSession
import com.opencapture.openzcine.core.CameraSessionState
import java.io.IOException
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.withTimeoutOrNull

/**
 * Sketch of the production seam wiring: NSD discovery plus the socket
 * transport behind the core-api [CameraSession].
 *
 * This proves the byte path only — browse, pick a camera (falling back to the
 * fixed camera-AP host when mDNS finds nothing), open the command socket. The
 * PTP-IP Init handshake, session open, and real [CameraIdentity] arrive with
 * the Swift-core JNI facade, which replaces [TransportCameraSession]'s
 * "connected" claim with a protocol-verified one.
 */
class NsdCameraSessionFactory(
    private val browser: NsdBrowser,
    private val discoveryWindowMillis: Long = 5_000,
) {
    /** Builds a transport-backed [CameraSession]. */
    fun create(): CameraSession =
        TransportCameraSession(CameraDiscovery(browser), discoveryWindowMillis)
}

internal class TransportCameraSession(
    private val discovery: CameraDiscovery,
    private val discoveryWindowMillis: Long,
) : CameraSession {
    private val mutableState =
        MutableStateFlow<CameraSessionState>(CameraSessionState.Disconnected)

    override val state: StateFlow<CameraSessionState> = mutableState.asStateFlow()

    private val mutableRecordingState = MutableStateFlow(CameraRecordingState.STANDBY)
    override val recordingState: StateFlow<CameraRecordingState> =
        mutableRecordingState.asStateFlow()

    private var transport: PtpIpSocketTransport? = null

    override suspend fun connect() {
        mutableState.value = CameraSessionState.Connecting
        val camera =
            withTimeoutOrNull(discoveryWindowMillis) {
                discovery.cameras().first { it.isNotEmpty() }.first()
            } ?: CameraDiscovery.accessPointCamera()

        val candidate = PtpIpSocketTransport(camera.host, camera.port)
        try {
            candidate.connect()
        } catch (_: IOException) {
            mutableState.value = CameraSessionState.Disconnected
            return
        }
        transport = candidate
        // ponytail: identity from the mDNS name only — model/serial come from
        // the protocol layer once the JNI facade lands.
        mutableState.value =
            CameraSessionState.Connected(
                CameraIdentity(name = camera.name, model = camera.name, serialNumber = "")
            )
    }

    override suspend fun setRecording(recording: Boolean) {
        // This raw-socket probe never opened a protocol session, so it must
        // not pretend a local toggle controls a camera.
        throw CameraRecordingException.Unsupported
    }

    override suspend fun disconnect() {
        transport?.disconnect()
        transport = null
        mutableState.value = CameraSessionState.Disconnected
        mutableRecordingState.value = CameraRecordingState.STANDBY
    }
}
