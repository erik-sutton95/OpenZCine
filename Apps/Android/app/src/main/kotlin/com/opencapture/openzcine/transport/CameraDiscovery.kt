package com.opencapture.openzcine.transport

import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.distinctUntilChanged
import kotlinx.coroutines.flow.map
import kotlinx.coroutines.flow.scan

/**
 * A PTP-IP camera discovered on the network (or addressed directly in
 * camera-AP mode).
 *
 * @property name Service/camera name as advertised over mDNS (for example
 *   `"ZR_1234"`), or a fixed label for direct-host cameras.
 * @property host IPv4 address the camera answers on.
 * @property port TCP port of the PTP-IP responder (normally [CameraDiscovery.PTP_IP_PORT]).
 */
data class DiscoveredCamera(
    val name: String,
    val host: String,
    val port: Int,
)

/**
 * Platform-free mDNS browse events — the thin seam over [android.net.nsd.NsdManager]
 * so discovery bookkeeping stays testable on the JVM.
 */
sealed interface NsdEvent {
    /** A service appeared but has not resolved to a host yet. */
    data class ServiceFound(val serviceName: String) : NsdEvent

    /** A found service resolved to a reachable host/port. */
    data class ServiceResolved(val serviceName: String, val host: String, val port: Int) : NsdEvent

    /** A previously found service disappeared from the network. */
    data class ServiceLost(val serviceName: String) : NsdEvent
}

/**
 * Browses one mDNS service type, emitting [NsdEvent]s while collected.
 *
 * Production implementation is [AndroidNsdBrowser]; tests substitute a fake.
 * Browsing stops when the collector cancels. One active collection at a time —
 * the platform NSD stack only supports a single discovery per listener.
 */
interface NsdBrowser {
    fun events(serviceType: String): Flow<NsdEvent>
}

/**
 * Camera discovery over mDNS/NSD, mirroring the iOS Bonjour browse
 * (`ios/Runner/NativeCameraDiscovery.swift`): the ZR advertises `_ptp._tcp`,
 * and in camera-AP mode it always sits at a fixed address
 * ([NIKON_ZR_ACCESS_POINT_HOST]) with no mDNS required.
 */
class CameraDiscovery(private val browser: NsdBrowser) {
    /**
     * Emits the current set of reachable cameras, updating as services
     * resolve and disappear. Starts with an empty list; found-but-unresolved
     * services are not cameras yet (no host to connect to).
     */
    fun cameras(): Flow<List<DiscoveredCamera>> =
        browser.events(PTP_SERVICE_TYPE)
            .scan(emptyMap<String, DiscoveredCamera>()) { known, event ->
                when (event) {
                    is NsdEvent.ServiceResolved ->
                        if (isSupportedPtpIpDiscoveryHost(event.host)) {
                            known +
                                (event.serviceName to
                                    DiscoveredCamera(event.serviceName, event.host, event.port))
                        } else {
                            // A service can re-resolve after a network change. Do not leave its
                            // previous IPv4 address selectable if the new endpoint is unusable.
                            known - event.serviceName
                        }
                    is NsdEvent.ServiceLost -> known - event.serviceName
                    is NsdEvent.ServiceFound -> known
                }
            }
            .map { known -> known.values.sortedBy(DiscoveredCamera::name) }
            .distinctUntilChanged()

    companion object {
        /** mDNS service type the ZR advertises (same as the iOS browse). */
        const val PTP_SERVICE_TYPE: String = "_ptp._tcp."

        /** Standard PTP-IP TCP port (CIPA DC-005). */
        const val PTP_IP_PORT: Int = 15740

        /**
         * Fixed camera address when the phone joins the ZR's own access
         * point — mirrors `CameraDiscovery.nikonZRAccessPointHost` in the
         * shared Swift core.
         */
        const val NIKON_ZR_ACCESS_POINT_HOST: String = "192.168.1.1"

        /**
         * Prefix of the camera's own access-point SSID (e.g. `NIKON_ZR_01234`)
         * — mirrors `CameraWiFiSSID.nikonAccessPointPrefix` in the shared core.
         */
        const val NIKON_ZR_SSID_PREFIX: String = "NIKON_ZR_"

        /**
         * Whether an NSD-resolved host is usable by the current PTP-IP stack.
         *
         * The Swift PTP-IP facade only opens numeric IPv4 sockets. This mirrors the iOS
         * discovery path: Bonjour first limits results to `AF_INET`, then the shared
         * `CameraDiscovery.isDefaultScanIPv4` policy retains only the supported private
         * ranges. Keep the small parser here instead of crossing JNI: discovery must remain
         * safe and JVM-testable when the optional Swift library is not installed.
         *
         * The default shared policy deliberately excludes `10/8`, even though it is RFC 1918,
         * so mDNS discovery does not broaden the camera search beyond the iOS default scope.
         */
        internal fun isSupportedPtpIpDiscoveryHost(host: String): Boolean {
            val octets = host.split('.')
            if (octets.size != 4) return false

            val values =
                octets.map { octet ->
                    if (octet.isEmpty() || octet.any { !it.isDigit() }) return false
                    octet.toIntOrNull() ?: return false
                }
            if (values.any { it !in 0..255 }) return false

            return (values[0] == 172 && values[1] in 16..31) ||
                (values[0] == 192 && values[1] == 168)
        }

        /** Direct-host camera for the camera-AP case; no mDNS browse needed. */
        fun accessPointCamera(): DiscoveredCamera =
            DiscoveredCamera(
                name = "Nikon ZR",
                host = NIKON_ZR_ACCESS_POINT_HOST,
                port = PTP_IP_PORT,
            )
    }
}
