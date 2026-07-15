package com.opencapture.openzcine.wear

import android.content.Context
import android.graphics.Bitmap
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import com.google.android.gms.common.ConnectionResult
import com.google.android.gms.common.GoogleApiAvailability
import com.google.android.gms.wearable.CapabilityClient
import com.google.android.gms.wearable.CapabilityInfo
import com.google.android.gms.wearable.MessageClient
import com.google.android.gms.wearable.MessageEvent
import com.google.android.gms.wearable.Wearable
import com.opencapture.openzcine.LiveFramePreviewBaker
import com.opencapture.openzcine.core.LiveFrame
import com.opencapture.openzcine.wearrelay.WatchCommandResult
import com.opencapture.openzcine.wearrelay.WatchConnectionState
import com.opencapture.openzcine.wearrelay.WatchRelayCommand
import com.opencapture.openzcine.wearrelay.WatchRelayEnvelope
import com.opencapture.openzcine.wearrelay.WatchRelayFrame
import com.opencapture.openzcine.wearrelay.WatchRelayState
import com.opencapture.openzcine.wearrelay.WatchTimecode
import com.opencapture.openzcine.wearrelay.WearRelayTransport
import java.io.ByteArrayOutputStream
import kotlin.math.roundToInt
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.launch

/**
 * Foreground handheld relay for the Wear OS companion.
 *
 * This class receives already-presented monitor frames; it never subscribes to
 * a [com.opencapture.openzcine.core.LiveFrameSource]. Consequently it cannot
 * keep Nikon live view running after the monitor stops, backgrounds, enters
 * command/media mode, or leaves composition. The wearable gets only a bounded
 * JPEG preview, current monitor state, and the result of a guarded record
 * toggle routed back through the phone's existing [com.opencapture.openzcine.core.CameraSession].
 */
