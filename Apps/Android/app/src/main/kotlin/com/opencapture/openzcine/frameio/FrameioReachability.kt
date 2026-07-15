package com.opencapture.openzcine.frameio

import android.content.Context
import android.net.ConnectivityManager
import android.net.Network
import android.net.NetworkCapabilities

/** Current network safety state for Adobe IMS and Frame.io delivery. */
internal enum class FrameioNetworkState {
    /** A validated internet route is available to the process. */
    ONLINE,

    /** The process is still explicitly bound to the camera's no-internet AP. */
    CAMERA_ACCESS_POINT,

    /** No validated route can safely reach Adobe IMS or Frame.io. */
    OFFLINE,
}

/** Framework-free facts used by [FrameioReachabilityPolicy]. */
internal data class FrameioNetworkSnapshot(
    val processBound: Boolean,
    val boundNetworkHasValidatedInternet: Boolean,
    val activeNetworkHasValidatedInternet: Boolean,
)

/**
 * Fails cloud delivery closed while the PTP-IP process binding owns a local
 * camera AP. The app must never silently unbind/release that network because
 * doing so interrupts active camera control. Only the explicit, operator-approved
 * Frame.io hop may ask the pairing owner to release and later recreate it.
 */
internal object FrameioReachabilityPolicy {
    fun state(snapshot: FrameioNetworkSnapshot): FrameioNetworkState =
        when {
            snapshot.processBound && snapshot.boundNetworkHasValidatedInternet -> FrameioNetworkState.ONLINE
            snapshot.processBound -> FrameioNetworkState.CAMERA_ACCESS_POINT
            snapshot.activeNetworkHasValidatedInternet -> FrameioNetworkState.ONLINE
            else -> FrameioNetworkState.OFFLINE
        }

    fun operatorMessage(state: FrameioNetworkState): String =
        when (state) {
            FrameioNetworkState.ONLINE -> ""
            FrameioNetworkState.CAMERA_ACCESS_POINT ->
                "Frame.io needs internet. This phone is still bound to the camera's Wi-Fi, so OpenZCine will not interrupt camera control without your approval. Use Hop to internet to disconnect, upload, then verify a camera rejoin."
            FrameioNetworkState.OFFLINE ->
                "Frame.io needs a validated internet connection. Check Wi‑Fi or cellular and try again."
        }
}

/** Platform reachability adapter used immediately before every cloud action. */
internal interface FrameioReachability {
    fun state(): FrameioNetworkState
}

/** Android [ConnectivityManager] adapter; it does not change network bindings. */
internal class AndroidFrameioReachability(context: Context) : FrameioReachability {
    private val connectivity = context.getSystemService(ConnectivityManager::class.java)

    override fun state(): FrameioNetworkState {
        val bound = connectivity.boundNetworkForProcess
        return FrameioReachabilityPolicy.state(
            FrameioNetworkSnapshot(
                processBound = bound != null,
                boundNetworkHasValidatedInternet = bound?.hasValidatedInternet() ?: false,
                activeNetworkHasValidatedInternet = connectivity.activeNetwork?.hasValidatedInternet() ?: false,
            ),
        )
    }

    private fun Network.hasValidatedInternet(): Boolean {
        val capabilities = connectivity.getNetworkCapabilities(this) ?: return false
        return capabilities.hasCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET) &&
            capabilities.hasCapability(NetworkCapabilities.NET_CAPABILITY_VALIDATED)
    }
}
