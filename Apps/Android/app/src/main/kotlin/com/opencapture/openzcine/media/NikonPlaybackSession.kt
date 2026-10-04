package com.opencapture.openzcine.media

import com.opencapture.opencine.appkit.MonitorMediaLibraryModel
import com.opencapture.opencine.appkit.MonitorMediaPlaybackModel
import com.opencapture.opencine.appkit.MonitorMediaRecord
import com.opencapture.opencine.media.MonitorPlaybackStartTiming
import kotlinx.coroutines.CoroutineScope

/** One actual gallery-borrowing logical owner. Native preparation/transfer remain the bounded
 * existing session primitives; callers supply current already-filtered typed playlist values. */
internal class NikonPlaybackSession(
    library: MonitorMediaLibraryModel<NikonLibraryClip>,
    record: MonitorMediaRecord<NikonLibraryClip>,
    records: List<MonitorMediaRecord<NikonLibraryClip>>,
    scope: CoroutineScope,
    val native: NikonPlaybackNativePort = NikonPlaybackNativePort(),
    now: () -> com.opencapture.opencine.core.MonotonicInstant = { com.opencapture.opencine.core.MonotonicInstant.now() },
) {
    val owner = MonitorMediaPlaybackModel<NikonLibraryClip, Unit>(
        library = library, native = native, scope = scope, readyTimeout = null,
        retryNativeFailures = false,
        startTiming = MonitorPlaybackStartTiming.AFTER_NATIVE_ITEM_INSTALLATION,
        candidates = { native.candidates(it, library) }, now = now,
    )
    init { owner.load(record, records) }

    fun navigate(target: MonitorMediaRecord<NikonLibraryClip>, records: List<MonitorMediaRecord<NikonLibraryClip>>) {
        if (!owner.isActive) return
        owner.load(target, records)
    }
    data class DeliveryPause(val item: com.opencapture.opencine.media.MonitorPlaybackItemToken, val resume: Boolean)
    fun pauseForDelivery(nativePlaying: Boolean): DeliveryPause? {
        if (!owner.isActive) return null
        val captured = DeliveryPause(owner.state.value.token, nativePlaying)
        owner.setPlaying(false)
        return captured
    }
    fun resumeAfterDelivery(captured: DeliveryPause) {
        if (!captured.resume || !owner.isActive || owner.state.value.token != captured.item) return
        owner.setPlaying(true)
    }

    fun scenePaused(item: com.opencapture.opencine.media.MonitorPlaybackItemToken) {
        if (!owner.isActive || owner.state.value.token != item) return
        owner.setPlaying(false)
        owner.setSceneActive(false)
    }
    fun sceneResumed(item: com.opencapture.opencine.media.MonitorPlaybackItemToken) {
        if (!owner.isActive || owner.state.value.token != item) return
        owner.setSceneActive(true)
    }

}
