package com.opencapture.openzcine.relay

import android.net.nsd.NsdManager
import com.opencapture.opencine.nikonwire.MonitorRelayWire
import com.opencapture.opencine.relayruntime.RelayInUseBeacon
import com.opencapture.opencine.relayruntime.RelayPassiveListener
import com.opencapture.opencine.relayruntime.RelayServiceAdvertiser
import com.opencapture.opencine.relayruntime.RelayServiceDirectory
import com.opencapture.opencine.relayruntime.RelayServiceEvent
import com.opencapture.openzcine.transport.NsdBrowser
import com.opencapture.openzcine.transport.NsdEvent
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.map

typealias RelayBroadcast = com.opencapture.opencine.relay.RelayBroadcast

/** Existing passive SDK events and exact deployed profile compose the shared listing owner. */
class RelayBroadcastDirectory(private val browser: NsdBrowser) {
    private val owner = RelayServiceDirectory(DeployedMonitorRelayCodec().profile)
    fun broadcasts(): Flow<List<RelayBroadcast>> = owner.broadcasts(
        browser.events(MonitorRelayWire.SERVICE_TYPE).map { event ->
            when (event) {
                is NsdEvent.ServiceFound -> RelayServiceEvent.Found(event.serviceName)
                is NsdEvent.ServiceLost -> RelayServiceEvent.Lost(event.serviceName)
                is NsdEvent.ServiceResolved -> RelayServiceEvent.Resolved(
                    event.serviceName, event.host, event.port, event.attributes,
                )
            }
        }
    )
}

/** Native NSD registration/lifetime lives in the shared SDK leaf. */
class RelayAdvertiser(nsdManager: NsdManager) {
    private val owner = RelayServiceAdvertiser(nsdManager)
    fun register(deviceName: String, port: Int, servedCameraHost: String?, watchable: Boolean = true) {
        owner.register(DeployedMonitorRelayCodec().profile, deviceName, port, servedCameraHost, watchable)
    }
    fun unregister() { owner.unregister() }
}

/** Only the exact deployed presence-line encoding and original log remain app-composed. */
class RelayPresenceResponder {
    private val owner = RelayPassiveListener(port = MonitorRelayWire.PRESENCE_TCP_PORT,
        onBindFailure = { android.util.Log.w("RelayHost", "presence responder bind failed") })
    fun update(name: String?, watchable: Boolean = false, servedCameraHost: String? = null, relayPort: Int? = null) {
        owner.update(name?.let {
            MonitorRelayWire.relayPresenceLine(it, watchable, servedCameraHost, relayPort).toByteArray(Charsets.UTF_8)
        })
    }
    fun stop() { owner.stop() }
}

/** SDK composition and deployed names only; shield accept/stop/presence are shared. */
class CameraInUseBeacon(nsdManager: NsdManager, private val deviceName: String) {
    private val owner = RelayInUseBeacon(nsdManager, DeployedMonitorRelayCodec().profile, "$deviceName in-use",
        onPresenceBindFailure = { android.util.Log.w("RelayHost", "presence responder bind failed") })
    fun start(servedCameraHost: String) {
        owner.start(servedCameraHost,
            MonitorRelayWire.relayPresenceLine(deviceName, false, servedCameraHost).toByteArray(Charsets.UTF_8))
    }
    fun stop() { owner.stop() }
}
