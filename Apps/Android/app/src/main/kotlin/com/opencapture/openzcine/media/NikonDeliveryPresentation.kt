package com.opencapture.openzcine.media

import com.opencapture.opencine.appkit.MonitorDeliveryAdmission
import com.opencapture.opencine.appkit.MonitorDeliveryExternalOperation
import com.opencapture.opencine.appkit.MonitorDeliveryExternalTicket
import com.opencapture.opencine.appkit.MonitorDeliveryPresentation
import com.opencapture.opencine.appkit.MonitorDeliveryRunHandle
import com.opencapture.openzcine.frameio.FrameioDeliveryState
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.SharingStarted
import kotlinx.coroutines.flow.map
import kotlinx.coroutines.flow.stateIn
import kotlin.time.Duration

/** Native progress/wire report projection over the complete shared presentation owner. */
internal class NikonDeliveryPresentation(scope: CoroutineScope, sleep: suspend (Duration) -> Unit = { delay(it) }) {
    internal class ExternalTicket internal constructor(internal val captured: MonitorDeliveryExternalTicket<MediaDeliveryOverlayState>)
    internal data class Display(
        val overlay: MediaDeliveryOverlayState? = null,
        val toast: String? = null,
        val expanded: Boolean = false,
    )
    private val owner = MonitorDeliveryPresentation<MediaDeliveryOverlayState>(scope,
        isCaching = { it.isCaching }, isExternalDelivery = { it.destination == MediaDeliveryKind.FRAMEIO }, sleep = sleep)
    val display = owner.display.map { Display(it.overlay, it.toast, it.expanded) }
        .stateIn(scope, SharingStarted.Eagerly, Display())
    val overlayState get() = owner.overlayState
    val completionToast get() = owner.completionToast
    var isExpanded: Boolean
        get() = owner.isExpanded
        set(value) { owner.isExpanded = value }
    val nativeRunning get() = owner.nativeRunning
    val nativeState get() = owner.nativeState
    fun beginNative(operation: suspend ((MediaDeliveryOverlayState) -> Unit) -> String?) = owner.beginNative(operation)
    fun beginNativeCaptured(operation: suspend ((MediaDeliveryOverlayState) -> Unit, MonitorDeliveryAdmission) -> String?): MonitorDeliveryRunHandle? =
        owner.beginNativeCaptured(operation)
    fun trackExternalDelivery(job: Job?): ExternalTicket = ExternalTicket(owner.trackExternalDelivery(job?.let {
        MonitorDeliveryExternalOperation(active = { it.isActive }, cancel = { it.cancel() })
    }))
    fun finishExternalDelivery(captured: ExternalTicket) = owner.finishExternalDelivery(captured.captured)
    fun publishCache(captured: ExternalTicket, progress: MediaDeliveryOverlayState) = owner.publishCache(captured.captured, progress)
    fun bindFrameioDeliveryState(captured: ExternalTicket, state: FrameioDeliveryState) {
        when (state) {
            is FrameioDeliveryState.Uploading -> owner.publishExternalDelivery(captured.captured,
                MediaDeliveryOverlayState(MediaDeliveryKind.FRAMEIO, state.itemCount, state.itemIndex,
                    state.progress.coerceIn(0.0, 1.0), state.filename))
            is FrameioDeliveryState.Completed -> owner.completeExternalDelivery(captured.captured, buildString {
                append("Uploaded ${state.uploadedCount}")
                if (state.failedCount > 0) append(", ${state.failedCount} failed")
                if (state.skippedCount > 0) append(", ${state.skippedCount} skipped")
            })
            is FrameioDeliveryState.Failed -> owner.completeExternalDelivery(captured.captured, state.message)
            FrameioDeliveryState.Idle -> owner.noteExternalIdle(captured.captured)
        }
    }
    fun showToast(message: String) = owner.showToast(message)
    fun dismissToast() = owner.dismissToast()
    fun cancel() = owner.cancel()
    fun close() = owner.close()
}
