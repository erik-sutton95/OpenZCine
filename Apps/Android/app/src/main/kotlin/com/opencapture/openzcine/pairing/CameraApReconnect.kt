package com.opencapture.openzcine.pairing

import com.opencapture.opencine.nikon.CameraConnectionPhase
import com.opencapture.opencine.nikon.CameraSession
import com.opencapture.opencine.nikon.CameraSessionState
import com.opencapture.opencine.nikon.NikonHosts
import com.opencapture.opencine.nikon.SavedCameraRecord
import com.opencapture.opencine.nikon.SavedCameraRecords
import com.opencapture.opencine.nikon.SavedCameraTransport
import com.opencapture.opencine.nikon.UsbPtpOpenResult
import com.opencapture.openzcine.transport.CameraDiscovery
import com.opencapture.openzcine.transport.DiscoveredCamera
import com.opencapture.openzcine.transport.UsbPtpCamera
import com.opencapture.openzcine.transport.UsbPtpCameraAccess
import java.net.InetSocketAddress
import java.net.Socket
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineStart
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.async
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.delay
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import kotlinx.coroutines.selects.select
import kotlinx.coroutines.withContext
import kotlinx.coroutines.withTimeoutOrNull

/**
 * Post-Confirm camera-AP readiness helpers.
 *
 * After the operator taps Confirm on the body, Nikon reboots the camera AP.
 * The working "My cameras" path always does a **full** Wi‑Fi rejoin then
 * restore-profile-then-pair. Post-first-pair reconnect must do the same —
 * trusting a pre-reboot process bind is what left the UI on Connecting until
 * timeout on Samsung flagships.
 */

/** How often to poke the camera's PTP-IP port while waiting for body Confirm. */
internal const val CAMERA_AP_PTP_PROBE_INTERVAL_MILLIS: Long = 400L

/** Per-attempt TCP connect timeout for the readiness probe. */
internal const val CAMERA_AP_PTP_PROBE_TIMEOUT_MILLIS: Int = 600

/**
 * True when [host]:[port] accepts a TCP connection within [timeoutMillis].
 * Never throws — failures mean "not ready yet".
 */
internal fun probePtpIpReachable(
    host: String,
    port: Int = CameraDiscovery.PTP_IP_PORT,
    timeoutMillis: Int = CAMERA_AP_PTP_PROBE_TIMEOUT_MILLIS,
): Boolean =
    try {
        Socket().use { socket ->
            socket.connect(InetSocketAddress(host, port), timeoutMillis)
            true
        }
    } catch (_: Exception) {
        false
    }

/**
 * Suspend until the camera AP looks ready after body Confirm (best-effort).
 *
 * Races reassociation callbacks with TCP probes. Returns when either succeeds
 * or [timeoutMillis] elapses — callers should still force a clean rejoin
 * afterward (My-cameras parity).
 */
internal suspend fun awaitCameraApReadyAfterConfirm(
    awaitReassociation: suspend (timeoutMillis: Long) -> Boolean,
    isProcessBound: () -> Boolean,
    /** Learned dialable host to probe; null skips TCP probes (no fixed AP IP). */
    host: String? = null,
    timeoutMillis: Long = FIRST_PAIR_CAMERA_AP_RESTART_TIMEOUT_MILLIS,
): Boolean =
    coroutineScope {
        val deadline = System.nanoTime() + timeoutMillis * 1_000_000L
        val reassociation =
            async(Dispatchers.IO) {
                awaitReassociation(timeoutMillis)
            }
        val probeHost = host?.takeIf { NikonHosts.isDialableHost(it) }
        val probe =
            async(Dispatchers.IO) {
                if (probeHost == null) return@async false
                // Only treat a probe as success when we still own a process bind,
                // otherwise a phantom route can exit the wait early.
                while (isActive && System.nanoTime() < deadline) {
                    if (isProcessBound() && probePtpIpReachable(probeHost)) return@async true
                    delay(CAMERA_AP_PTP_PROBE_INTERVAL_MILLIS)
                }
                false
            }
        try {
            select {
                reassociation.onAwait { ok ->
                    if (ok) {
                        probe.cancel()
                        // Only settle against an address we actually have. With no learned AP
                        // host there is nothing to dial — reassociation is the whole signal.
                        probeHost?.let { awaitPtpPortBriefly(it, maxWaitMillis = 2_000L) }
                        true
                    } else {
                        probe.await()
                    }
                }
                probe.onAwait { ok ->
                    if (ok) {
                        reassociation.cancel()
                        true
                    } else {
                        reassociation.await()
                    }
                }
            }
        } catch (error: CancellationException) {
            reassociation.cancel()
            probe.cancel()
            throw error
        } finally {
            reassociation.cancel()
            probe.cancel()
        }
    }