internal class AndroidWearPhoneRelay(context: Context) :
    MessageClient.OnMessageReceivedListener,
    CapabilityClient.OnCapabilityChangedListener {
    private val applicationContext = context.applicationContext
    private val messageClient by lazy { Wearable.getMessageClient(applicationContext) }
    private val capabilityClient by lazy { Wearable.getCapabilityClient(applicationContext) }
    private val lock = Any()
    private val handler = Handler(Looper.getMainLooper())
    private val relayScope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)
    private val previewPacing = AdaptiveWearPreviewPacing()
    private val framePump =
        LatestFrameBackpressure<PreviewSnapshot>(
            maximumInFlight = MAX_PREVIEWS_IN_FLIGHT,
            dispatch = ::dispatchPreview,
            onDiscard = PreviewSnapshot::recycle,
        )

    private var active = false
    private var closed = false
    private var reachableWearNodes: Set<String> = emptySet()
    private var latestState: WatchRelayState? = null
    private var lastSentState: WatchRelayState? = null
    private var commandHandler: (suspend () -> WatchCommandResult)? = null
    private val pendingPreviewAcks = mutableMapOf<Long, PendingPreviewAck>()

    /** Attaches the only camera command the relay can invoke. */
    fun setCommandHandler(handler: suspend () -> WatchCommandResult) {
        synchronized(lock) { commandHandler = handler }
    }

    /** Activates foreground-only Data Layer listeners when Play services is available. */
    fun activate() {
        if (!hasGooglePlayServices()) return
        val shouldRegister =
            synchronized(lock) {
                if (active || closed) {
                    false
                } else {
                    active = true
                    true
                }
            }
        if (!shouldRegister) return
        messageClient.addListener(this)
        capabilityClient.addListener(this, WearRelayTransport.WEAR_CAPABILITY)
        refreshReachableWearNodes()
    }

    /**
     * Removes Data Layer listeners when the phone monitor is no longer
     * foreground. [publishDisconnected] must run first while the relay is
     * still active, so an already-open watch has an explicit unavailable
     * state instead of retaining its last preview until expiry.
     */
    fun deactivate() {
        val shouldUnregister =
            synchronized(lock) {
                if (!active || closed) {
                    false
                } else {
                    active = false
                    reachableWearNodes = emptySet()
                    lastSentState = null
                    true
                }
            }
        if (!shouldUnregister) return
        handler.removeCallbacks(heartbeat)
        invalidatePreviewPump(resetPacing = true)
        if (hasGooglePlayServices()) {
            messageClient.removeListener(this)
            capabilityClient.removeListener(this, WearRelayTransport.WEAR_CAPABILITY)
        }
    }

    /**
     * Publishes one truthful monitor snapshot. Identical snapshots are
     * coalesced, with a small foreground heartbeat so a resumed watch can
     * reject its old state and receive proof that the phone monitor is live.
     */
    fun publishState(state: WatchRelayState) {
        val enrichedState =
            synchronized(lock) {
                retainWatchFrameMetadata(state, latestState).also { latestState = it }
            }
        if (enrichedState.connection == WatchConnectionState.DISCONNECTED || !enrichedState.feedLive) {
            // No stale preview may outlive a hidden/paused/command monitor.
            invalidatePreviewPump(resetPacing = false)
        }
        sendState(
            enrichedState,
            force = enrichedState.connection == WatchConnectionState.DISCONNECTED,
        )
        updateHeartbeat(enrichedState)
    }

    /** Sends the explicit unavailable state before foreground relay teardown. */
    fun publishDisconnected() {
        val disconnected =
            synchronized(lock) {
                latestState?.copy(
                    connection = WatchConnectionState.DISCONNECTED,
                    feedLive = false,
                )
            }
        if (disconnected != null) publishState(disconnected)
    }

    /**
     * Accepts a bitmap only from the existing on-screen frame presentation
     * callback. The small snapshot is then sent through the watchOS-parity
     * three-active, one-replacement pump; slow links retain only the latest
     * waiting preview.
     */
    fun ingestPresentedFrame(
        frame: LiveFrame,
        bitmap: Bitmap,
        previewBaker: LiveFramePreviewBaker?,
    ) {
        val profile = previewPacing.currentProfile()
        val shouldCapture = synchronized(lock) { active && reachableWearNodes.isNotEmpty() }
        if (!shouldCapture) return

        // The decoder owns a small bitmap ring, so retain only a bounded raw
        // copy here. Expensive display-effect baking waits until this frame
        // wins a backpressure slot in dispatchPreview; replaced frames never
        // pay a GPU readback.
        val preview = WearPreviewEncoder.snapshot(bitmap, profile.maximumWidth) ?: return
        updateLatestFrameMetadata(frame)
        val snapshot =
            PreviewSnapshot(
                bitmap = preview,
                previewBaker = previewBaker,
                timecode = frame.timecode?.toWatchTimecode() ?: WatchTimecode.unavailable(),
                isRecording = frame.isRecording,
                profile = profile,
            )
        val stillEligible =
            synchronized(lock) {
                active && reachableWearNodes.isNotEmpty() && latestState?.feedLive == true
            }
        if (stillEligible) {
            framePump.offer(snapshot)
        } else {
            snapshot.recycle()
        }
    }

    /** Unregisters all foreground listeners and makes late frame callbacks harmless. */
    fun close() {
        val shouldClose =
            synchronized(lock) {
                if (closed) {
                    false
                } else {
                    closed = true
                    active = false
                    reachableWearNodes = emptySet()
                    commandHandler = null
                    true
                }
            }
        if (!shouldClose) return
        handler.removeCallbacks(heartbeat)
        invalidatePreviewPump(resetPacing = true)
        if (hasGooglePlayServices()) {
            messageClient.removeListener(this)
            capabilityClient.removeListener(this, WearRelayTransport.WEAR_CAPABILITY)
        }
        relayScope.cancel()
    }

    override fun onCapabilityChanged(capabilityInfo: CapabilityInfo) {
        if (capabilityInfo.name != WearRelayTransport.WEAR_CAPABILITY) return
        updateReachableWearNodes(capabilityInfo.nodes.map { it.id }.toSet())
    }

    override fun onMessageReceived(messageEvent: MessageEvent) {
        val frameRequestID = WearRelayTransport.frameAckRequestID(messageEvent.path)
        if (frameRequestID != null) {
            acceptPreviewAcknowledgement(messageEvent.sourceNodeId, frameRequestID)
            return
        }
        val requestID = WearRelayTransport.commandRequestID(messageEvent.path) ?: return
        val isReachableForegroundRelay =
            synchronized(lock) {
                active && messageEvent.sourceNodeId in reachableWearNodes
            }
        if (!isReachableForegroundRelay) return
        val command =
            runCatching { WatchRelayEnvelope.decode(messageEvent.data) }.getOrNull()
                as? WatchRelayCommand
        val handler = synchronized(lock) { commandHandler }
        relayScope.launch {
            val result =
                if (command == WatchRelayCommand.TOGGLE_RECORD && handler != null) {
                    try {
                        handler.invoke()
                    } catch (_: Exception) {
                            WatchCommandResult(false, false, "unavailable")
                    }
                } else {
                    WatchCommandResult(false, false, "unavailable")
                }
            sendResult(messageEvent.sourceNodeId, requestID, result)
        }
    }

    private fun refreshReachableWearNodes() {
        capabilityClient
            .getCapability(WearRelayTransport.WEAR_CAPABILITY, CapabilityClient.FILTER_REACHABLE)
            .addOnSuccessListener { capability ->
                updateReachableWearNodes(capability.nodes.map { it.id }.toSet())
            }.addOnFailureListener {
                updateReachableWearNodes(emptySet())
            }
    }

    private fun updateReachableWearNodes(nodes: Set<String>) {
        var linkChanged = false
        val state =
            synchronized(lock) {
                if (!active) {
                    null
                } else {
                    linkChanged = reachableWearNodes != nodes
                    reachableWearNodes = nodes
                    // A just-reachable watch needs the state even when unchanged.
                    lastSentState = null
                    latestState
                }
            }
        if (linkChanged) invalidatePreviewPump(resetPacing = true)
        state?.let { sendState(it, force = true) }
    }

    private fun sendState(state: WatchRelayState, force: Boolean) {
        val data = runCatching { WatchRelayEnvelope.encode(state) }.getOrNull() ?: return
        val destinations =
            synchronized(lock) {
                if (!active || reachableWearNodes.isEmpty() || (!force && lastSentState == state)) {
                    emptySet()
                } else {
                    lastSentState = state
                    reachableWearNodes
                }
            }
        destinations.forEach { nodeID ->
            messageClient.sendMessage(nodeID, WearRelayTransport.STATE_PATH, data)
        }
    }

    private fun sendResult(nodeID: String, requestID: Long, result: WatchCommandResult) {
        val data = runCatching { WatchRelayEnvelope.encode(result) }.getOrNull() ?: return
        val shouldSend = synchronized(lock) { active }
        if (shouldSend) {
            messageClient.sendMessage(nodeID, WearRelayTransport.resultPath(requestID), data)
        }
    }

    private fun dispatchPreview(dispatch: LatestFrameBackpressure.Dispatch<PreviewSnapshot>) {
        relayScope.launch(Dispatchers.Default) {
            val snapshot = dispatch.value
            val data =
                try {
                    if (!isPreviewCurrent()) {
                        null
                    } else {
                        snapshot.encodeDisplayPreview()
                    }
                } finally {
                    snapshot.recycle()
                }
            if (data == null || !isPreviewCurrent() || !framePump.isActive(dispatch.token)) {
                framePump.complete(dispatch.token)
                return@launch
            }
            val destinations =
                synchronized(lock) {
                    if (active && latestState?.feedLive == true) reachableWearNodes else emptySet()
                }
            if (destinations.isEmpty()) {
                framePump.complete(dispatch.token)
                return@launch
            }
            val sentAtMillis = SystemClock.elapsedRealtime()
            val timeout = Runnable { expirePreviewAcknowledgement(dispatch.token) }
            val registered =
                synchronized(lock) {
                    if (
                        !active ||
                            latestState?.feedLive != true ||
                            !framePump.isActive(dispatch.token)
                    ) {
                        false
                    } else {
                        pendingPreviewAcks[dispatch.token] =
                            PendingPreviewAck(
                                sentAtMillis = sentAtMillis,
                                remainingNodeIDs = destinations.toMutableSet(),
                                timeout = timeout,
                            )
                        true
                    }
                }
            if (!registered) {
                framePump.complete(dispatch.token)
                return@launch
            }
            handler.postDelayed(timeout, PREVIEW_ACK_TIMEOUT_MILLIS)
            destinations.forEach { nodeID ->
                runCatching {
                    messageClient
                        .sendMessage(nodeID, WearRelayTransport.framePath(dispatch.token), data)
                        .addOnFailureListener {
                            rejectPreviewDestination(nodeID, dispatch.token)
                        }
                }.onFailure {
                    rejectPreviewDestination(nodeID, dispatch.token)
                }
            }
        }
    }

    private fun acceptPreviewAcknowledgement(nodeID: String, token: Long) {
        val completion =
            synchronized(lock) {
                val pending = pendingPreviewAcks[token]
                if (!active || pending == null || !pending.remainingNodeIDs.remove(nodeID)) {
                    null
                } else if (pending.remainingNodeIDs.isNotEmpty()) {
                    null
                } else {
                    pendingPreviewAcks.remove(token)
                    PreviewCompletion(
                        token = token,
                        timeout = pending.timeout,
                        roundTripMillis =
                            (SystemClock.elapsedRealtime() - pending.sentAtMillis).coerceAtLeast(1L),
                        degraded = pending.failed,
                    )
                }
            }
        completion?.let(::finishPreview)
    }

    private fun rejectPreviewDestination(nodeID: String, token: Long) {
        val completion =
            synchronized(lock) {
                val pending = pendingPreviewAcks[token]
                if (pending == null || !pending.remainingNodeIDs.remove(nodeID)) {
                    null
                } else {
                    pending.failed = true
                    if (pending.remainingNodeIDs.isNotEmpty()) {
                        null
                    } else {
                        pendingPreviewAcks.remove(token)
                        PreviewCompletion(token, pending.timeout, null, degraded = true)
                    }
                }
            }
        completion?.let(::finishPreview)
    }

    private fun expirePreviewAcknowledgement(token: Long) {
        val shouldComplete =
            synchronized(lock) {
                if (pendingPreviewAcks.remove(token) == null) {
                    false
                } else {
                    true
                }
            }
        if (!shouldComplete) return
        previewPacing.timedOut()
        framePump.complete(token)
    }

    private fun finishPreview(completion: PreviewCompletion) {
        handler.removeCallbacks(completion.timeout)
        if (completion.degraded) {
            previewPacing.timedOut()
        } else {
            previewPacing.acknowledge(requireNotNull(completion.roundTripMillis))
        }
        framePump.complete(completion.token)
    }

    private fun invalidatePreviewPump(resetPacing: Boolean) {
        val timeouts =
            synchronized(lock) {
                val pendingTimeouts = pendingPreviewAcks.values.map { it.timeout }
                pendingPreviewAcks.clear()
                pendingTimeouts
            }
        timeouts.forEach(handler::removeCallbacks)
        if (resetPacing) previewPacing.reset()
        framePump.invalidate()
    }

    private fun updateLatestFrameMetadata(frame: LiveFrame) {
        synchronized(lock) {
            val state = latestState ?: return
            latestState =
                state.copy(
                    timecode = frame.timecode?.toWatchTimecode() ?: state.timecode,
                    liveFPS =
                        frame.measuredFramesPerSecond
                            ?.takeIf { it.isFinite() && it > 0.0 }
                            ?.roundToInt()
                            ?.toString()
                            ?: state.liveFPS,
                )
        }
    }

    private fun isPreviewCurrent(): Boolean =
        synchronized(lock) {
            active && reachableWearNodes.isNotEmpty() && latestState?.feedLive == true
        }

    private fun updateHeartbeat(state: WatchRelayState) {
        handler.removeCallbacks(heartbeat)
        val shouldHeartbeat =
            synchronized(lock) {
                active && state.connection != WatchConnectionState.DISCONNECTED
            }
        if (shouldHeartbeat) handler.postDelayed(heartbeat, STATE_HEARTBEAT_MILLIS)
    }

    private val heartbeat =
        object : Runnable {
            override fun run() {
                val state = synchronized(lock) { latestState }
                if (state == null || state.connection == WatchConnectionState.DISCONNECTED) return
                sendState(state, force = true)
                val keepSending = synchronized(lock) { active }
                if (keepSending) handler.postDelayed(this, STATE_HEARTBEAT_MILLIS)
            }
        }

    private fun hasGooglePlayServices(): Boolean =
        GoogleApiAvailability.getInstance().isGooglePlayServicesAvailable(applicationContext) ==
            ConnectionResult.SUCCESS
}

