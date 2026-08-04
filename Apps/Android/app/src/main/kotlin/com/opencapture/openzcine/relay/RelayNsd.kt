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
    /**
     * False for a "camera in use" beacon (TXT `w=0`): a device holding a session without
     * sharing. Nothing to join — hide the row — but the served-camera exclusion applies
     * exactly as for a broadcast.
     */
    val isWatchable: Boolean = true,
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
                                    isWatchable =
                                        event.attributes[
                                            MonitorRelayWire.WATCHABLE_TXT_KEY] != "0",
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

    fun register(deviceName: String, port: Int, servedCameraHost: String?, watchable: Boolean = true) {
        unregister()
        val info =
            NsdServiceInfo().apply {
                serviceName = deviceName
                serviceType = MonitorRelayWire.SERVICE_TYPE
                setPort(port)
                servedCameraHost
                    ?.takeIf(String::isNotBlank)
                    ?.let { setAttribute(MonitorRelayWire.SERVED_CAMERA_TXT_KEY, it) }
                if (!watchable) setAttribute(MonitorRelayWire.WATCHABLE_TXT_KEY, "0")
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

/**
 * Answers the unicast presence check (TCP [MonitorRelayWire.PRESENCE_TCP_PORT]) with one JSON
 * line — the Android twin of the iOS `RelayPresenceServer`. On networks whose routers filter
 * multicast, this line is the only sighting other devices get of this one: their discovery
 * sweeps the subnet on this port when the advertisement never arrives.
 */
class RelayPresenceResponder {
    private var server: java.net.ServerSocket? = null
    @Volatile private var line: ByteArray? = null

    /** Publishes the device's current presence, or stops answering with a `null` name. */
    fun update(
        name: String?,
        watchable: Boolean = false,
        servedCameraHost: String? = null,
        relayPort: Int? = null,
    ) {
        if (name == null) {
            stop()
            return
        }
        line =
            MonitorRelayWire.relayPresenceLine(name, watchable, servedCameraHost, relayPort)
                .toByteArray(Charsets.UTF_8)
        startIfNeeded()
    }

    private fun startIfNeeded() {
        if (server != null) return
        val bound =
            try {
                java.net.ServerSocket(MonitorRelayWire.PRESENCE_TCP_PORT)
            } catch (_: java.io.IOException) {
                android.util.Log.w("RelayHost", "presence responder bind failed")
                return
            }
        server = bound
        Thread {
                while (!bound.isClosed) {
                    try {
                        bound.accept().use { socket ->
                            line?.let { socket.getOutputStream().write(it) }
                        }
                    } catch (_: java.io.IOException) {
                        return@Thread
                    }
                }
            }
            .apply {
                isDaemon = true
                name = "ozc-relay-presence"
                start()
            }
    }

    fun stop() {
        server?.close()
        server = null
        line = null
    }
}

/**
 * Advertises "this camera is in use" while this device holds a session WITHOUT sharing — the
 * Android twin of the iOS `CameraInUseBeacon`. Same service type and `ch=` key, flagged `w=0`:
 * every other device's probe exclusion engages exactly as for a broadcast, no list shows a
 * joinable row, and the bound port only closes whatever connects (nothing is served). The
 * unicast presence twin answers beside it for multicast-filtered networks.
 */
class CameraInUseBeacon(nsdManager: NsdManager, private val deviceName: String) {
    private val advertiser = RelayAdvertiser(nsdManager)
    private val presence = RelayPresenceResponder()
    private var socket: java.net.ServerSocket? = null

    fun start(servedCameraHost: String) {
        stop()
        if (servedCameraHost.isBlank()) return
        val server =
            try {
                java.net.ServerSocket(0)
            } catch (_: java.io.IOException) {
                return
            }
        socket = server
        Thread {
                while (!server.isClosed) {
                    try {
                        server.accept().close()
                    } catch (_: java.io.IOException) {
                        return@Thread
                    }
                }
            }
            .apply {
                isDaemon = true
                name = "ozc-in-use-beacon"
                start()
            }
        advertiser.register(deviceName, server.localPort, servedCameraHost, watchable = false)
        presence.update(deviceName, watchable = false, servedCameraHost = servedCameraHost)
    }

    fun stop() {
        advertiser.unregister()
        presence.update(null)
        socket?.close()
        socket = null
    }
}
