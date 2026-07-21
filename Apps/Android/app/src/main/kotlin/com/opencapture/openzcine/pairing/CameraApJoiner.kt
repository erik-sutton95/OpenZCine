package com.opencapture.openzcine.pairing

import android.content.Context
import android.net.ConnectivityManager
import android.net.Network
import android.net.NetworkCapabilities
import android.net.NetworkRequest
import android.net.wifi.WifiManager
import android.net.wifi.WifiNetworkSpecifier
import android.os.Handler
import android.os.Looper
import kotlinx.coroutines.CancellableContinuation
import kotlinx.coroutines.suspendCancellableCoroutine
import kotlinx.coroutines.withTimeoutOrNull

/**
 * CAMERA-AP-ONLY Wi-Fi join machinery: the phone joins the camera's own
 * network (`NIKON_ZR_xxxxx`) via [WifiNetworkSpecifier] +
 * [ConnectivityManager.requestNetwork] — a peer-to-peer request with no
 * internet expectation (API 29+, the app's minSdk floor).
 *
 * This class is the entire camera-AP network surface. The phone-hotspot path
 * must NEVER touch it: there the camera joins the phone, the phone hosts and
 * neither scans nor joins anything (the iOS shells learned this separation
 * the hard way — see `hotspot-path-not-camera-ap` history).
 *
 * On join, the process is bound to the camera network with
 * [ConnectivityManager.bindProcessToNetwork] so the PTP-IP sockets route over
 * it (the specifier network carries no internet, and unbound sockets would
 * otherwise prefer the default network). The [android.net.ConnectivityManager.NetworkCallback]
 * stays registered while the session lives — unregistering tears the
 * peer-to-peer network down — so callers must [release] on teardown.
 *
 * The system "switch networks" dialog only appears after Android finds a
 * matching AP in scan results (unlike iOS `NEHotspotConfiguration`, which
 * prompts immediately). Callers should stage a Ready-to-join confirm first
 * and keep Wi‑Fi enabled so the dialog can surface.
 */
public class CameraApJoiner(context: Context) {
    private val appContext = context.applicationContext
    private val connectivity =
        appContext.getSystemService(ConnectivityManager::class.java)
            ?: error("ConnectivityManager unavailable")
    private val wifi = appContext.getSystemService(WifiManager::class.java)
    private val mainHandler = Handler(Looper.getMainLooper())
    private val lock = Any()
    private val availability = CameraApAvailabilityTracker<Network>()
    private val reassociationWaiters = mutableListOf<ReassociationWaiter>()
    private var callback: ConnectivityManager.NetworkCallback? = null
    private var joinContinuation: CancellableContinuation<Boolean>? = null