/** A relay-owned, small bitmap snapshot that may safely outlive the feed's decode ring. */
private data class PreviewSnapshot(
    val bitmap: Bitmap,
    val previewBaker: LiveFramePreviewBaker?,
    val timecode: WatchTimecode,
    val isRecording: Boolean,
    val profile: WearPreviewProfile,
) {
    fun encodeDisplayPreview(): ByteArray? {
        val displayBitmap =
            previewBaker?.bakePreview(bitmap, profile.maximumWidth) ?: bitmap.takeIf {
                previewBaker == null
            }
        if (displayBitmap == null) return null
        return try {
            WearPreviewEncoder.encode(displayBitmap, profile)?.let { jpeg ->
                WatchRelayEnvelope.encode(
                    WatchRelayFrame(
                        jpeg = jpeg,
                        timecode = timecode,
                        isRecording = isRecording,
                    ),
                )
            }
        } finally {
            if (displayBitmap !== bitmap && !displayBitmap.isRecycled) displayBitmap.recycle()
        }
    }

    fun recycle() {
        if (!bitmap.isRecycled) bitmap.recycle()
    }
}

private data class PendingPreviewAck(
    val sentAtMillis: Long,
    val remainingNodeIDs: MutableSet<String>,
    val timeout: Runnable,
    var failed: Boolean = false,
)

