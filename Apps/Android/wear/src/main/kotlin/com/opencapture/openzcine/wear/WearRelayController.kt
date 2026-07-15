package com.opencapture.openzcine.wear

import android.content.Context
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import androidx.compose.runtime.Stable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import com.google.android.gms.common.ConnectionResult
import com.google.android.gms.common.GoogleApiAvailability
import com.google.android.gms.wearable.CapabilityClient
import com.google.android.gms.wearable.CapabilityInfo
import com.google.android.gms.wearable.MessageClient
import com.google.android.gms.wearable.MessageEvent
import com.google.android.gms.wearable.Wearable
import com.opencapture.openzcine.wearrelay.WatchCommandResult
import com.opencapture.openzcine.wearrelay.WatchConnectionState
import com.opencapture.openzcine.wearrelay.WatchRecordState
import com.opencapture.openzcine.wearrelay.WatchRelayCommand
import com.opencapture.openzcine.wearrelay.WatchRelayEnvelope
import com.opencapture.openzcine.wearrelay.WatchRelayFrame
import com.opencapture.openzcine.wearrelay.WatchRelayState
import com.opencapture.openzcine.wearrelay.WearRelayTransport

/**
 * Foreground Wear OS client for the phone-owned relay.
 *
 * It has no `WearableListenerService` by design: messages are useful only
 * while this monitor is visible, and a background listener could retain stale
 * preview/state or imply the watch can control a camera while the phone relay
 * is unavailable. On every foreground start it clears cached state, waits for
 * the phone's heartbeat, and expires a state snapshot that stops refreshing.
 */
