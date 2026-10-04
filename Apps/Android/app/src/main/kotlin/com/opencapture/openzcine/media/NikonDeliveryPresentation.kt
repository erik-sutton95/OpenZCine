package com.opencapture.openzcine.media

import com.opencapture.opencine.appkit.MonitorDeliveryCompletion
import com.opencapture.opencine.appkit.MonitorDeliveryModel
import com.opencapture.openzcine.frameio.FrameioDeliveryState
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Job
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.SharingStarted
import kotlinx.coroutines.flow.combine
import kotlinx.coroutines.flow.stateIn
import kotlin.time.Duration

/** Actual native/export and surface-owned upload intents coexist; neither starts wire work here. */
internal class NikonDeliveryPresentation(
    scope: CoroutineScope,
    sleep: suspend (Duration) -> Unit = { delay(it) },
) {
    internal class ExternalTicket internal constructor(internal val job: Job?) {
        internal val terminal = CompletableDeferred<String?>()
        internal var report: ((MediaDeliveryOverlayState) -> Unit)? = null
        internal var pendingProgress: MediaDeliveryOverlayState? = null
        internal var callerFinished = false
    }

    internal data class Display(
        val overlay: MediaDeliveryOverlayState? = null,
        val toast: String? = null,
        val expanded: Boolean = false,
    )

    private enum class Intent { NATIVE, EXTERNAL }
    private val native = MonitorDeliveryModel<MediaDeliveryOverlayState, String?, Unit>(scope, sleep)
    private val external = MonitorDeliveryModel<MediaDeliveryOverlayState, String?, Unit>(scope, sleep)
    private val chrome = MonitorDeliveryModel<Unit, Unit, Unit>(scope, sleep)
    private val notifications = MonitorDeliveryModel<Unit, Unit, Unit>(scope, sleep)
    private val presented = MutableStateFlow<Intent?>(null)
    private class NativeTicket
    private var nativeTicket: NativeTicket? = null
    private var ticket: ExternalTicket? = null
    private var closed = false
    val display = combine(native.state, external.state, chrome.state, notifications.state, presented) { n, e, c, t, intent ->
        Display(when (intent) { Intent.NATIVE -> n.progress; Intent.EXTERNAL -> e.progress; null -> null }, t.toast, c.expanded)
    }.stateIn(scope, SharingStarted.Eagerly, Display())

    val overlayState: MediaDeliveryOverlayState?
        get() = when (presented.value) {
            Intent.NATIVE -> native.state.value.progress
            Intent.EXTERNAL -> external.state.value.progress
            null -> null
        }
    val completionToast: String? get() = notifications.state.value.toast
    var isExpanded: Boolean
        get() = chrome.state.value.expanded
        set(value) { chrome.setExpanded(value) }
    val nativeRunning: Boolean get() = native.state.value.running

    fun beginNative(operation: suspend ((MediaDeliveryOverlayState) -> Unit) -> String?) {
        if (closed) return
        val captured = NativeTicket()
        nativeTicket = captured
        presented.value = Intent.NATIVE
        if (nativeTicket !== captured || closed) return
        chrome.setExpanded(false)
        if (nativeTicket !== captured || closed) return
        native.begin(onComplete = { message ->
            if (nativeTicket === captured && !closed) {
                presented.value = null
                if (nativeTicket !== captured || closed) return@begin null
                chrome.setExpanded(false)
                if (nativeTicket === captured && !closed) message?.let(::showToast)
            }
            null
        }) { report ->
            val operationJob = currentCoroutineContext()[Job]
            val message = operation { progress ->
                if (!closed && nativeTicket === captured && operationJob?.isActive == true) {
                    presented.value = Intent.NATIVE
                    report(progress)
                }
            }
            MonitorDeliveryCompletion(message)
        }
    }

    /** Replacement retires presentation; the original surface still owns its previous raw Job. */
    fun trackExternalDelivery(job: Job?): ExternalTicket {
        val captured = ExternalTicket(job)
        if (closed) { captured.callerFinished = true; return captured }
        captured.pendingProgress = overlayState.takeIf { presented.value == Intent.EXTERNAL }
        ticket = captured
        external.begin(onCancel = {
            if (!captured.callerFinished) captured.job?.cancel()
        }, onComplete = { message ->
            if (ticket === captured) {
                presented.value = null
                if (ticket !== captured || closed) return@begin null
                chrome.setExpanded(false)
                if (ticket === captured && !closed) message?.let(::showToast)
            }
            null
        }) { report ->
            captured.report = report
            captured.pendingProgress?.let(report)
            captured.pendingProgress = null
            MonitorDeliveryCompletion(captured.terminal.await())
        }
        return captured
    }

    /** Captured finally cannot clear the raw handle or bar belonging to another surface. */
    fun finishExternalDelivery(captured: ExternalTicket) {
        if (ticket !== captured || closed) return
        captured.callerFinished = true
        if (overlayState?.isCaching == true && !nativeRunning) {
            presented.value = null
            if (ticket !== captured || closed) return
            chrome.setExpanded(false)
            if (ticket === captured && !closed) external.cancel()
        }
        // An uploading bar without a terminal observation stays visible, as in the donor.
        // Its completed caller Job is retained only as that current presentation's identity.
    }

    /** Cache callbacks preserve donor last-publication behavior even during native work. */
    fun publishCache(captured: ExternalTicket, progress: MediaDeliveryOverlayState) {
        if (closed || ticket !== captured) return
        presented.value = Intent.EXTERNAL
        val report = captured.report
        if (report == null) captured.pendingProgress = progress else report(progress)
    }

    /** This callback belongs to the real deliver invocation, never a newly sampled global state. */
    fun bindFrameioDeliveryState(captured: ExternalTicket, state: FrameioDeliveryState) {
        if (closed || ticket !== captured || nativeRunning) return
        when (state) {
            is FrameioDeliveryState.Uploading -> publishCache(captured,
                MediaDeliveryOverlayState(MediaDeliveryKind.FRAMEIO, state.itemCount,
                    state.itemIndex, state.progress.coerceIn(0.0, 1.0), state.filename))
            is FrameioDeliveryState.Completed -> captured.terminal.complete(buildString {
                append("Uploaded ${state.uploadedCount}")
                if (state.failedCount > 0) append(", ${state.failedCount} failed")
                if (state.skippedCount > 0) append(", ${state.skippedCount} skipped")
            })
            is FrameioDeliveryState.Failed -> captured.terminal.complete(state.message)
            FrameioDeliveryState.Idle -> if (captured.job?.isActive != true) {
                if (overlayState?.destination == MediaDeliveryKind.FRAMEIO) {
                    presented.value = null
                    if (ticket !== captured || closed) return
                    chrome.setExpanded(false)
                    if (ticket === captured && !closed) external.cancel()
                }
            }
        }
    }

    fun showToast(message: String) {
        if (closed) return
        notifications.begin { MonitorDeliveryCompletion(Unit, toast = message) }
    }
    fun dismissToast() = notifications.dismissToast()
    fun cancel() {
        val retiringExternal = ticket
        nativeTicket = null
        ticket = null
        presented.value = null
        if (nativeTicket == null && ticket == null) chrome.setExpanded(false)
        if (nativeTicket == null) native.cancel()
        // Native cancellation can synchronously register a successor external intent.
        if (ticket == null) external.cancel()
        else if (retiringExternal?.callerFinished == false) retiringExternal.job?.cancel()
    }
    fun close() {
        if (closed) return
        closed = true
        cancel()
        native.close()
        external.close()
        chrome.close()
        notifications.close()
    }
}
