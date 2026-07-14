package com.opencapture.openzcine.pairing

import android.net.ConnectivityManager
import android.net.Network
import android.net.NetworkCapabilities
import android.net.NetworkRequest
import android.net.wifi.WifiNetworkSpecifier
import kotlin.coroutines.resume
import kotlinx.coroutines.suspendCancellableCoroutine

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
 */
public class CameraApJoiner(private val connectivity: ConnectivityManager) {
    private var callback: ConnectivityManager.NetworkCallback? = null

    /**
     * Requests the camera's network and suspends until Android connects
     * (`true`) or declines/times out (`false`). Android shows its own consent
     * dialog for the specifier request; a user cancel surfaces as
     * `onUnavailable` → `false`. Cancelling the coroutine releases the request.
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
            val networkCallback =
                object : ConnectivityManager.NetworkCallback() {
                    override fun onAvailable(network: Network) {
                        connectivity.bindProcessToNetwork(network)
                        if (continuation.isActive) continuation.resume(true)
                    }

                    override fun onUnavailable() {
                        if (continuation.isActive) continuation.resume(false)
                    }
                }
            callback = networkCallback
            connectivity.requestNetwork(request, networkCallback, timeoutMillis)
            continuation.invokeOnCancellation { release() }
        }
    }

    /**
     * Drops the camera network: unbinds the process and unregisters the
     * callback (which releases the peer-to-peer network). Safe to call twice.
     */
    public fun release() {
        val current = callback ?: return
        callback = null
        connectivity.bindProcessToNetwork(null)
        // Racing a self-releasing request (e.g. timeout) throws if already gone.
        runCatching { connectivity.unregisterNetworkCallback(current) }
    }
}