private data class PreviewCompletion(
    val token: Long,
    val timeout: Runnable,
    val roundTripMillis: Long?,
    val degraded: Boolean,
)

private fun com.opencapture.openzcine.core.LiveFrameTimecode.toWatchTimecode(): WatchTimecode =
    WatchTimecode(
        on = on,
        hour = hour,
        minute = minute,
        second = second,
        frame = frame,
    )

/** Downscales and re-encodes a preview within the Data Layer-safe payload budget. */
private object WearPreviewEncoder {
    fun snapshot(source: Bitmap, maximumWidth: Int): Bitmap? =
        try {
            val scale = minOf(1f, maximumWidth.toFloat() / source.width.toFloat())
            val width = (source.width * scale).toInt().coerceAtLeast(1)
            val height = (source.height * scale).toInt().coerceAtLeast(1)
            if (width == source.width && height == source.height) {
                source.copy(source.config ?: Bitmap.Config.ARGB_8888, false)
            } else {
                Bitmap.createScaledBitmap(source, width, height, true)
            }
        } catch (_: OutOfMemoryError) {
            null
        }

    fun encode(source: Bitmap, profile: WearPreviewProfile): ByteArray? {
        val widths =
            intArrayOf(profile.maximumWidth, 336, 256)
                .map { minOf(source.width, it) }
                .distinct()
        val qualities = intArrayOf(profile.jpegQuality, profile.jpegQuality - 6, 20).distinct()
        for (width in widths) {
            val candidate = scaledCopy(source, width) ?: continue
            try {
                for (quality in qualities) {
                    val bytes = ByteArrayOutputStream().use { output ->
                        if (!candidate.compress(Bitmap.CompressFormat.JPEG, quality, output)) return@use null
                        output.toByteArray()
                    }
                    if (bytes != null && bytes.size <= WatchRelayEnvelope.MAX_PREVIEW_JPEG_BYTES) {
                        return bytes
                    }
                }
            } finally {
                if (candidate !== source && !candidate.isRecycled) candidate.recycle()
            }
        }
        return null
    }

    private fun scaledCopy(source: Bitmap, targetWidth: Int): Bitmap? =
        try {
            if (source.width <= targetWidth) {
                source
            } else {
                val targetHeight = (source.height * targetWidth.toFloat() / source.width.toFloat()).toInt()
                Bitmap.createScaledBitmap(source, targetWidth, targetHeight.coerceAtLeast(1), true)
            }
        } catch (_: OutOfMemoryError) {
            null
        }
}

private const val PREVIEW_ACK_TIMEOUT_MILLIS: Long = 2_000L
private const val MAX_PREVIEWS_IN_FLIGHT: Int = 3
private const val STATE_HEARTBEAT_MILLIS: Long = 2_000L