/** Polls PTP for a short window; always returns after [maxWaitMillis]. */
private suspend fun awaitPtpPortBriefly(host: String, maxWaitMillis: Long = 2_500L) {
    withTimeoutOrNull(maxWaitMillis) {
        while (true) {
            if (withContext(Dispatchers.IO) { probePtpIpReachable(host) }) return@withTimeoutOrNull
            delay(CAMERA_AP_PTP_PROBE_INTERVAL_MILLIS)
        }
    }
}

/**
 * Post-Confirm reconnect loop — My-cameras shape:
 * 1. Force-join the camera AP (release + specifier) at least once
 * 2. Settle
 * 3. Restore-profile-then-pair connect with short retries
 * 4. Force rejoin again after repeated Init failures
 */
internal suspend fun reconnectCameraApAfterConfirm(
    rejoinSsid: String?,
    rejoinKey: String?,
    isProcessBound: () -> Boolean,
    ensureJoined: suspend (ssid: String, passphrase: String?, timeoutMillis: Int) -> Boolean,
    forceJoin: suspend (ssid: String, passphrase: String?, timeoutMillis: Int) -> Boolean,
    connectSavedProfile: suspend () -> Boolean,
    onPhaseReconnecting: () -> Unit,
    alwaysForceJoinFirst: Boolean = true,
    timeoutMillis: Long = FIRST_PAIR_RECONNECT_TIMEOUT_MILLIS,
): Boolean =
    withTimeoutOrNull(timeoutMillis) {
        var consecutiveInitFailures = 0
        var didInitialForceJoin = false
        while (true) {
            onPhaseReconnecting()
            if (rejoinSsid != null) {
                val force =
                    alwaysForceJoinFirst && !didInitialForceJoin ||
                        consecutiveInitFailures >= 2 ||
                        !isProcessBound()
                if (force) {
                    val joined =
                        forceJoin(
                            rejoinSsid,
                            rejoinKey,
                            if (didInitialForceJoin) {
                                FIRST_PAIR_REJOIN_TIMEOUT_MILLIS * 2
                            } else {
                                // First rejoin after AP reboot — give Samsung time to show
                                // the (often silent) re-association.
                                20_000
                            },
                        )
                    didInitialForceJoin = true
                    if (!joined) {
                        consecutiveInitFailures = 0
                        delay(FIRST_PAIR_RECONNECT_INTERVAL_MILLIS)
                        continue
                    }
                    consecutiveInitFailures = 0
                    // Same settle as the working My-cameras camera-AP path.
                    delay(CAMERA_AP_POST_JOIN_SETTLE_MILLIS)
                } else if (!isProcessBound()) {
                    if (!ensureJoined(rejoinSsid, rejoinKey, FIRST_PAIR_REJOIN_TIMEOUT_MILLIS)) {
                        delay(FIRST_PAIR_RECONNECT_INTERVAL_MILLIS)
                        continue
                    }
                    delay(CAMERA_AP_POST_JOIN_SETTLE_MILLIS)
                }
            }
            val ok = connectSavedProfile()
            if (ok) return@withTimeoutOrNull true
            consecutiveInitFailures += 1
            delay(
                if (isProcessBound() && consecutiveInitFailures < 2) {
                    FIRST_PAIR_BOUND_RETRY_INTERVAL_MILLIS
                } else {
                    FIRST_PAIR_RECONNECT_INTERVAL_MILLIS
                },
            )
        }
        @Suppress("UNREACHABLE_CODE")
        false
    } == true

/** The live discovery [record] names (same address, or the same camera name); never for a cable. */
internal fun List<DiscoveredCamera>.discoveryFor(record: SavedCameraRecord): DiscoveredCamera? =
    if (record.transport == SavedCameraTransport.USB_C) {
        null
    } else {
        firstOrNull { camera ->
            camera.host == record.host || SavedCameraRecords.cameraNamesMatch(camera.name, record.cameraName)
        }
    }

/**
 * The address [record] may dial right now, or null when nothing is dialable yet: a camera-AP
 * record holding the pending key must rediscover on the live link after join, never hand the key
 * itself to the transport (#327).
 */
internal fun List<DiscoveredCamera>.dialableHostFor(record: SavedCameraRecord): String? =
    if (record.transport == SavedCameraTransport.USB_C) {
        record.host
    } else {
        CameraDiscovery.dialableSavedHost(record.host, discoveryFor(record)?.host)
    }

/**
 * The one reconnect after the body's pairing Confirm (A4-42): the wizard's first pair and a saved
 * setup's re-pair both run it, so the two can never drift. The caller already shows "Confirm on
 * the camera"; this waits for the body (a camera AP restarts its network), then dials
 * restore-then-pair, never strict saved profile: right after Confirm the camera often still
 * rejects a pure saved-profile app-control for a few seconds, and restore-then-pair recovers
 * without a second Confirm once the profile is trusted. A camera-AP setup force-rejoins its stored
 * network first ([reconnectCameraApAfterConfirm]); any other setup redials until
 * [FIRST_PAIR_RECONNECT_TIMEOUT_MILLIS]. A null host or a missing cable is "no session yet", so the
 * loop keeps waiting instead of dialling a non-address.
 */
