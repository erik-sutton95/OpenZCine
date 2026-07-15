package com.opencapture.openzcine.lut

import android.content.Context
import android.net.ConnectivityManager
import android.net.NetworkCapabilities
import java.net.URI

/** Must match `LUTLibraryWire.redAvailabilityRecordVersion` on the Swift/JNI side. */
private const val RED_AVAILABILITY_RECORD_VERSION = "1"

private const val LUT_WIRE_FIELD_SEPARATOR = "\u001F"

/**
 * The only configuration shape that could enable a future Android RED delivery implementation.
 *
 * This public build deliberately supplies [UNCONFIGURED]. A real integration must provide an
 * HTTPS endpoint, the exact RED terms URL/revision that the operator sees, and an explicit
 * authorization approval. No endpoint, identity, token, or RED asset is inferred from a label or
 * bundled into the app.
 */
data class RedLutDownloadConfiguration(
    val endpoint: String?,
    val termsUrl: String?,
    val termsRevision: String?,
    val authorizedForThisBuild: Boolean,
) {
    /** A configuration that can truthfully enter a terms/authorization workflow. */
    val isAuthorized: Boolean
        get() =
            authorizedForThisBuild && endpoint.isHttpsUrl() && termsUrl.isHttpsUrl() &&
                !termsRevision.isNullOrBlank()

    companion object {
        /** The production default until RED authorizes and an Android terms flow is implemented. */
        val UNCONFIGURED = RedLutDownloadConfiguration(
            endpoint = null,
            termsUrl = null,
            termsRevision = null,
            authorizedForThisBuild = false,
        )
    }
}

/** Network state originating in shared `RedLUTDownloadPolicy`, not Kotlin policy reimplementation. */
enum class RedLutNetworkAvailability(val operatorMessage: String) {
    AVAILABLE("Internet is available for an authorized RED workflow."),
    ON_CAMERA_ACCESS_POINT(
        "Connect to the internet before downloading RED LUTs — the camera Wi-Fi access point has no internet.",
    ),
    NO_INTERNET("Connect to the internet before downloading RED LUTs — no usable internet path is available."),
    SWIFT_CORE_UNAVAILABLE("The shared RED network policy is unavailable in this build."),
}

/** Truthful readiness report for the RED tab. `canEnterWorkflow` is false in public builds. */
data class RedLutDownloadReadiness(
    val network: RedLutNetworkAvailability,
    val configuration: RedLutDownloadConfiguration,
) {
    /** A real terms/authorization screen may be entered only after both guards pass. */
    val canEnterWorkflow: Boolean
        get() = network == RedLutNetworkAvailability.AVAILABLE && configuration.isAuthorized

    /** Why no download button is available yet, without implying a fixture or a configured RED flow. */
    val configurationMessage: String?
        get() =
            if (configuration.isAuthorized) {
                null
            } else {
                "RED download is not configured for Android. An authorized HTTPS endpoint, RED terms " +
                    "revision, and operator acknowledgement flow are required before downloads can be enabled."
            }
}

/**
 * Platform reachability adapter for the shared RED download policy. Camera AP detection is based
 * on the process-bound network: `CameraApJoiner` is the only production class that binds a
 * no-internet Wi-Fi network, so a bound network without `NET_CAPABILITY_INTERNET` is the actual
 * local camera route rather than a guessed SSID.
 */
class RedLutDownloadGate internal constructor(
    private val connectivity: ConnectivityManager,
    private val core: LutCoreBridge,
) {
    constructor(context: Context) : this(
        context.getSystemService(ConnectivityManager::class.java),
        SwiftLutCoreBridge,
    )

    /** Resolves network safety first, then reports whether an authorized delivery workflow exists. */
    fun readiness(
        configuration: RedLutDownloadConfiguration = RedLutDownloadConfiguration.UNCONFIGURED,
    ): RedLutDownloadReadiness {
        val bound = connectivity.boundNetworkForProcess
        val network = bound ?: connectivity.activeNetwork
        val capabilities = network?.let(connectivity::getNetworkCapabilities)
        val isOnCameraAccessPoint =
            bound != null && capabilities?.hasCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET) != true
        val hasInternetPath =
            capabilities?.hasCapability(NetworkCapabilities.NET_CAPABILITY_VALIDATED) == true
        val native = core.redDownloadAvailability(hasInternetPath, isOnCameraAccessPoint)
        val availability = redNetworkAvailability(native)
        return RedLutDownloadReadiness(availability, configuration)
    }
}

/** Strict decoder for the versioned `[version, state]` record from the shared Swift RED policy. */
internal fun redNetworkAvailability(record: String?): RedLutNetworkAvailability {
    val fields = record?.split(LUT_WIRE_FIELD_SEPARATOR)
        ?: return RedLutNetworkAvailability.SWIFT_CORE_UNAVAILABLE
    if (fields.size != 2 || fields[0] != RED_AVAILABILITY_RECORD_VERSION) {
        return RedLutNetworkAvailability.SWIFT_CORE_UNAVAILABLE
    }
    return when (fields[1]) {
        "0" -> RedLutNetworkAvailability.AVAILABLE
        "1" -> RedLutNetworkAvailability.ON_CAMERA_ACCESS_POINT
        "2" -> RedLutNetworkAvailability.NO_INTERNET
        else -> RedLutNetworkAvailability.SWIFT_CORE_UNAVAILABLE
    }
}

private fun String?.isHttpsUrl(): Boolean {
    val value = this ?: return false
    return try {
        val uri = URI(value)
        uri.scheme.equals("https", ignoreCase = true) && !uri.host.isNullOrBlank()
    } catch (_: IllegalArgumentException) {
        false
    }
}
