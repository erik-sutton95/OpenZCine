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

/** The Nikon player policy: the shared defaults plus the proxy end clearance Z iOS also uses. */
internal fun nikonPlaybackModel(
    library: MonitorMediaLibraryModel<NikonLibraryClip>,
    native: NikonPlaybackNativePort,
    scope: CoroutineScope,
    now: () -> com.opencapture.opencine.core.MonotonicInstant = { com.opencapture.opencine.core.MonotonicInstant.now() },
): MonitorMediaPlaybackModel<NikonLibraryClip, Unit> = MonitorMediaPlaybackModel(
    library = library, native = native, scope = scope, readyTimeout = null,
    retryNativeFailures = false,
    startTiming = MonitorPlaybackStartTiming.AFTER_NATIVE_ITEM_INSTALLATION,
    candidates = { native.candidates(it, library) }, now = now, seekEndClearance = 0.25,
)

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
                val playback = nikonPlaybackModel(owner, next, scope)
                playback.setItemAdmission(::recordAdmission)
                if (!admission.isCurrent() || !sourceAdmitted()) {
                    playback.close(); null
                } else { native = next; playback }
            }
        })
}
