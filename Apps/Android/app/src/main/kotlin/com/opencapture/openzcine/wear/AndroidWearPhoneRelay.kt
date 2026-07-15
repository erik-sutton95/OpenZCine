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
import java.util.concurrent.atomic.AtomicInteger
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
    private val framePump =
        LatestFrameBackpressure<PreviewSnapshot>(
            dispatch = ::dispatchPreview,
            onDiscard = PreviewSnapshot::recycle,
        )

    private var active = false
    private var closed = false
    private var reachableWearNodes: Set<String> = emptySet()
    private var latestState: WatchRelayState? = null
    private var lastSentState: WatchRelayState? = null
    private var commandHandler: (suspend () -> WatchCommandResult)? = null
    private var lastPreviewAcceptedAtMillis = Long.MIN_VALUE

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
        framePump.invalidate()
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
        synchronized(lock) { latestState = state }
        if (state.connection == WatchConnectionState.DISCONNECTED || !state.feedLive) {
            // No stale preview may outlive a hidden/paused/command monitor.
            framePump.invalidate()
        }
        sendState(state, force = state.connection == WatchConnectionState.DISCONNECTED)
        updateHeartbeat(state)
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
     * callback. The small snapshot is then sent through a one-active,
     * one-replacement pump; slow links retain only the latest preview.
     */
    fun ingestPresentedFrame(frame: LiveFrame, bitmap: Bitmap) {
        val acceptedAt = SystemClock.elapsedRealtime()
        val shouldCapture =
            synchronized(lock) {
                if (!active || reachableWearNodes.isEmpty()) {
                    false
                } else if (acceptedAt - lastPreviewAcceptedAtMillis < PREVIEW_MIN_INTERVAL_MILLIS) {
                    false
                } else {
                    lastPreviewAcceptedAtMillis = acceptedAt
                    true
                }
            }
        if (!shouldCapture) return

        val preview = WearPreviewEncoder.snapshot(bitmap) ?: return
        val snapshot =
            PreviewSnapshot(
                bitmap = preview,
                timecode = WatchTimecode.unavailable(),
                isRecording = frame.isRecording,
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
        framePump.invalidate()
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
        val state =
            synchronized(lock) {
                if (!active) {
                    null
                } else {
                    reachableWearNodes = nodes
                    // A just-reachable watch needs the state even when unchanged.
                    lastSentState = null
                    latestState
                }
            }
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
                        WearPreviewEncoder.encode(snapshot.bitmap)?.let { jpeg ->
                            WatchRelayEnvelope.encode(
                                WatchRelayFrame(
                                    jpeg = jpeg,
                                    timecode = snapshot.timecode,
                                    isRecording = snapshot.isRecording,
                                ),
                            )
                        }
                    }
                } finally {
                    snapshot.recycle()
                }
            if (data == null || !isPreviewCurrent()) {
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
            val remaining = AtomicInteger(destinations.size)
            destinations.forEach { nodeID ->
                runCatching {
                    messageClient
                        .sendMessage(nodeID, WearRelayTransport.FRAME_PATH, data)
                        .addOnCompleteListener {
                            if (remaining.decrementAndGet() == 0) {
                                framePump.complete(dispatch.token)
                            }
                        }
                }.onFailure {
                    if (remaining.decrementAndGet() == 0) framePump.complete(dispatch.token)
                }
            }
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
    val timecode: WatchTimecode,
    val isRecording: Boolean,
) {
    fun recycle() {
        if (!bitmap.isRecycled) bitmap.recycle()
    }
}

/** Downscales and re-encodes a preview within the Data Layer-safe payload budget. */
private object WearPreviewEncoder {
    private const val MAX_WIDTH = 416

    fun snapshot(source: Bitmap): Bitmap? =
        try {
            val scale = minOf(1f, MAX_WIDTH.toFloat() / source.width.toFloat())
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

    fun encode(source: Bitmap): ByteArray? {
        val widths = intArrayOf(MAX_WIDTH, 336, 256)
        val qualities = intArrayOf(32, 26, 20)
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

private const val PREVIEW_MIN_INTERVAL_MILLIS: Long = 125L
private const val STATE_HEARTBEAT_MILLIS: Long = 2_000L
