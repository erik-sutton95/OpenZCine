@file:androidx.media3.common.util.UnstableApi

package com.opencapture.openzcine.media

import android.content.Context
import com.opencapture.monitorui.MonitorAssistTool
import com.opencapture.opencine.appkit.*
import com.opencapture.opencine.cameracontrols.*
import com.opencapture.opencine.media.*
import com.opencapture.opencine.nikon.NikonMediaClipRecord
import com.opencapture.opencine.nikon.NikonNative
import com.opencapture.openzcine.NikonAssists
import com.opencapture.openzcine.StoredPanelCenter
import com.opencapture.openzcine.bridge.SwiftCore
import com.opencapture.openzcine.diagnostics.AndroidDiagnosticEvent
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext

// Nikon playback services the shared playback screen runs on: admitted transfers, panel placement
// stored per camera app, and the camera star rating over PTP.

internal class NikonPlaybackSourceCapture(val source: () -> Boolean,
    val record: (MonitorMediaRecord<NikonLibraryClip>) -> MonitorPlaybackAdmission)

/** Gates each bounded SDK primitive, without introducing a transfer/cache owner. */
internal class AdmittedPlaybackTransferBridge(
    private val delegate: MediaObjectTransferBridge,
    private val ifCurrent: () -> Boolean,
) : MediaObjectTransferBridge {
    override val isAvailable: Boolean get() = delegate.isAvailable && ifCurrent()
    override fun resolveMediaSize(handle: Int, reportedSize: Long): Long {
        if (!ifCurrent()) throw MonitorPlaybackException(MonitorPlaybackFailure.RETIRED)
        return delegate.resolveMediaSize(handle, reportedSize)
    }
    override fun startMediaTransfer(handle: Int, reportedSize: Long, resumeOffset: Long,
        listener: NikonNative.MediaTransferListener) {
        if (!ifCurrent()) throw MonitorPlaybackException(MonitorPlaybackFailure.RETIRED)
        delegate.startMediaTransfer(handle, reportedSize, resumeOffset, listener)
    }
    override fun stopMediaTransfer() = delegate.stopMediaTransfer()
}

internal fun playbackPanelPlacement(context: Context, assists: NikonAssists): MonitorAssistPanelPlacement {
    val reference = StoredPanelCenter(context, "playbackFalseColorReferencePlacement", "fcref")
    val audio = StoredPanelCenter(context, "playbackAudioMeterPlacement", "audio")
    return playbackPanelPlacement(reference, audio, assists.shared)
}

internal fun playbackPanelPlacement(reference: StoredPanelCenter, audio: StoredPanelCenter,
    assist: MonitorAssistState): MonitorAssistPanelPlacement {
    return MonitorAssistPanelPlacement(read = { tool, portrait -> when (tool) {
        MonitorAssistTool.FALSE -> reference.load()
        MonitorAssistTool.AUDIO -> audio.load()
        else -> assist.centerFor(tool, portrait)
    } }, write = { tool, center, portrait -> when (tool) {
        MonitorAssistTool.FALSE -> reference.save(center)
        MonitorAssistTool.AUDIO -> audio.save(center)
        else -> assist.storeCenter(tool, center, portrait)
    } }, falseColorDefaultHorizontalFraction = 0.72f,
        portraitAudioTrailingGapDp = 70f, landscapeAudioTrailingGapDp = 10f, usesAnalysisViewport = true,
        referenceBelowFeedGapDp = 10f, audioBottomGapDp = 10f, movementInsetDp = 0f)
}

internal fun playbackRating(available: Boolean, connectionOwner: Long?,
    mirror: (NikonMediaClipRecord, Int) -> Unit,
    capture: ((NikonMediaClipRecord) -> NikonMediaRatingCompletion)?,
    diagnostic: (AndroidDiagnosticEvent) -> Unit): MonitorMediaPlaybackRatingService<NikonLibraryClip> =
    MonitorMediaPlaybackRatingService(levels = (1..5).toList(), noticeMilliseconds = 4_000,
        read = { request ->
            val clip = request.record.payload.clip
            val completion = capture?.invoke(clip)
            if (!available || !SwiftCore.isAvailable || connectionOwner == null || !request.isCurrent) null
            else {
                val value = withContext(Dispatchers.IO) {
                    if (!request.isCurrent) -1 else NikonNative.sessionObjectRating(connectionOwner, clip.handle.toInt())
                }
                if (value < 0 || !request.isCurrent || completion?.isCurrent == false) null
                else if (completion != null && !completion.mirror(value)) null
                else { if (completion == null) mirror(clip, value); value }
            }
        }, commit = { target, request ->
            val clip = request.record.payload.clip
            val completion = capture?.invoke(clip)
            if (!available || !SwiftCore.isAvailable || connectionOwner == null || !request.isCurrent || completion?.isCurrent == false)
                MonitorMediaPictureRatingResult.Unavailable
            else {
                diagnostic(AndroidDiagnosticEvent.RATING_WRITE_ATTEMPTED)
                val result = withContext(Dispatchers.IO) {
                    if (!request.isCurrent) -1 else NikonNative.sessionSetObjectRating(connectionOwner, clip.handle.toInt(), target)
                }
                if (!request.isCurrent || completion?.isCurrent == false) MonitorMediaPictureRatingResult.Unavailable
                else when (val outcome = ratingWriteResult(result)) {
                    is RatingWriteResult.Confirmed -> {
                        if (completion != null && !completion.mirror(outcome.stars)) MonitorMediaPictureRatingResult.Unavailable
                        else {
                            if (completion == null) mirror(clip, outcome.stars)
                            diagnostic(AndroidDiagnosticEvent.RATING_WRITE_CONFIRMED)
                            MonitorMediaPictureRatingResult.Confirmed(outcome.stars)
                        }
                    }
                    is RatingWriteResult.Refused -> {
                        diagnostic(if (outcome.code == 0x2013) AndroidDiagnosticEvent.RATING_WRITE_REFUSED_ACCESS_DENIED
                            else AndroidDiagnosticEvent.RATING_WRITE_REFUSED)
                        MonitorMediaPictureRatingResult.Refused(ratingRefusalMessage(outcome.code))
                    }
                }
            }
        })

