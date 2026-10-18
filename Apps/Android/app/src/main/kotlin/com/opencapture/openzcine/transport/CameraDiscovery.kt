package com.opencapture.openzcine.transport

import com.opencapture.opencine.nikon.NikonHosts
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
        get() = heldByDeviceName?.takeIf(String::isNotBlank)?.let { "In use by $it" }
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
                        // The Swift PTP-IP facade opens numeric IPv4 sockets only, and discovery
                        // keeps the private ranges (Swift `isDefaultScanIPv4`, 10/8 included).
                        if (NikonHosts.isPrivateIPv4(event.host)) {
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
         * The host a saved wireless setup may hand the dialer: a live discovery first, else
         * the record's own host when that is a real address. The pending access-point key is
         * NEVER a dial target — it is a bookmark meaning "rediscover on the live link after
         * join", and dialling it surfaced the transport's numeric-IPv4 refusal instead of a
         * connect (#327). Null means nothing is dialable yet: discover after join, or fail
         * saying the camera was not found.
         */
        fun dialableSavedHost(recordHost: String, discoveredHost: String?): String? =
            discoveredHost?.takeIf(NikonHosts::isDialableHost) ?: recordHost.takeIf(NikonHosts::isDialableHost)
    }
}
