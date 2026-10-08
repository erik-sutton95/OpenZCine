package com.opencapture.openzcine.media

import com.opencapture.opencine.appkit.MonitorMediaLibraryModel
import com.opencapture.opencine.appkit.MonitorMediaPlaybackModel
import com.opencapture.opencine.appkit.MonitorMediaRecord
import com.opencapture.opencine.appkit.MonitorMediaGalleryOpen
import com.opencapture.opencine.appkit.MonitorOperatorMediaModel
import com.opencapture.opencine.appkit.MonitorPlaybackAdmission
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
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

/** One shared player, borrowing the actual gallery and canonical source generation. */
internal class NikonOperatorPlaybackContext(
    val library: MonitorMediaLibraryModel<NikonLibraryClip>,
    val initial: MonitorMediaGalleryOpen<NikonLibraryClip>,
    scope: CoroutineScope,
    private val sourceCurrent: () -> Boolean,
    private val captureRecord: (MonitorMediaRecord<NikonLibraryClip>) -> MonitorPlaybackAdmission,
    private val transferFactory: (MonitorMediaRecord<NikonLibraryClip>, () -> Boolean) -> MediaTransferCoordinator,
    private val captureDeliveryCleanup: () -> (suspend () -> Unit) = { {} },
    private val cleanupScope: CoroutineScope? = null,
) {
    private val directory = library.cache.directory
    private val generation = directory.generation
    private val root = directory.root
    var native: NikonPlaybackNativePort? by mutableStateOf(null)
        private set

    private fun sourceAdmitted(): Boolean {
        if (directory.generation != generation || directory.root != root) return false
        val accepted = sourceCurrent()
        return accepted && directory.generation == generation && directory.root == root
    }
    private fun recordAdmission(record: MonitorMediaRecord<NikonLibraryClip>): MonitorPlaybackAdmission {
        if (!sourceAdmitted()) return MonitorPlaybackAdmission { false }
        val actual = captureRecord(record)
        return MonitorPlaybackAdmission {
            sourceAdmitted() && actual.isCurrent() && sourceAdmitted()
        }
    }
    val media = MonitorOperatorMediaModel<NikonLibraryClip, Unit>(library, scope,
        recordAdmission = ::recordAdmission, makeAdmittedPlayback = { owner, admission ->
            if (!admission.isCurrent() || !sourceAdmitted()) null else {
                val previous = native
                val next = NikonPlaybackNativePort(transferFactory = transferFactory,
                    sourceCurrent = { sourceAdmitted() },
                    cleanupScope = cleanupScope,
                    beforePrepare = { previous?.finishEnteredTransfer() },
                    captureBeforePrepare = captureDeliveryCleanup)
                val playback = MonitorMediaPlaybackModel<NikonLibraryClip, Unit>(
                    library = owner, native = next, scope = scope, readyTimeout = null,
                    retryNativeFailures = false,
                    startTiming = MonitorPlaybackStartTiming.AFTER_NATIVE_ITEM_INSTALLATION,
                    candidates = { next.candidates(it, owner) }, seekEndClearance = 0.25,
                    sceneLossPolicy = com.opencapture.opencine.media.MonitorPlaybackSceneLossPolicy.CLEAR_REQUEST)
                playback.setItemAdmission(::recordAdmission)
                if (!admission.isCurrent() || !sourceAdmitted()) {
                    playback.close(); null
                } else { native = next; playback }
            }
        })
}
