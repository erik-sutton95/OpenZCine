package com.opencapture.openzcine.pairing

import com.opencapture.openzcine.transport.CameraDiscovery
import java.net.InetSocketAddress
import java.net.Socket
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.async
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.delay
import kotlinx.coroutines.isActive
import kotlinx.coroutines.selects.select
import kotlinx.coroutines.withContext
import kotlinx.coroutines.withTimeoutOrNull

/**
 * Post-Confirm camera-AP readiness helpers.
 *
 * Samsung (and some other OEMs) can delay or skip NetworkCallback loss/return for
 * peer-to-peer WifiNetworkSpecifier networks after the body restarts its AP.
 * Waiting only on reassociation can pin the UI on "Confirm on camera" for the full
 * timeout, then fail saved-profile connect against a stale bind. Probing the fixed
 * PTP-IP host in parallel exits as soon as the body answers again.
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
    host: String = CameraDiscovery.NIKON_ZR_ACCESS_POINT_HOST,
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
 * Suspend until the camera AP is ready for a saved-profile reconnect after body Confirm.
 *
 * Races:
 * 1. [awaitReassociation] — OEM callback when the AP drops and returns
 * 2. Continuous TCP probes to the fixed camera-AP host — wins when PTP answers even if
 *    callbacks never fire (common on Samsung)
 *
 * Returns `true` when either path succeeds before [timeoutMillis].
 */
internal suspend fun awaitCameraApReadyAfterConfirm(
    awaitReassociation: suspend (timeoutMillis: Long) -> Boolean,
    isProcessBound: () -> Boolean,
    host: String = CameraDiscovery.NIKON_ZR_ACCESS_POINT_HOST,
    timeoutMillis: Long = FIRST_PAIR_CAMERA_AP_RESTART_TIMEOUT_MILLIS,
): Boolean =
    coroutineScope {
        val deadline = System.nanoTime() + timeoutMillis * 1_000_000L
        val reassociation =
            async(Dispatchers.IO) {
                awaitReassociation(timeoutMillis)
            }
        val probe =
            async(Dispatchers.IO) {
                if (isProcessBound() && probePtpIpReachable(host)) return@async true
                while (isActive && System.nanoTime() < deadline) {
                    if (probePtpIpReachable(host)) return@async true
                    delay(CAMERA_AP_PTP_PROBE_INTERVAL_MILLIS)
                }
                false
            }
        try {
            select {
                reassociation.onAwait { ok ->
                    if (ok) {
                        probe.cancel()
                        // AP is back. A short port wait improves the first Init hit rate;
                        // the reconnect loop still retries if PTP is not ready yet.
                        awaitPtpPortBriefly(host, maxWaitMillis = 1_200L)
                        true
                    } else {
                        // Still race the probe for remaining budget — reassociation alone failed.
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
 * Runs the post-Confirm reconnect loop: ensure Wi‑Fi, wait for PTP port, then saved-profile
 * connect until success or [timeoutMillis].
 *
 * [joinCameraAp] always performs a full join (release + request). Call it when unbound or after
 * repeated Init failures on a stale bind. Prefer [ensureJoined] only when [isProcessBound] is false.
 */
internal suspend fun reconnectCameraApAfterConfirm(
    rejoinSsid: String?,
    rejoinKey: String?,
    isProcessBound: () -> Boolean,
    ensureJoined: suspend (ssid: String, passphrase: String?, timeoutMillis: Int) -> Boolean,
    forceJoin: suspend (ssid: String, passphrase: String?, timeoutMillis: Int) -> Boolean,
    connectSavedProfile: suspend () -> Boolean,
    onPhaseReconnecting: () -> Unit,
    timeoutMillis: Long = FIRST_PAIR_RECONNECT_TIMEOUT_MILLIS,
): Boolean =
    withTimeoutOrNull(timeoutMillis) {
        var bound = isProcessBound()
        var consecutiveInitFailures = 0
        while (true) {
            onPhaseReconnecting()
            if (rejoinSsid != null) {
                val force = consecutiveInitFailures >= 3
                val needJoin = !bound || force
                if (needJoin) {
                    val joined =
                        if (force) {
                            forceJoin(rejoinSsid, rejoinKey, FIRST_PAIR_REJOIN_TIMEOUT_MILLIS * 2)
                        } else {
                            ensureJoined(rejoinSsid, rejoinKey, FIRST_PAIR_REJOIN_TIMEOUT_MILLIS)
                        }
                    if (!joined) {
                        consecutiveInitFailures = 0
                        delay(FIRST_PAIR_RECONNECT_INTERVAL_MILLIS)
                        bound = isProcessBound()
                        continue
                    }
                    bound = true
                    consecutiveInitFailures = 0
                    delay(CAMERA_AP_POST_JOIN_SETTLE_MILLIS)
                }
            }
            // Prefer waiting for the port before a full 10s Init attempt.
            if (!withContext(Dispatchers.IO) { probePtpIpReachable() }) {
                delay(CAMERA_AP_PTP_PROBE_INTERVAL_MILLIS)
                bound = isProcessBound()
                if (!bound) consecutiveInitFailures = 0
                continue
            }
            val ok = connectSavedProfile()
            if (ok) return@withTimeoutOrNull true
            consecutiveInitFailures += 1
            bound = isProcessBound()
            delay(
                if (bound && consecutiveInitFailures < 3) {
                    FIRST_PAIR_BOUND_RETRY_INTERVAL_MILLIS
                } else {
                    FIRST_PAIR_RECONNECT_INTERVAL_MILLIS
                },
            )
        }
        @Suppress("UNREACHABLE_CODE")
        false
    } == true
