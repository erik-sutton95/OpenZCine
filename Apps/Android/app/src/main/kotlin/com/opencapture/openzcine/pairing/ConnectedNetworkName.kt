package com.opencapture.openzcine.pairing

import android.Manifest
import android.content.Context
import android.content.pm.PackageManager
import android.net.ConnectivityManager
import android.net.Network
import android.net.NetworkCapabilities
import android.net.NetworkRequest
import android.net.wifi.WifiInfo
import android.net.wifi.WifiManager
import android.os.Build
import androidx.annotation.RequiresApi
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit

/**
 * The name of the Wi-Fi network this device is on, when the operator has allowed us to read it.
 *
 * It tells a camera's access point from other networks ([isCameraAccessPoint]) and a camera's
 * router setups apart ([read]). A body reached from the studio
 * and from home is two setups, and the network's name is the only thing that can say so — the
 * address cannot, because the router hands out a different one whenever it feels like it, and
 * keying on it would fork a setup every lease instead of separating two networks.
 *
 * Android gates the SSID behind location because a network name can be looked up geographically.
 * The app asks for that permission at the moment a router setup needs naming, never at launch, and
 * every answer here is optional: [read] returns null when the permission is absent, when the
 * device is not on Wi-Fi, or when the OS redacts the value, and an unnamed network simply joins
 * whatever router setup already exists — which is exactly the behaviour every operator had before
 * this existed.
 */
public object ConnectedNetworkName {
    /** What the OS returns instead of an SSID when it will not tell us. */
    private const val REDACTED = WifiManager.UNKNOWN_SSID

    public fun isPermissionGranted(context: Context): Boolean =
        context.checkSelfPermission(Manifest.permission.ACCESS_FINE_LOCATION) ==
            PackageManager.PERMISSION_GRANTED

    /** The current network's name, or null when it cannot be read for any reason. */
    public fun read(context: Context): String? = currentSsids(context).firstNotNullOfOrNull(::sanitized)

    /**
     * Whether the phone is on a camera's own access point (camera access points isolate their
     * clients, so some joins cannot work from there). False when no name can be read.
     */
    public fun isCameraAccessPoint(context: Context): Boolean =
        currentSsids(context).any { unquoted(it)?.let(::looksLikeNikonAccessPointSsid) == true }

    /**
     * Strips the quotes the platform wraps an SSID in, and rejects the placeholders it returns
     * when it will not say, and a camera's own access point. Pure, so the parsing is testable
     * without a device.
     */
    public fun sanitized(rawSsid: String?): String? =
        // A camera's own access point is never an infrastructure network, whatever else is true.
        unquoted(rawSsid)?.takeUnless(::looksLikeNikonAccessPointSsid)

    private fun unquoted(rawSsid: String?): String? {
        val trimmed = rawSsid?.trim() ?: return null
        val unquoted =
            if (trimmed.length >= 2 && trimmed.startsWith('"') && trimmed.endsWith('"')) {
                trimmed.substring(1, trimmed.length - 1)
            } else {
                trimmed
            }
        return unquoted.takeUnless { it.isEmpty() || it == REDACTED }
    }

    /** The joined Wi-Fi networks' SSIDs as the platform words them; empty without the permission. */
    private fun currentSsids(context: Context): Collection<String> {
        if (!isPermissionGranted(context)) return emptyList()
        val app = context.applicationContext
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.S) {
            // Before 12 a Wi-Fi network carries no transport info; this is the platform's reader.
            @Suppress("DEPRECATION")
            return listOfNotNull(app.getSystemService(WifiManager::class.java)?.connectionInfo?.ssid)
        }
        return WifiNetworkNames.current(app)
    }
}

/**
 * The joined Wi-Fi networks' names on 12+. A one-shot `getNetworkCapabilities` redacts the name
 * for an app targeting 12+; only a callback registered with FLAG_INCLUDE_LOCATION_INFO receives it.
 * Registered on the first read and kept for the process, so every later read answers at once.
 */
// ponytail: one process-long callback; unregister it if a reader ever needs to stop watching.
@RequiresApi(Build.VERSION_CODES.S)
private object WifiNetworkNames {
    /** How long the first read waits for the platform's first answer while Wi-Fi is on. */
    private const val FIRST_ANSWER_MILLIS = 500L

    private val names = ConcurrentHashMap<Network, String>()
    private val firstAnswer = CountDownLatch(1)
    private var registered = false

    fun current(context: Context): Collection<String> {
        if (register(context) && context.getSystemService(WifiManager::class.java)?.isWifiEnabled == true) {
            firstAnswer.await(FIRST_ANSWER_MILLIS, TimeUnit.MILLISECONDS)
        }
        return names.values.toList()
    }

    /** Registers the callback once; true on the call that did. */
    @Synchronized
    private fun register(context: Context): Boolean {
        if (registered) return false
        val connectivity = context.getSystemService(ConnectivityManager::class.java) ?: return false
        val request = NetworkRequest.Builder().addTransportType(NetworkCapabilities.TRANSPORT_WIFI).build()
        connectivity.registerNetworkCallback(
            request,
            object : ConnectivityManager.NetworkCallback(FLAG_INCLUDE_LOCATION_INFO) {
                override fun onCapabilitiesChanged(network: Network, capabilities: NetworkCapabilities) {
                    (capabilities.transportInfo as? WifiInfo)?.ssid?.let { names[network] = it }
                    firstAnswer.countDown()
                }

                override fun onLost(network: Network) {
                    names.remove(network)
                }
            },
        )
        registered = true
        return true
    }
}
