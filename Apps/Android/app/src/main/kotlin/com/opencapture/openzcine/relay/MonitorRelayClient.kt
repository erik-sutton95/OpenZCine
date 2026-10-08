package com.opencapture.openzcine.relay

import com.opencapture.opencine.nikonwire.MonitorRelayWire
import com.opencapture.opencine.relay.RelayPeerHello
import com.opencapture.opencine.relayruntime.RelayClientEvent
import com.opencapture.opencine.relayruntime.RelaySocketClient
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.map

/** Typed facade preserving original event payloads over the shared bounded socket owner. */
class MonitorRelayClient(scope: CoroutineScope) {
    sealed interface Event {
        data class Connected(val hostName: String, val cameraName: String?) : Event
        data class StateReceived(val state: MonitorRelayWire.State) : Event
        data class FrameReceived(val metadata: MonitorRelayWire.FrameMetadata, val image: ByteArray) : Event
        data class ControlChanged(val token: MonitorRelayWire.ControlToken) : Event
        data class JoinDenied(val denied: MonitorRelayWire.JoinDenied) : Event
        data class Closed(val reason: String?) : Event
    }
    private val owner = RelaySocketClient(scope, DeployedMonitorRelayCodec())
    val events: Flow<Event> = owner.events.map { event ->
        when (event) {
            is RelayClientEvent.Connected -> Event.Connected(event.hello.hostName, event.hello.cameraName)
            is RelayClientEvent.StateReceived -> Event.StateReceived(event.state)
            is RelayClientEvent.FrameReceived -> Event.FrameReceived(event.metadata, event.image)
            is RelayClientEvent.ControlChanged -> Event.ControlChanged(event.control)
            is RelayClientEvent.JoinDenied -> Event.JoinDenied(event.denied)
            is RelayClientEvent.Closed -> Event.Closed(event.reason)
        }
    }
    fun connect(host: String, port: Int, deviceName: String, passcode: String?,
        codecs: List<String>? = null, watcherId: String? = null) {
        owner.connect(host, port, RelayPeerHello(MonitorRelayWire.VERSION, deviceName,
            passcode = passcode, codecs = codecs, watcherID = watcherId))
    }
    fun requestControl() { owner.requestControl() }
    fun releaseControl() { owner.releaseControl() }
    fun sendCommand(command: MonitorRelayWire.Command) { owner.sendCommand(command) }
    suspend fun stop() = owner.stop()
}
