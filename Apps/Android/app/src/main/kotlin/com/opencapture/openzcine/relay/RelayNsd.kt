package com.opencapture.openzcine.relay

import android.net.nsd.NsdManager
import android.net.nsd.NsdServiceInfo
import com.opencapture.openzcine.transport.NsdBrowser
import com.opencapture.openzcine.transport.NsdEvent
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.distinctUntilChanged
import kotlinx.coroutines.flow.map
import kotlinx.coroutines.flow.scan

/** A broadcast visible on the network, from the relay's own service type. */
data class RelayBroadcast(
    /** Service (device) name, as the watch list shows it. */
    val name: String,
    val host: String,
    val port: Int,
    /**
     * The camera host this broadcast serves (TXT `ch`) — the address discovery must not
     * PTP-probe while the broadcast stands. Android discovery is passive today; carried so a
     * future active path inherits the exclusion for free, matching iOS.
     */
    val servedCameraHost: String?,
)

/** Browses `_openzcine-mon._tcp` into a live broadcast list — the iOS relay browser's twin. */
class RelayBroadcastDirectory(private val browser: NsdBrowser) {
    fun broadcasts(): Flow<List<RelayBroadcast>> =
        browser.events(MonitorRelayWire.SERVICE_TYPE)
            .scan(emptyMap<String, RelayBroadcast>()) { known, event ->
                when (event) {
                    is NsdEvent.ServiceResolved ->
                        known +
                            (event.serviceName to
                                RelayBroadcast(
                                    name = event.serviceName,
                                    host = event.host,
                                    port = event.port,
                                    servedCameraHost =
                                        event.attributes[
                                            MonitorRelayWire.SERVED_CAMERA_TXT_KEY]
                                            ?.takeIf(String::isNotBlank),
                                ))
                    is NsdEvent.ServiceLost -> known - event.serviceName
                    is NsdEvent.ServiceFound -> known
                }
            }
            .map { known -> known.values.sortedBy(RelayBroadcast::name) }
            .distinctUntilChanged()
}

/**
 * Registers this device's broadcast over NSD with the served-camera TXT record — the Android
 * twin of the iOS listener's Bonjour advertisement. Not JVM-testable (framework types); the
 * protocol constants it advertises are pinned in `MonitorRelayWireTest`.
 */
class RelayAdvertiser(private val nsdManager: NsdManager) {
    private var listener: NsdManager.RegistrationListener? = null

    fun register(deviceName: String, port: Int, servedCameraHost: String?) {
        unregister()
        val info =
            NsdServiceInfo().apply {
                serviceName = deviceName
                serviceType = MonitorRelayWire.SERVICE_TYPE
                setPort(port)
                servedCameraHost
                    ?.takeIf(String::isNotBlank)
                    ?.let { setAttribute(MonitorRelayWire.SERVED_CAMERA_TXT_KEY, it) }
            }
        val registration =
            object : NsdManager.RegistrationListener {
                override fun onServiceRegistered(serviceInfo: NsdServiceInfo) {}

                override fun onRegistrationFailed(serviceInfo: NsdServiceInfo, errorCode: Int) {}

                override fun onServiceUnregistered(serviceInfo: NsdServiceInfo) {}

                override fun onUnregistrationFailed(
                    serviceInfo: NsdServiceInfo,
                    errorCode: Int,
                ) {}
            }
        listener = registration
        nsdManager.registerService(info, NsdManager.PROTOCOL_DNS_SD, registration)
    }

    fun unregister() {
        listener?.let { registration ->
            try {
                nsdManager.unregisterService(registration)
            } catch (_: IllegalArgumentException) {
                // Registration never completed; nothing to withdraw.
            }
        }
        listener = null
    }
}
