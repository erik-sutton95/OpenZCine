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
import com.opencapture.opencine.nikon.CameraSession
import com.opencapture.opencine.nikon.CameraCommandAdmission
import com.opencapture.opencine.nikon.LiveFrame
import com.opencapture.opencine.nikon.LiveFrameTimecode
import com.opencapture.opencine.relay.RelayPreviewPacingPolicy
import com.opencapture.opencine.relay.RelayPreviewProfile
import com.opencapture.opencine.runtime.MonitorBitmapPreviewBaker
import com.opencapture.opencine.runtime.MonitorBitmapPreviewEncoder
import com.opencapture.opencine.runtime.MonitorBitmapPreviewEncoding
import com.opencapture.opencine.watchruntime.WatchMessagePort
import com.opencapture.opencine.watchruntime.WatchPhoneOwner
import com.opencapture.opencine.watchruntime.WatchPhonePolicy
import com.opencapture.opencine.watchruntime.WatchRelayAction
import com.opencapture.opencine.watchruntime.WatchRuntimeScheduler
import com.opencapture.opencine.watchruntime.WatchScheduled
import com.opencapture.openzcine.wearrelay.DeployedWearRelayCodec
import com.opencapture.openzcine.wearrelay.WatchCommandResult
import com.opencapture.openzcine.wearrelay.WatchConnectionState
import com.opencapture.openzcine.wearrelay.WatchRelayEnvelope
import com.opencapture.openzcine.wearrelay.WatchRelayFrame
import com.opencapture.openzcine.wearrelay.WatchRelayState
import com.opencapture.openzcine.wearrelay.WatchTimecode
import com.opencapture.openzcine.wearrelay.WearRelayTransport
import java.util.UUID
import java.util.concurrent.atomic.AtomicReference
import kotlin.math.roundToInt
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.withContext

