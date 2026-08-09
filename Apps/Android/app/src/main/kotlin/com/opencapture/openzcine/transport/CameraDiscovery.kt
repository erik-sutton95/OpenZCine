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
    /**
     * The device that says it is holding this camera, when one does. A held camera
     * is deliberately never probed — a PTP `Init` from a second initiator drops the
     * first one's session — but shielded is not the same as absent, and dropping it
     * from the list is what leaves an operator searching for a camera the app can
     * already name. See iOS `DiscoverySource.heldByAnotherDevice`.
     */
    val heldByDeviceName: String? = null,
) {
    /** Whether another device holds this camera, so connecting would take it from them. */
    val isHeldByAnotherDevice: Boolean
        get() = heldByDeviceName != null

    /** What the row says under the name — the holder if there is one, else nothing. */
    val heldByLabel: String?
        get() = heldByDeviceName?.takeIf(String::isNotBlank)?.let { "In use by \$it" }
}

/**
 * Platform-free mDNS browse events — the thin seam over [android.net.nsd.NsdManager]
 * so discovery bookkeeping stays testable on the JVM.
 */
sealed interface NsdEvent {
    /** A service appeared but has not resolved to a host yet. */
    data class ServiceFound(val serviceName: String) : NsdEvent

    /** A found service resolved to a reachable host/port. */
    data class ServiceResolved(
        val serviceName: String,
        val host: String,
        val port: Int,
        /** DNS-SD TXT attributes, UTF-8 decoded. The relay directory reads `ch` from here. */
        val attributes: Map<String, String> = emptyMap(),
    ) : NsdEvent

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
 * (`ios/Runner/NativeCameraDiscovery.swift`): the ZR advertises `_ptp._tcp`.
 * Camera-AP mode rediscovers on the live link after join — no fixed AP IP.
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
         * Prefix of the camera's own access-point SSID (e.g. `NIKON_ZR_01234`)
         * — mirrors `CameraWiFiSSID.nikonAccessPointPrefix` in the shared core.
         */
        const val NIKON_ZR_SSID_PREFIX: String = "NIKON_ZR_"

        /**
         * Non-dialable host key for an access-point setup with no learned address.
         * Mirrors Swift `CameraDiscovery.pendingAccessPointHostPrefix`.
         */
        const val PENDING_ACCESS_POINT_HOST_PREFIX: String = "ap:"

        fun pendingAccessPointHostKey(ssid: String?): String {
            val trimmed = ssid?.trim().orEmpty()
            return if (trimmed.isNotEmpty()) {
                PENDING_ACCESS_POINT_HOST_PREFIX + trimmed
            } else {
                PENDING_ACCESS_POINT_HOST_PREFIX + "pending"
            }
        }

        fun isAccessPointHostKey(host: String): Boolean =
            host.startsWith(PENDING_ACCESS_POINT_HOST_PREFIX)

        /**
         * The `a.b.c` of a dotted IPv4 address, or null when it is not one.
         *
         * Mirrors Swift `CameraDiscovery.subnetBase(for:)`. A /24 is an assumption, and a
         * deliberate one: it is what a sweep enumerates and what tells two Wi‑Fi setups apart.
         * The real prefix is a separate question, asked only when a diagnosis needs it.
         */
        fun subnetBase(host: String): String? {
            val trimmed = host.trim()
            if (!isSupportedPtpIpDiscoveryHost(trimmed)) return null
            return trimmed.substringBeforeLast('.').takeIf { it.count { ch -> ch == '.' } == 2 }
        }

        fun isDialableHost(host: String): Boolean {
            if (host.isBlank() || isAccessPointHostKey(host)) return false
            if (host.startsWith("usb:", ignoreCase = true)) return false
            return isSupportedPtpIpDiscoveryHost(host)
        }

        /**
         * Whether an NSD-resolved host is usable by the current PTP-IP stack.
         *
         * The Swift PTP-IP facade only opens numeric IPv4 sockets. This mirrors the iOS
         * discovery path: Bonjour first limits results to `AF_INET`, then the shared
         * `CameraDiscovery.isDefaultScanIPv4` policy retains only the supported private
         * ranges. Keep the small parser here instead of crossing JNI: discovery must remain
         * safe and JVM-testable when the optional Swift library is not installed.
         *
         * Mirrors the shared policy (`CameraDiscovery.swift isPrivateIPv4`): all three RFC 1918
         * ranges INCLUDING `10/8` — set and travel routers commonly hand out 10.x, and iOS
         * added it deliberately for exactly that. This filter previously excluded 10/8 (with a
         * comment claiming the core agreed, which had since stopped being true): a camera on a
         * 10.x router was discoverable on iOS and invisible on Android.
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

            return values[0] == 10 ||
                (values[0] == 172 && values[1] in 16..31) ||
                (values[0] == 192 && values[1] == 168)
        }

    }
}
