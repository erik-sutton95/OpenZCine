package com.opencapture.openzcine.frameio

import com.opencapture.opencine.frameio.FrameioCameraHop
import com.opencapture.opencine.frameio.FrameioCameraRejoinEvidence
import com.opencapture.opencine.frameio.FrameioHopAvailability
import com.opencapture.opencine.nikon.CameraSession
import com.opencapture.opencine.nikon.CameraSessionState
import com.opencapture.openzcine.pairing.PairedCamera
import com.opencapture.openzcine.pairing.PairingEnvironment
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.TimeoutCancellationException
import kotlinx.coroutines.withTimeout
import com.opencapture.opencine.nikon.SavedCameraRecord
import com.opencapture.opencine.nikon.SavedCameraTransport

/**
 * Production hop adapter over the existing Android pairing owner; the shared Frame.io owner
 * (com.opencapture.opencine.frameio) holds the lease around it.
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
    private val prepareForDisconnect: suspend () -> Unit = {},
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
            disconnectSession()
            if (activeSession.state.value !is CameraSessionState.Disconnected) return false
            environment.releaseCameraAp()
            true
        } catch (error: CancellationException) {
            throw error
        } catch (_: Exception) {
            if (activeSession.state.value is CameraSessionState.Disconnected) {
                runCatching { environment.releaseCameraAp() }
            }
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
            disconnectSession()
            environment.releaseCameraAp()
            throw error
        } catch (_: Exception) {
            return failedReconnect()
        }
    }

    private suspend fun failedReconnect(): FrameioCameraRejoinEvidence? {
        runCatching { disconnectSession() }
        environment.releaseCameraAp()
        return null
    }

    private suspend fun disconnectSession() {
        try {
            prepareForDisconnect()
        } finally {
            activeSession.disconnect()
        }
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