    /**
     * Requests the camera's network and suspends until Android connects
     * (`true`) or declines/times out (`false`). Android shows its own consent
     * dialog for the specifier request once the AP is visible; a user cancel
     * surfaces as `onUnavailable` → `false`. Cancelling the coroutine releases
     * its own request without disturbing a later [join] call.
     *
     * Returns `false` immediately when Wi‑Fi is disabled — Android never shows
     * a join dialog while the radio is off.
     *
     * @param ssid Exact camera SSID from the camera's Direct-connection screen.
     * @param passphrase WPA2 key, or null/empty for an open camera network.
     * @param timeoutMillis How long Android keeps looking before giving up.
     */
    public suspend fun join(
        ssid: String,
        passphrase: String?,
        timeoutMillis: Int = 45_000,
    ): Boolean {
        release()
        // No scan → no specifier match → no system "switch networks" dialog.
        if (wifi != null && !wifi.isWifiEnabled) {
            return false
        }
        val specifier =
            WifiNetworkSpecifier.Builder()
                .setSsid(ssid)
                .apply { if (!passphrase.isNullOrEmpty()) setWpa2Passphrase(passphrase) }
                .build()
        val request =
            NetworkRequest.Builder()
                .addTransportType(NetworkCapabilities.TRANSPORT_WIFI)
                .removeCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET)
                .setNetworkSpecifier(specifier)
                .build()
        return suspendCancellableCoroutine { continuation ->
            lateinit var networkCallback: ConnectivityManager.NetworkCallback
            networkCallback =
                object : ConnectivityManager.NetworkCallback() {
                    override fun onAvailable(network: Network) {
                        handleAvailable(networkCallback, network)
                    }

                    override fun onLost(network: Network) {
                        handleLost(networkCallback, network)
                    }

                    override fun onUnavailable() {
                        handleUnavailable(networkCallback)
                    }
                }

            synchronized(lock) {
                availability.requestStarted()
                callback = networkCallback
                joinContinuation = continuation
            }
            // Post the request on the main looper so OEMs that attach the
            // system join dialog to the foreground activity's UI thread still
            // surface it above our connection popup.
            mainHandler.post {
                if (!continuation.isActive) {
                    releaseOwned(networkCallback)
                    return@post
                }
                try {
                    connectivity.requestNetwork(
                        request,
                        networkCallback,
                        mainHandler,
                        timeoutMillis,
                    )
                } catch (_: RuntimeException) {
                    // SecurityException / IllegalArgumentException / IllegalStateException
                    // when the radio or framework rejects the request.
                    handleUnavailable(networkCallback)
                }
            }
            continuation.invokeOnCancellation { releaseOwned(networkCallback) }
        }
    }

    /**
     * Waits for the currently joined camera AP to disappear and then become
     * available again. Nikon performs that restart after the operator accepts
     * an initial pairing request on the camera body. The request and callback
     * remain registered while this wait is active, so the replacement AP can
     * rebind the process before this method returns.
     *
     * This method never reports success for a duplicate availability callback
     * from the already joined network. It returns `false` when there is no
     * established camera-AP request, Android declares that request unavailable,
     * or the supplied timeout elapses. Cancelling this method propagates
     * cancellation after removing only its wait; it does not release the camera
     * AP.
     *
     * @param timeoutMillis Maximum time to wait for the loss-and-reavailability cycle.
     */
    public suspend fun awaitReassociation(timeoutMillis: Long): Boolean {
        require(timeoutMillis > 0L) { "timeoutMillis must be greater than zero." }
        return withTimeoutOrNull(timeoutMillis) {
            suspendCancellableCoroutine { continuation ->
                val waiter =
                    synchronized(lock) {
                        val targetGeneration = availability.nextReassociationGeneration()
                        if (targetGeneration == null) {
                            null
                        } else {
                            ReassociationWaiter(targetGeneration, continuation).also(
                                reassociationWaiters::add,
                            )
                        }
                    }
                if (waiter == null) {
                    continuation.resumeValue(false)
                } else {
                    continuation.invokeOnCancellation { removeReassociationWaiter(continuation) }
                }
            }
        } ?: false
    }

    /**
     * Whether the process is currently bound to an established camera-AP network
     * from this joiner. Used after body-side Confirm to skip a wasteful
     * `release()` + full rejoin when [awaitReassociation] already rebound us.
     */
    public fun isProcessBound(): Boolean =
        synchronized(lock) { availability.hasEstablishedNetwork() }

    /**
     * Joins the camera AP only when we are not already process-bound. Prefer this
     * after first-pair Confirm: a successful reassociation keeps the peer-to-peer
     * request alive, and [join] would tear it down and re-scan (slow on Samsung).
     */
    public suspend fun ensureJoined(
        ssid: String,
        passphrase: String?,
        timeoutMillis: Int = 45_000,
    ): Boolean {
        if (isProcessBound()) return true
        return join(ssid, passphrase, timeoutMillis)
    }

    /**
     * Drops the camera network: unbinds the process and unregisters the
     * callback (which releases the peer-to-peer network). Safe to call twice.
     */
    public fun release() {
        val release =
            synchronized(lock) {
                callback?.let { detachLocked(it) }
            } ?: return
        finishRelease(release)
    }

    private fun handleAvailable(
        expectedCallback: ConnectivityManager.NetworkCallback,
        network: Network,
    ) {
        val completions =
            synchronized(lock) {
                if (callback !== expectedCallback) {
                    return
                }
                val result = availability.onAvailable(network)
                if (!result.shouldBind) {
                    return
                }
                connectivity.bindProcessToNetwork(network)
                CompletionBatch(
                    join = joinContinuation.takeIf { availability.hasEstablishedNetwork() },
                    reassociation = result.reassociationGeneration?.let(::takeReassociationWaiters),
                ).also { joinContinuation = null }
            }
        completions.resume(success = true)
    }

    private fun handleLost(
        expectedCallback: ConnectivityManager.NetworkCallback,
        network: Network,
    ) {
        synchronized(lock) {
            if (callback === expectedCallback && availability.onLost(network)) {
                connectivity.bindProcessToNetwork(null)
            }
        }
    }

    private fun handleUnavailable(expectedCallback: ConnectivityManager.NetworkCallback) {
        val completions =
            synchronized(lock) {
                if (callback !== expectedCallback) {
                    return
                }
                availability.onUnavailable()
                CompletionBatch(
                    join = joinContinuation,
                    reassociation = reassociationWaiters.toList(),
                ).also {
                    joinContinuation = null
                    reassociationWaiters.clear()
                }
            }
        completions.resume(success = false)
    }

    private fun releaseOwned(expectedCallback: ConnectivityManager.NetworkCallback) {
        val release =
            synchronized(lock) {
                if (callback === expectedCallback) {
                    detachLocked(expectedCallback)
                } else {
                    null
                }
            } ?: return
        finishRelease(release)
    }

    private fun detachLocked(expectedCallback: ConnectivityManager.NetworkCallback): Release {
        callback = null
        availability.release()
        connectivity.bindProcessToNetwork(null)
        return Release(
            callback = expectedCallback,
            join = joinContinuation,
            reassociation = reassociationWaiters.toList(),
        ).also {
            joinContinuation = null
            reassociationWaiters.clear()
        }
    }

    private fun finishRelease(release: Release) {
        // Racing a self-releasing request (e.g. timeout) throws if already gone.
        runCatching { connectivity.unregisterNetworkCallback(release.callback) }
        release.join?.resumeValue(false)
        release.reassociation.forEach { it.continuation.resumeValue(false) }
    }

    private fun removeReassociationWaiter(continuation: CancellableContinuation<Boolean>) {
        synchronized(lock) {
            reassociationWaiters.removeAll { it.continuation === continuation }
        }
    }

    private fun takeReassociationWaiters(generation: Long): List<ReassociationWaiter> {
        val complete = reassociationWaiters.filter { it.targetGeneration <= generation }
        reassociationWaiters.removeAll(complete.toSet())
        return complete
    }

    private data class ReassociationWaiter(
        val targetGeneration: Long,
        val continuation: CancellableContinuation<Boolean>,
    )

    private data class Release(
        val callback: ConnectivityManager.NetworkCallback,
        val join: CancellableContinuation<Boolean>?,
        val reassociation: List<ReassociationWaiter>,
    )

    private data class CompletionBatch(
        val join: CancellableContinuation<Boolean>?,
        val reassociation: List<ReassociationWaiter>?,
    ) {
        fun resume(success: Boolean) {
            join?.resumeValue(success)
            reassociation.orEmpty().forEach { it.continuation.resumeValue(success) }
        }
    }
}