/** Google SDK and calibrated native picture adapters over the actual shared phone runtime. */
internal class AndroidWearPhoneRelay(context: Context) {
    private val applicationContext = context.applicationContext
    private val messageClient by lazy { Wearable.getMessageClient(applicationContext) }
    private val capabilityClient by lazy { Wearable.getCapabilityClient(applicationContext) }
    private val handler = Handler(Looper.getMainLooper())
    private val relayScope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)
    private var gate: AtomicReference<UUID?>? = null
    private var messageListener: MessageClient.OnMessageReceivedListener? = null
    private var capabilityListener: CapabilityClient.OnCapabilityChangedListener? = null
    @Volatile private var boundSource: CameraSession? = null
    private var commandHandler: (suspend () -> WatchCommandResult)? = null
    private var admittedCommandHandler:
        (suspend (CameraSession, CameraCommandAdmission) -> WatchCommandResult)? = null
    private val owner = WatchPhoneOwner(
        scope = relayScope, codec = DeployedWearRelayCodec(), scheduler = object : WatchRuntimeScheduler {
            override fun nowMillis(): Long = SystemClock.elapsedRealtime()
            override fun schedule(afterMillis: Long, action: () -> Unit): WatchScheduled {
                val runnable = Runnable(action)
                handler.postDelayed(runnable, afterMillis)
                return WatchScheduled { handler.removeCallbacks(runnable) }
            }
        }, messages = WatchMessagePort { node, path, bytes, failure ->
            messageClient.sendMessage(node, path, bytes).addOnFailureListener { failure?.invoke() }
        }, policy = WatchPhonePolicy(pacing = RelayPreviewPacingPolicy(
            profiles = listOf(RelayPreviewProfile(416, 32), RelayPreviewProfile(336, 28), RelayPreviewProfile(256, 24)),
            roundTripThresholds = listOf(0.2, 0.35), initialIndex = 1, sampleUnitsPerSecond = 1_000.0)),
        encode = { preview: PreviewSnapshot, _ -> withContext(Dispatchers.Default) { preview.encodeDisplayPreview() } },
        discard = PreviewSnapshot::recycle)
    init {
        owner.onSourceRetired = { gate?.set(it) }
        owner.onCommand = { action, admission ->
            val source = boundSource
            if (action == WatchRelayAction.TOGGLE_RECORD && owner.admits(admission) && source != null) {
                val nativeAdmission = CameraCommandAdmission(source) {
                    boundSource === source && owner.admits(admission)
                }
                admittedCommandHandler?.invoke(source, nativeAdmission)
                    ?: commandHandler?.invoke() ?: WatchCommandResult(false, false, "unavailable")
            } else WatchCommandResult(false, false, "unavailable")
        }
    }
    fun bindSource(source: CameraSession?) {
        if (boundSource === source) return
        boundSource = source
        owner.retireSource(clearState = true)
    }
    fun setCommandHandler(handler: suspend () -> WatchCommandResult) { commandHandler = handler }
    fun setAdmittedCommandHandler(handler: suspend (CameraSession, CameraCommandAdmission) -> WatchCommandResult) {
        admittedCommandHandler = handler
    }
    fun activate() {
        if (!hasGooglePlayServices() || !owner.activate()) return
        val gate = AtomicReference<UUID?>(owner.source)
        this.gate = gate
        val message = MessageClient.OnMessageReceivedListener { event: MessageEvent ->
            val window = gate.get() ?: return@OnMessageReceivedListener
            val node = event.sourceNodeId
            val path = event.path
            val bytes = event.data.copyOf()
            operator { owner.receive(node, path, bytes, window) }
        }
        val capability = CapabilityClient.OnCapabilityChangedListener { info: CapabilityInfo ->
            if (info.name == WearRelayTransport.WEAR_CAPABILITY) {
                val window = gate.get() ?: return@OnCapabilityChangedListener
                val nodes = info.nodes.map { it.id }.toSet()
                operator { owner.acceptNodes(nodes, window) }
            }
        }
        messageListener = message
        capabilityListener = capability
        messageClient.addListener(message)
        capabilityClient.addListener(capability, WearRelayTransport.WEAR_CAPABILITY)
        capabilityClient.getCapability(WearRelayTransport.WEAR_CAPABILITY, CapabilityClient.FILTER_REACHABLE)
            .addOnSuccessListener { info ->
                val window = gate.get() ?: return@addOnSuccessListener
                val nodes = info.nodes.map { it.id }.toSet()
                operator { owner.acceptNodes(nodes, window) }
            }.addOnFailureListener {
                val window = gate.get() ?: return@addOnFailureListener
                operator { owner.acceptNodes(emptySet(), window) }
            }
    }
    fun deactivate() {
        gate?.set(null)
        gate = null
        owner.deactivate()
        if (hasGooglePlayServices()) {
            messageListener?.let(messageClient::removeListener)
            capabilityListener?.let { capabilityClient.removeListener(it, WearRelayTransport.WEAR_CAPABILITY) }
        }
        messageListener = null
        capabilityListener = null
    }
    fun close() {
        deactivate()
        owner.close()
        commandHandler = null
        admittedCommandHandler = null
        boundSource = null
        relayScope.cancel()
    }
    fun publishState(state: WatchRelayState) {
        owner.publishState(retainWatchFrameMetadata(state, owner.currentState))
    }
    fun publishDisconnected() {
        owner.currentState?.copy(connection = WatchConnectionState.DISCONNECTED, feedLive = false)?.let(::publishState)
    }
    fun ingestPresentedFrame(source: CameraSession, frame: LiveFrame, bitmap: Bitmap, previewBaker: MonitorBitmapPreviewBaker?) {
        if (source !== boundSource || !owner.canPreview) return
        val window = owner.source
        val profile = owner.currentProfile()
        val preview = MonitorBitmapPreviewEncoder.snapshot(bitmap, profile.maximumWidth) ?: return
        if (source !== boundSource || owner.source != window || !owner.canPreview) {
            if (!preview.isRecycled) preview.recycle()
            return
        }
        owner.currentState?.let { state ->
            owner.updateFrameState(state.copy(timecode = frame.timecode?.toWatchTimecode() ?: state.timecode,
                liveFPS = frame.measuredFramesPerSecond?.takeIf { it.isFinite() && it > 0.0 }?.roundToInt()?.toString() ?: state.liveFPS))
        }
        owner.ingestPreview(PreviewSnapshot(preview, previewBaker,
            frame.timecode?.toWatchTimecode() ?: WatchTimecode.unavailable(), frame.isRecording, profile), window)
    }
    private fun operator(action: () -> Unit) {
        if (Looper.myLooper() == handler.looper) action() else handler.post { action() }
    }
    private fun hasGooglePlayServices(): Boolean =
        GoogleApiAvailability.getInstance().isGooglePlayServicesAvailable(applicationContext) == ConnectionResult.SUCCESS
}

/** Bounded native image port. Effects remain in the already shared MonitorBitmapPreviewBaker. */
private data class PreviewSnapshot(val bitmap: Bitmap, val previewBaker: MonitorBitmapPreviewBaker?,
    val timecode: WatchTimecode, val isRecording: Boolean, val profile: RelayPreviewProfile) {
    fun encodeDisplayPreview(): WatchRelayFrame? {
        val display = previewBaker?.bakePreview(bitmap, profile.maximumWidth) ?: bitmap.takeIf { previewBaker == null }
        if (display == null) return null
        return try {
            MonitorBitmapPreviewEncoder.encode(display, MonitorBitmapPreviewEncoding(profile.maximumWidth,
                profile.qualityPercent, fallbackWidths = listOf(336, 256), qualityReduction = 6, minimumQuality = 20,
                maximumEncodedBytes = WatchRelayEnvelope.MAX_PREVIEW_JPEG_BYTES))?.let {
                WatchRelayFrame(jpeg = it, timecode = timecode, isRecording = isRecording)
            }
        } finally { if (display !== bitmap && !display.isRecycled) display.recycle() }
    }
    fun recycle() { if (!bitmap.isRecycled) bitmap.recycle() }
}
private fun LiveFrameTimecode.toWatchTimecode(): WatchTimecode = WatchTimecode(on, hour, minute, second, frame)