@Stable
internal class WearRelayController(context: Context) :
    MessageClient.OnMessageReceivedListener,
    CapabilityClient.OnCapabilityChangedListener {
    private val applicationContext = context.applicationContext
    private val messageClient by lazy { Wearable.getMessageClient(applicationContext) }
    private val capabilityClient by lazy { Wearable.getCapabilityClient(applicationContext) }
    private val handler = Handler(Looper.getMainLooper())

    var state: WatchRelayState? by mutableStateOf(null)
        private set
    var frame: Bitmap? by mutableStateOf(null)
        private set
    var frameTimecode by mutableStateOf<com.opencapture.openzcine.wearrelay.WatchTimecode?>(null)
        private set
    var phoneReachable: Boolean by mutableStateOf(false)
        private set
    var isSendingCommand: Boolean by mutableStateOf(false)
        private set
    var commandMessage: String? by mutableStateOf(null)
        private set

    private var active = false
    private var closed = false
    private val stateFreshness = WatchRelayFreshness(STATE_FRESHNESS_MILLIS)
    private var reachablePhoneNodes: Set<String> = emptySet()
    private var preferredPhoneNodeID: String? = null
    private var pendingCommand: PendingWearCommand? = null
    private var commandToken = 0L

    /** Begins foreground-only listeners and requires a fresh phone state. */
    fun start() {
        if (!hasGooglePlayServices() || active || closed) return
        active = true
        phoneReachable = false
        reachablePhoneNodes = emptySet()
        preferredPhoneNodeID = null
        commandMessage = null
        clearCachedPresentation()
        messageClient.addListener(this)
        capabilityClient.addListener(this, WearRelayTransport.PHONE_CAPABILITY)
        refreshReachablePhones()
    }

    /** Stops all listeners while the watch surface is not visible. */
    fun stop() {
        if (!active) return
        active = false
        handler.removeCallbacks(stateExpiry)
        handler.removeCallbacks(commandTimeout)
        isSendingCommand = false
        pendingCommand = null
        commandMessage = null
        phoneReachable = false
        reachablePhoneNodes = emptySet()
        preferredPhoneNodeID = null
        if (hasGooglePlayServices()) {
            messageClient.removeListener(this)
            capabilityClient.removeListener(this, WearRelayTransport.PHONE_CAPABILITY)
        }
        // A capability only proves the app is installed/reachable; never let
        // the next resume use that fact as camera/monitor truth.
        clearCachedPresentation()
    }

    /** Permanently tears down the Activity-owned foreground client. */
    fun close() {
        if (closed) return
        stop()
        closed = true
    }

    /** Sends the one supported command only if fresh state proves it is safe. */
    fun sendToggleRecord() {
        val snapshot = state
        val nodeID = preferredPhoneNodeID
        if (
            !active ||
                !phoneReachable ||
                !stateFreshness.isFresh(SystemClock.elapsedRealtime()) ||
                snapshot == null ||
                snapshot.connection != WatchConnectionState.CONNECTED ||
                !snapshot.feedLive ||
                isSendingCommand ||
                nodeID == null
        ) {
            return
        }
        val data = runCatching { WatchRelayEnvelope.encode(WatchRelayCommand.TOGGLE_RECORD) }.getOrNull()
            ?: return
        isSendingCommand = true
        commandMessage = null
        commandToken += 1
        val token = commandToken
        pendingCommand = PendingWearCommand(nodeID, token)
        messageClient
            .sendMessage(nodeID, WearRelayTransport.commandPath(token), data)
            .addOnFailureListener {
                if (token == commandToken) rejectPendingCommand("Phone monitor unavailable.")
            }
        handler.postDelayed(commandTimeout, COMMAND_TIMEOUT_MILLIS)
    }

    override fun onCapabilityChanged(capabilityInfo: CapabilityInfo) {
        if (capabilityInfo.name != WearRelayTransport.PHONE_CAPABILITY) return
        updateReachablePhones(capabilityInfo.nodes.map { it.id }.toSet())
    }

    override fun onMessageReceived(messageEvent: MessageEvent) {
        if (!active) return
        when (messageEvent.path) {
            WearRelayTransport.STATE_PATH -> {
                if (messageEvent.sourceNodeId !in reachablePhoneNodes) return
                val snapshot = decode<WatchRelayState>(messageEvent.data) ?: return
                preferredPhoneNodeID = messageEvent.sourceNodeId
                updateState(snapshot)
            }
            WearRelayTransport.FRAME_PATH -> {
                if (messageEvent.sourceNodeId != preferredPhoneNodeID) return
                val relayFrame = decode<WatchRelayFrame>(messageEvent.data) ?: return
                // State arrives as a heartbeat first. Ignore an unordered or
                // late frame rather than making a stale camera look live.
                if (
                    !stateFreshness.isFresh(SystemClock.elapsedRealtime()) ||
                        state?.connection != WatchConnectionState.CONNECTED ||
                        state?.feedLive != true
                ) {
                    return
                }
                val image = BitmapFactory.decodeByteArray(relayFrame.jpeg, 0, relayFrame.jpeg.size) ?: return
                frame = image
                frameTimecode = relayFrame.timecode
            }
            else -> {
                val requestID = WearRelayTransport.resultRequestID(messageEvent.path) ?: return
                val result = decode<WatchCommandResult>(messageEvent.data) ?: return
                acceptCommandResult(messageEvent.sourceNodeId, requestID, result)
            }
        }
    }

    private fun refreshReachablePhones() {
        capabilityClient
            .getCapability(WearRelayTransport.PHONE_CAPABILITY, CapabilityClient.FILTER_REACHABLE)
            .addOnSuccessListener { capability ->
                updateReachablePhones(capability.nodes.map { it.id }.toSet())
            }.addOnFailureListener {
                updateReachablePhones(emptySet())
            }
    }

    private fun updateReachablePhones(nodes: Set<String>) {
        if (!active) return
        reachablePhoneNodes = nodes
        phoneReachable = nodes.isNotEmpty()
        if (preferredPhoneNodeID !in nodes) preferredPhoneNodeID = nodes.minOrNull()
        if (!phoneReachable) clearCachedPresentation()
    }

    private fun updateState(snapshot: WatchRelayState) {
        state = snapshot
        stateFreshness.accept(SystemClock.elapsedRealtime())
        if (snapshot.connection != WatchConnectionState.CONNECTED || !snapshot.feedLive) {
            frame = null
            frameTimecode = null
        }
        handler.removeCallbacks(stateExpiry)
        scheduleStateExpiry()
    }

    private fun acceptCommandResult(nodeID: String, requestID: Long, result: WatchCommandResult) {
        // The portable protocol has no command identifier, so only one request
        // may be pending and its result must come from the exact destination.
        // A late/mismatched response cannot alter a newer command's UI state.
        if (!isSendingCommand || pendingCommand?.matches(nodeID, requestID) != true) return
        handler.removeCallbacks(commandTimeout)
        isSendingCommand = false
        pendingCommand = null
        commandMessage = result.error
        state =
            state?.copy(
                recordState = if (result.isRecording) WatchRecordState.RECORDING else WatchRecordState.STANDBY,
                isRecording = result.isRecording,
            )
    }

    private fun rejectPendingCommand(message: String) {
        handler.removeCallbacks(commandTimeout)
        isSendingCommand = false
        pendingCommand = null
        commandMessage = message
    }

    private fun clearCachedPresentation() {
        state = null
        frame = null
        frameTimecode = null
        stateFreshness.clear()
    }

    private val stateExpiry =
        Runnable {
            if (stateFreshness.isFresh(SystemClock.elapsedRealtime())) {
                scheduleStateExpiry()
            } else {
                clearCachedPresentation()
            }
        }

    private fun scheduleStateExpiry() {
        val remaining = stateFreshness.remainingMillis(SystemClock.elapsedRealtime()) ?: return
        handler.postDelayed(stateExpiry, remaining)
    }

    private val commandTimeout =
        Runnable {
            if (isSendingCommand) rejectPendingCommand("Phone did not confirm the record command.")
        }

    private inline fun <reified Payload> decode(data: ByteArray): Payload? =
        runCatching { WatchRelayEnvelope.decode(data) as? Payload }.getOrNull()

    private fun hasGooglePlayServices(): Boolean =
        GoogleApiAvailability.getInstance().isGooglePlayServicesAvailable(applicationContext) ==
            ConnectionResult.SUCCESS
}

private const val STATE_FRESHNESS_MILLIS: Long = 6_000L
private const val COMMAND_TIMEOUT_MILLIS: Long = 5_000L
