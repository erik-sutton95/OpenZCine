package com.opencapture.openzcine.pairing

import android.Manifest
import android.content.Context
import android.content.pm.PackageManager
import android.net.ConnectivityManager
import android.net.NetworkCapabilities
import android.net.wifi.WifiInfo
import android.net.wifi.WifiManager

/**
 * The name of the Wi-Fi network this device is on, when the operator has allowed us to read it.
 *
 * Only one thing uses this: telling a camera's router setups apart. A body reached from the studio
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

    /**
     * The current network's name, or null when it cannot be read for any reason.
     *
     * Reads through [NetworkCapabilities.getTransportInfo] rather than the long-deprecated
     * `WifiManager.getConnectionInfo()`: on 12+ that one answers for whichever network the SYSTEM
     * considers primary, which during a camera-AP join is not the one the app is bound to.
     */
    public fun read(context: Context): String? {
        if (!isPermissionGranted(context)) return null
        val connectivity =
            context.getSystemService(ConnectivityManager::class.java) ?: return null
        val network = connectivity.activeNetwork ?: return null
        val capabilities = connectivity.getNetworkCapabilities(network) ?: return null
        if (!capabilities.hasTransport(NetworkCapabilities.TRANSPORT_WIFI)) return null
        val info = capabilities.transportInfo as? WifiInfo ?: return null
        return sanitized(info.ssid)
    }

    /**
     * Strips the quotes the platform wraps an SSID in, and rejects the placeholders it returns
     * when it will not say. Pure, so the parsing is testable without a device.
     */
    public fun sanitized(rawSsid: String?): String? {
        val trimmed = rawSsid?.trim() ?: return null
        val unquoted =
            if (trimmed.length >= 2 && trimmed.startsWith('"') && trimmed.endsWith('"')) {
                trimmed.substring(1, trimmed.length - 1)
            } else {
                trimmed
            }
        if (unquoted.isEmpty() || unquoted == REDACTED) return null
        // A camera's own access point is never an infrastructure network, whatever else is true.
        if (looksLikeNikonAccessPointSsid(unquoted)) return null
        return unquoted
    }
}
