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
import com.opencapture.opencine.watchruntime.WatchMessagePort
import com.opencapture.opencine.watchruntime.WatchReceiverOwner
import com.opencapture.opencine.watchruntime.WatchReceiverPolicy
import com.opencapture.opencine.watchruntime.WatchRuntimeScheduler
import com.opencapture.opencine.watchruntime.WatchScheduled
import com.opencapture.openzcine.wearrelay.DeployedWearRelayCodec
import com.opencapture.openzcine.wearrelay.WatchRelayState
import com.opencapture.openzcine.wearrelay.WatchTimecode
import com.opencapture.openzcine.wearrelay.WearRelayTransport
import java.util.UUID
import java.util.concurrent.atomic.AtomicReference
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.launch

/** Bounded Google/native SDK adapter. Shared WatchReceiverOwner owns all receiver policy. */
@Stable internal class WearRelayController(context: Context) {
    private val applicationContext = context.applicationContext
    private val messageClient by lazy { Wearable.getMessageClient(applicationContext) }
    private val capabilityClient by lazy { Wearable.getCapabilityClient(applicationContext) }
    private val handler = Handler(Looper.getMainLooper())
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)
    private var gate: AtomicReference<UUID?>? = null
    private var messageListener: MessageClient.OnMessageReceivedListener? = null
    private var capabilityListener: CapabilityClient.OnCapabilityChangedListener? = null
    private val owner = WatchReceiverOwner(
        codec = DeployedWearRelayCodec(), scheduler = object : WatchRuntimeScheduler {
            override fun nowMillis(): Long = SystemClock.elapsedRealtime()
            override fun schedule(afterMillis: Long, action: () -> Unit): WatchScheduled {
                val runnable = Runnable(action)
                handler.postDelayed(runnable, afterMillis)
                return WatchScheduled { handler.removeCallbacks(runnable) }
            }
        }, messages = WatchMessagePort { node, path, bytes, failure ->
            messageClient.sendMessage(node, path, bytes).addOnFailureListener { failure?.invoke() }
        }, decodeImage = { bytes -> BitmapFactory.decodeByteArray(bytes, 0, bytes.size) },
        policy = WatchReceiverPolicy(
            unavailableError = applicationContext.getString(R.string.wear_phone_unavailable_error),
            timeoutError = applicationContext.getString(R.string.wear_record_timeout)))
    private var observed by mutableStateOf(owner.snapshot.value)
    // Observe for recomposition, then read the actual owner atomically for captured action checks.
    private val current get() = observed.let { owner.snapshot.value }
    val presentationRevision: Long get() = current.presentationRevision
    val state: WatchRelayState? get() = current.state
    val frame: Bitmap? get() = current.image
    val frameTimecode: WatchTimecode? get() = current.timecode
    val phoneReachable: Boolean get() = current.phoneReachable
    val isSendingCommand: Boolean get() = current.isSendingCommand
    val commandMessage: String? get() = current.commandMessage
    init {
        owner.onSourceRetired = { gate?.set(it) }
        scope.launch {
            owner.snapshot.collect { observed = it }
        }
    }
    fun start() {
        if (!hasGooglePlayServices() || !owner.start()) return
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
            if (info.name == WearRelayTransport.PHONE_CAPABILITY) {
                val window = gate.get() ?: return@OnCapabilityChangedListener
                val nodes = info.nodes.map { it.id }.toSet()
                operator { owner.acceptNodes(nodes, window) }
            }
        }
        messageListener = message
        capabilityListener = capability
        messageClient.addListener(message)
        capabilityClient.addListener(capability, WearRelayTransport.PHONE_CAPABILITY)
        capabilityClient.getCapability(WearRelayTransport.PHONE_CAPABILITY, CapabilityClient.FILTER_REACHABLE)
            .addOnSuccessListener { info ->
                val window = gate.get() ?: return@addOnSuccessListener
                val nodes = info.nodes.map { it.id }.toSet()
                operator { owner.acceptNodes(nodes, window) }
            }.addOnFailureListener {
                val window = gate.get() ?: return@addOnFailureListener
                operator { owner.acceptNodes(emptySet(), window) }
            }
    }
    fun stop() {
        gate?.set(null)
        gate = null
        owner.stop()
        if (hasGooglePlayServices()) {
            messageListener?.let(messageClient::removeListener)
            capabilityListener?.let { capabilityClient.removeListener(it, WearRelayTransport.PHONE_CAPABILITY) }
        }
        messageListener = null
        capabilityListener = null
    }
    fun close() { stop(); owner.close(); scope.cancel() }
    fun sendToggleRecord() { owner.sendToggleRecord() }
    private fun operator(action: () -> Unit) {
        if (Looper.myLooper() == handler.looper) action() else handler.post(action)
    }
    private fun hasGooglePlayServices(): Boolean =
        GoogleApiAvailability.getInstance().isGooglePlayServicesAvailable(applicationContext) == ConnectionResult.SUCCESS
}
