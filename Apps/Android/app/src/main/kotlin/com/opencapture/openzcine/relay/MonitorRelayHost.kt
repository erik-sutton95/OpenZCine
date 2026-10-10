package com.opencapture.openzcine.relay

import com.opencapture.opencine.nikonwire.MonitorRelayWire
import com.opencapture.opencine.relay.RelayHostControl
import com.opencapture.opencine.relayruntime.RelaySocketHost
import com.opencapture.openzcine.core.RelayEncoderProfile
import kotlinx.coroutines.CoroutineScope

/** Original consumer spelling over the actual shared listener/peer/control owner. */
class MonitorRelayHost(scope: CoroutineScope, hostName: String, cameraName: String?) {
    private val owner = RelaySocketHost(scope, DeployedMonitorRelayCodec(), hostName, cameraName)
    var watcherPasscode: String
        get() = owner.watcherPasscode
        set(value) { owner.watcherPasscode = value }
    var allowsControlRequests: Boolean
        get() = owner.allowsControlRequests
        set(value) { owner.allowsControlRequests = value }
    var encoderProfile: RelayEncoderProfile
        get() = owner.encoderProfile
        set(value) { owner.encoderProfile = value }
    var onPeerCountChanged: ((Int) -> Unit)?
        get() = owner.onPeerCountChanged
        set(value) { owner.onPeerCountChanged = value }
    var onControlChanged: ((String?, String?) -> Unit)?
        get() = owner.onControlChanged
        set(value) { owner.onControlChanged = value }
    var onFailure: ((String) -> Unit)?
        get() = owner.onFailure
        set(value) { owner.onFailure = value }
    var onCommand: ((MonitorRelayWire.Command) -> Unit)? = null
    var onAdmittedCommand: ((MonitorRelayWire.Command, RelayHostControl.Admission) -> Unit)? = null
    init {
        owner.onCommand = { command, admission ->
            onAdmittedCommand?.invoke(command, admission) ?: onCommand?.invoke(command)
        }
    }
    val boundPort: Int get() = owner.boundPort
    fun start(preferredPort: Int = 0) = owner.start(preferredPort)
    fun admits(admission: RelayHostControl.Admission) = owner.admits(admission)
    fun retireSource() = owner.retireSource()
    suspend fun broadcastState(state: MonitorRelayWire.State) = owner.broadcastState(state)
    suspend fun broadcastFrame(metadata: MonitorRelayWire.FrameMetadata, image: ByteArray) = owner.broadcastFrame(metadata, image)
    suspend fun grantPendingControl() = owner.grantPendingControl()
    suspend fun declinePendingControl() = owner.declinePendingControl()
    suspend fun reclaimControl() = owner.reclaimControl()
    suspend fun stop() = owner.stop()
    suspend fun stop(notifyingViewers: String?) = owner.stop(notifyingViewers)
}