/** Each playback transfer: the cached proxy prepared over an admitted bridge, stopped on the owning connection. */
internal fun nikonPlaybackTransfers(
    cacheStore: MediaCacheStore,
    connectionOwner: Long?,
    cameraTransferAvailable: Boolean,
    onResolvedObjectSize: (NikonMediaClipRecord, Long) -> Unit,
): (MonitorMediaRecord<NikonLibraryClip>, () -> Boolean) -> MediaTransferCoordinator = { record, ifCurrent ->
    val clip = record.payload.clip
    val delegate = SwiftCoreMediaObjectTransferBridge(connectionOwner)
    val bridge = AdmittedPlaybackTransferBridge(delegate, ifCurrent)
    MediaTransferCoordinator(prepareTransfer = {
        if (!ifCurrent()) MediaTransferPreparation.Cancelled else withContext(Dispatchers.IO) {
            if (!ifCurrent()) MediaTransferPreparation.Cancelled else {
                val result = prepareMediaObjectTransfer(cacheStore, record.payload.bucket, clip,
                    "clip", bridge, cameraTransferAvailable,
                    onResolvedSize = { bytes -> if (ifCurrent()) onResolvedObjectSize(clip, bytes) })
                if (ifCurrent()) result else MediaTransferPreparation.Cancelled
            }
        }
    }, stopTransfer = {
        // Entered cleanup always addresses the captured native connection owner.
        if (cameraTransferAvailable && connectionOwner != null) withContext(Dispatchers.IO) {
            NikonNative.sessionStopMediaTransfer(connectionOwner)
        }
    })
}

/** Delete, favourite, share access and rating for the shared playback screen, each admitted against the open clip. */
internal fun nikonPlaybackOperations(
    playerContext: NikonOperatorPlaybackContext,
    coordinator: MonitorDeliveryCoordinator,
    capture: NikonPlaybackSourceCapture,
    captureDeletion: ((MonitorMediaRecord<NikonLibraryClip>, suspend () -> Boolean) -> MonitorOperatorPlaybackDeletionRequest?)?,
    transferAvailable: () -> Boolean,
    cover: Boolean,
    prepared: () -> NikonPlaybackNativePort.Source?,
    onToggleFavorite: (NikonMediaClipRecord) -> Unit,
    rating: MonitorMediaPlaybackRatingService<NikonLibraryClip>,
): MonitorOperatorPlaybackOperations<NikonLibraryClip, Unit> =
    MonitorOperatorPlaybackOperations<NikonLibraryClip, Unit>(
        captureDeletion = { record ->
            val outgoing = playerContext.media.state.value.playback
            val outgoingNative = playerContext.native
            // Deleting from the camera needs its channel; only a run caching from it yields.
            val run = coordinator.capturedRun.takeIf { coordinator.holdsCameraTransfer }
            if (captureDeletion == null || outgoing == null || outgoingNative == null ||
                !transferAvailable() || cover || !capture.record(record).isCurrent() ||
                !playerContext.media.isCurrent(outgoing.state.value.token) ||
                outgoing.state.value.active?.asset?.id != record.asset.id) null else {
                val token = outgoing.state.value.token
                captureDeletion(record) {
                    if (playerContext.media.state.value.playback !== outgoing || playerContext.native !== outgoingNative ||
                        !playerContext.media.isCurrent(token)) false else {
                        outgoing.close()
                        run?.cancelAndJoin()
                        outgoingNative.finishEnteredTransfer()
                        val retired = outgoing.state.value
                        playerContext.media.state.value.playback === outgoing && playerContext.native === outgoingNative &&
                            retired.closed && retired.token == token.copy(revision = token.revision + 1)
                    }
                }
            }
        },
        favorite = { record -> if (capture.record(record).isCurrent()) onToggleFavorite(record.payload.clip) },
        access = { record ->
            val preparedRecord = prepared()?.takeIf { it.record.asset.id == record.asset.id }
            val completed = (preparedRecord?.preparation as? MediaTransferPreparation.Ready)?.entry
            val ready = completed?.let { playbackShareState(it.state, it.downloadedBytes, it.expectedLength) == PlaybackShareState.READY } == true
            MonitorMediaGalleryAccess(share = capture.record(record).isCurrent() &&
                canDeliverMedia(if (ready) 1 else 0, 1, transferAvailable()),
                delete = captureDeletion != null && transferAvailable() && !cover && capture.record(record).isCurrent())
        }, rating = rating)
