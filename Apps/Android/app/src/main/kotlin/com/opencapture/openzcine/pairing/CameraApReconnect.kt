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
 * Suspend until the camera AP looks ready after body Confirm (best-effort).
 *
 * Races reassociation callbacks with TCP probes. Returns when either succeeds
 * or [timeoutMillis] elapses — callers should still force a clean rejoin
 * afterward (My-cameras parity).
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
                // Only treat a probe as success when we still own a process bind,
                // otherwise a phantom route can exit the wait early.
                while (isActive && System.nanoTime() < deadline) {
                    if (isProcessBound() && probePtpIpReachable(host)) return@async true
                    delay(CAMERA_AP_PTP_PROBE_INTERVAL_MILLIS)
                }
                false
            }
        try {
            select {
                reassociation.onAwait { ok ->
                    if (ok) {
                        probe.cancel()
                        awaitPtpPortBriefly(host, maxWaitMillis = 2_000L)
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
 * 3. Wait for PTP port
 * 4. Restore-profile-then-pair connect with short retries
 * 5. Force rejoin again after repeated Init failures
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
            // Prefer waiting for the port before a full Init attempt.
            if (!withContext(Dispatchers.IO) { probePtpIpReachable() }) {
                delay(CAMERA_AP_PTP_PROBE_INTERVAL_MILLIS)
                consecutiveInitFailures =
                    if (isProcessBound()) consecutiveInitFailures else 0
                // If we never joined, force-join on next loop.
                if (!isProcessBound() && rejoinSsid != null) {
                    didInitialForceJoin = false
                }
                continue
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