/** Safely resumes a cancellable continuation only while it still owns the result. */
private fun CancellableContinuation<Boolean>.resumeValue(value: Boolean) {
    if (isActive) {
        resume(value, onCancellation = null)
    }
}

/**
 * Framework-free availability policy behind [CameraApJoiner]. Android emits
 * callbacks from arbitrary threads, so callers serialize this state with the
 * joiner's lock. Keeping the lifecycle policy here makes the loss/restart
 * contract executable in local JVM tests without mocking Android networking.
 */
internal class CameraApAvailabilityTracker<NetworkToken : Any> {
    internal data class AvailableResult(
        val shouldBind: Boolean,
        val reassociationGeneration: Long?,
    )

    private var requestActive: Boolean = false
    private var activeNetwork: NetworkToken? = null
    private var hasEstablishedNetwork: Boolean = false
    private var awaitingReassociation: Boolean = false
    private var reassociationGeneration: Long = 0L

    /** Starts a fresh camera-AP request after the previous request is released. */
    internal fun requestStarted() {
        requestActive = true
        activeNetwork = null
        hasEstablishedNetwork = false
        awaitingReassociation = false
        reassociationGeneration = 0L
    }

    /**
     * Records an available network. A duplicate callback for the current
     * network is intentionally ignored: it cannot complete a restart wait.
     */
    internal fun onAvailable(network: NetworkToken): AvailableResult {
        if (!requestActive) {
            return AvailableResult(shouldBind = false, reassociationGeneration = null)
        }
        val previousNetwork = activeNetwork
        if (previousNetwork == network) {
            return AvailableResult(shouldBind = false, reassociationGeneration = null)
        }

        val completedReassociation = hasEstablishedNetwork &&
            (awaitingReassociation || previousNetwork != null)
        activeNetwork = network
        hasEstablishedNetwork = true
        awaitingReassociation = false
        val generation =
            if (completedReassociation) {
                ++reassociationGeneration
            } else {
                null
            }
        return AvailableResult(shouldBind = true, reassociationGeneration = generation)
    }

    /**
     * Records loss only when [network] is the owned active network. A stale
     * callback must not clear a newer process binding.
     */
    internal fun onLost(network: NetworkToken): Boolean {
        if (activeNetwork != network) {
            return false
        }
        activeNetwork = null
        awaitingReassociation = true
        return true
    }

    /** Marks the request terminal without fabricating an [onLost] event. */
    internal fun onUnavailable() {
        requestActive = false
    }

    /** Resets all state when the caller deliberately releases the camera AP. */
    internal fun release() {
        requestActive = false
        activeNetwork = null
        hasEstablishedNetwork = false
        awaitingReassociation = false
        reassociationGeneration = 0L
    }

    /**
     * Returns the next reassociation generation a waiter must observe, or null
     * unless this request has successfully joined a camera AP and remains live.
     */
    internal fun nextReassociationGeneration(): Long? =
        if (requestActive && hasEstablishedNetwork) {
            reassociationGeneration + 1L
        } else {
            null
        }

    /** Whether [onAvailable] has established a camera AP for the current request. */
    internal fun hasEstablishedNetwork(): Boolean = hasEstablishedNetwork
}
