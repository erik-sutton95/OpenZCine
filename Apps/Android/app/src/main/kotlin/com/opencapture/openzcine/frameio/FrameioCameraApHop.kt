package com.opencapture.openzcine.frameio

import com.opencapture.openzcine.core.CameraSession
import com.opencapture.openzcine.core.CameraSessionState
import com.opencapture.openzcine.pairing.PairedCamera
import com.opencapture.openzcine.pairing.PairingEnvironment
import com.opencapture.openzcine.pairing.SavedCameraRecord
import com.opencapture.openzcine.pairing.SavedCameraTransport
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.TimeoutCancellationException
import kotlinx.coroutines.withTimeout

/** Whether the current camera context can safely perform an explicit Frame.io internet hop. */
internal enum class FrameioHopAvailability {
    READY,
    NOT_CAMERA_ACCESS_POINT,
    MISSING_SAVED_PROFILE,
    FIXTURE_UNAVAILABLE,
    ;

    val operatorMessage: String
        get() =
            when (this) {
                READY -> ""
                NOT_CAMERA_ACCESS_POINT ->
                    "This camera connection doesn't own a camera access-point binding."
                MISSING_SAVED_PROFILE ->
                    "OpenZCine can't return to this camera automatically because its saved Wi-Fi profile or key is unavailable. Pair it again before using a Frame.io hop."
                FIXTURE_UNAVAILABLE ->
                    "Network hopping is unavailable for demo fixtures. Connect a configured camera access point to verify the real workflow."
            }
}

/** Session evidence captured only after a fresh camera connection succeeds. */
internal data class FrameioCameraRejoinEvidence(
    val cameraName: String,
    val cameraModel: String,
    val verifiedAtEpochMillis: Long,
)

/** Visible lifecycle of the explicit camera-AP → internet → camera-AP round trip. */
internal sealed interface FrameioInternetHopState {
    data object Idle : FrameioInternetHopState

    data object LeavingCamera : FrameioInternetHopState

    data object WaitingForInternet : FrameioInternetHopState

    data object Online : FrameioInternetHopState

    data object RejoiningCamera : FrameioInternetHopState

    data class Rejoined(val evidence: FrameioCameraRejoinEvidence) : FrameioInternetHopState

    data class Failed(val message: String) : FrameioInternetHopState
}

/** Camera lifecycle boundary held by the Frame.io controller while delivery context remains mounted. */
internal interface FrameioCameraHop {
    val availability: FrameioHopAvailability

    /** Disconnects the current session, then releases its AP binding after operator consent. */
    suspend fun leaveCameraNetwork(): Boolean

    /** Rejoins through the saved profile and returns only protocol-connected session evidence. */
    suspend fun rejoinCameraNetwork(): FrameioCameraRejoinEvidence?
}

/**
 * Production hop adapter over the existing Android pairing owner.
 *
 * It never retains or exposes the Wi-Fi passphrase. The key is read from the encrypted pairing
 * store only for the rejoin request, and the monitor receives the reconnected session only after
 * [CameraSessionState.Connected] is observed.
 */
internal class AndroidFrameioCameraApHop(
    private val activeSession: CameraSession,
    private val savedCamera: SavedCameraRecord?,
    private val environment: PairingEnvironment,
    private val fixtureSession: Boolean,
    private val onReconnected: (PairedCamera) -> Unit,
    private val clock: () -> Long = System::currentTimeMillis,
    private val rejoinTimeoutMillis: Long = DEFAULT_REJOIN_TIMEOUT_MILLIS,
) : FrameioCameraHop {
    init {
        require(rejoinTimeoutMillis > 0) { "Camera rejoin timeout must be positive." }
    }

    override val availability: FrameioHopAvailability
        get() =
            frameioHopAvailability(
                savedCamera = savedCamera,
                fixtureSession = fixtureSession,
                credentialAvailable = savedCamera?.wifiSsid?.let(environment.credentials::passphrase) != null,
            )

    override suspend fun leaveCameraNetwork(): Boolean {
        if (availability != FrameioHopAvailability.READY) return false
        return try {
            activeSession.disconnect()
            if (activeSession.state.value !is CameraSessionState.Disconnected) return false
            environment.releaseCameraAp()
            true
        } catch (error: CancellationException) {
            throw error
        } catch (_: Exception) {
            false
        }
    }

    override suspend fun rejoinCameraNetwork(): FrameioCameraRejoinEvidence? {
        val record = savedCamera ?: return null
        if (availability != FrameioHopAvailability.READY) return null
        val ssid = record.wifiSsid ?: return null
        val passphrase = environment.credentials.passphrase(ssid) ?: return null
        if (!environment.joinCameraAp(ssid, passphrase)) return null

        try {
            // Reconnect the same monitor-owned session wrapper. Replacing the object here would
            // dispose the old monitor lifecycle after the new AP lease was acquired, and that
            // cleanup would release the fresh binding from the shared PairingEnvironment.
            withTimeout(rejoinTimeoutMillis) { activeSession.connect() }
            val connected = activeSession.state.value as? CameraSessionState.Connected
                ?: return failedReconnect()
            val verifiedAt = clock()
            val updated =
                record.copy(
                    cameraName = connected.identity.name,
                    lastSeenAtEpochMillis = verifiedAt,
                )
            onReconnected(PairedCamera(activeSession, updated))
            return FrameioCameraRejoinEvidence(
                cameraName = connected.identity.name,
                cameraModel = connected.identity.model,
                verifiedAtEpochMillis = verifiedAt,
            )
        } catch (_: TimeoutCancellationException) {
            return failedReconnect()
        } catch (error: CancellationException) {
            activeSession.disconnect()
            environment.releaseCameraAp()
            throw error
        } catch (_: Exception) {
            return failedReconnect()
        }
    }

    private suspend fun failedReconnect(): FrameioCameraRejoinEvidence? {
        runCatching { activeSession.disconnect() }
        environment.releaseCameraAp()
        return null
    }

    private companion object {
        const val DEFAULT_REJOIN_TIMEOUT_MILLIS = 45_000L
    }
}

/** Pure availability policy that prevents fixture or incomplete-profile behavior from looking real. */
internal fun frameioHopAvailability(
    savedCamera: SavedCameraRecord?,
    fixtureSession: Boolean,
    credentialAvailable: Boolean,
): FrameioHopAvailability =
    when {
        fixtureSession -> FrameioHopAvailability.FIXTURE_UNAVAILABLE
        savedCamera?.transport != SavedCameraTransport.CAMERA_ACCESS_POINT ->
            FrameioHopAvailability.NOT_CAMERA_ACCESS_POINT
        savedCamera.wifiSsid.isNullOrBlank() || !credentialAvailable ->
            FrameioHopAvailability.MISSING_SAVED_PROFILE
        else -> FrameioHopAvailability.READY
    }