internal suspend fun reconnectAfterBodyConfirm(
    environment: PairingEnvironment,
    record: SavedCameraRecord,
    discovered: () -> List<DiscoveredCamera>,
    usbCameras: () -> List<UsbPtpCamera>,
    onReconnecting: () -> Unit,
): PairedCamera? {
    val isCameraAp = record.transport == SavedCameraTransport.CAMERA_ACCESS_POINT
    if (isCameraAp) {
        // Success is optional: the forced rejoin below always runs, as for a saved setup.
        awaitCameraApReadyAfterConfirm(
            awaitReassociation = environment.awaitCameraApRestart,
            isProcessBound = environment.isCameraApProcessBound,
        )
    } else {
        delay(FIRST_PAIR_HOTSPOT_SETTLE_MILLIS)
    }
    suspend fun attempt(): PairedCamera? {
        val host = discovered().dialableHostFor(record) ?: return null
        val session = postConfirmSession(environment, record, host, usbCameras()) ?: return null
        return connectedWithoutConfirm(session, record.copy(host = host))
    }
    if (!isCameraAp) {
        return withTimeoutOrNull(FIRST_PAIR_RECONNECT_TIMEOUT_MILLIS) {
            while (true) {
                onReconnecting()
                attempt()?.let { return@withTimeoutOrNull it }
                delay(FIRST_PAIR_RECONNECT_INTERVAL_MILLIS)
            }
            @Suppress("UNREACHABLE_CODE")
            null
        }
    }
    val rejoinSsid = record.wifiSsid?.takeIf { it.isNotBlank() }
    var paired: PairedCamera? = null
    val ok =
        reconnectCameraApAfterConfirm(
            rejoinSsid = rejoinSsid,
            rejoinKey = rejoinSsid?.let(environment.credentials::passphrase),
            isProcessBound = environment.isCameraApProcessBound,
            // The AP rebooted: trusting a pre-reboot process bind is what left Connecting hung on
            // Samsung, so the first pass always rejoins.
            alwaysForceJoinFirst = true,
            ensureJoined = environment.ensureCameraApJoined,
            forceJoin = { ssid, key, timeout ->
                environment.releaseCameraAp()
                environment.ensureCameraApJoined(ssid, key, timeout)
            },
            connectSavedProfile = { attempt().also { paired = it } != null },
            onPhaseReconnecting = onReconnecting,
        )
    return paired.takeIf { ok }
}

/** A wireless setup dials [host]; a cable opens its ready attached camera, else null. */
private fun postConfirmSession(
    environment: PairingEnvironment,
    record: SavedCameraRecord,
    host: String,
    usbCameras: List<UsbPtpCamera>,
): CameraSession? {
    if (record.transport != SavedCameraTransport.USB_C) return environment.createSession(host)
    val source = environment.usbCameraSource ?: return null
    val camera = usbCameras.firstOrNull { it.access == UsbPtpCameraAccess.READY && it.hostKey == record.host } ?: return null
    return when (val opened = source.open(camera)) {
        is UsbPtpOpenResult.Opened -> environment.createUsbSession(opened)
        is UsbPtpOpenResult.Rejected -> null
    }
}

/**
 * Connects [session] and hands it over only when it is live without having asked for another body
 * Confirm on the way: a restore-then-pair that fell into pairing is not a monitor session, even
 * when a later phase overwrote PAIRING or CONFIRM_ON_CAMERA before connect returned.
 */
private suspend fun connectedWithoutConfirm(session: CameraSession, record: SavedCameraRecord): PairedCamera? =
    coroutineScope {
        val asksForConfirm = { phase: CameraConnectionPhase ->
            phase == CameraConnectionPhase.PAIRING || phase == CameraConnectionPhase.CONFIRM_ON_CAMERA
        }
        var askedForConfirm = false
        val watcher =
            launch(start = CoroutineStart.UNDISPATCHED) {
                session.connectionProgress.collect { if (asksForConfirm(it.phase)) askedForConfirm = true }
            }
        var paired: PairedCamera? = null
        try {
            session.connect()
            val connected = session.state.value as? CameraSessionState.Connected
            if (connected != null && !askedForConfirm && !asksForConfirm(session.connectionProgress.value.phase)) {
                paired =
                    PairedCamera(
                        session = session,
                        savedCamera =
                            record.copy(
                                cameraName = connected.identity.name,
                                lastSeenAtEpochMillis = System.currentTimeMillis(),
                            ),
                    )
            }
        } finally {
            watcher.cancel()
            if (paired == null) withContext(NonCancellable) { session.disconnect() }
        }
        paired
    }
