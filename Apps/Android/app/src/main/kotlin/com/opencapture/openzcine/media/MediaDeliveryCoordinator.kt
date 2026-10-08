package com.opencapture.openzcine.media

import android.content.Context
import com.opencapture.opencine.nikon.NikonMediaClipRecord
import com.opencapture.opencine.nikon.NikonMediaContentKind
import com.opencapture.openzcine.frameio.FrameioArtifactContext
import com.opencapture.openzcine.frameio.FrameioDeliveryArtifact
import com.opencapture.openzcine.frameio.FrameioDeliveryController
import com.opencapture.openzcine.frameio.FrameioDeliveryState
import com.opencapture.openzcine.frameio.FrameioPreparedArtifact
import com.opencapture.openzcine.frameio.FrameioInternetLease
import com.opencapture.openzcine.frameio.FrameioCapturedProjectListing
import com.opencapture.openzcine.frameio.FrameioDestination
import com.opencapture.openzcine.frameio.MediaDeliveryConfiguration
import java.nio.file.Files
import com.opencapture.opencine.appkit.*
import kotlin.math.min
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.withContext

/**
 * iOS `MediaDeliveryCoordinator` twin: app-scoped export/share work that
 * survives media-screen dismissal and drives a persistent progress overlay.
 */
internal enum class MediaDeliveryKind {
    NATIVE_SHARE,
    SAVE_TO_PHOTOS,
    FRAMEIO,
}

/** Live progress for the delivery pill / expanded panel (iOS `MediaDeliveryOverlayState`). */
internal data class MediaDeliveryOverlayState(
    val destination: MediaDeliveryKind,
    val totalClips: Int,
    val clipIndex: Int,
    val clipFraction: Double,
    val filename: String? = null,
    val isCaching: Boolean = false,
) {
    val overallFraction: Double
        get() {
            if (totalClips <= 0) return 0.0
            val completed = maxOf(0, clipIndex - 1).toDouble()
            return min(1.0, (completed + clipFraction.coerceIn(0.0, 1.0)) / totalClips.toDouble())
        }

    val isPreparingClip: Boolean
        get() = clipFraction <= 0.0

    val percentText: String
        get() =
            if (isPreparingClip) {
                ""
            } else {
                "${(overallFraction * 100.0).toInt()}%"
            }

    val statusLine: String
        get() {
            val verb =
                when {
                    isCaching && isPreparingClip -> "Caching from camera…"
                    isCaching -> "Caching from camera"
                    isPreparingClip -> "Preparing…"
                    destination == MediaDeliveryKind.NATIVE_SHARE -> "Preparing to share"
                    destination == MediaDeliveryKind.SAVE_TO_PHOTOS -> "Saving to Photos"
                    destination == MediaDeliveryKind.FRAMEIO -> "Uploading to Frame.io"
                    else -> "Preparing…"
                }
            return if (isPreparingClip || percentText.isEmpty()) verb else "$verb $percentText"
        }

    val batchLine: String?
        get() =
            if (totalClips > 1) {
                "Clip ${min(clipIndex, totalClips)} of $totalClips"
            } else {
                null
            }
}

/** One complete-cache clip ready for external delivery. */
internal data class MediaDeliveryWorkItem(
    val cameraID: String,
    val clip: NikonMediaClipRecord,
    val entry: MediaCacheEntry,
)

/** App-scoped native leaves and result projection; shared delivery owns every ordered run. */
internal class MediaDeliveryCoordinator(
    private val appContext: Context,
    private val frameioController: FrameioDeliveryController,
    private val cacheStore: MediaCacheStore,
    private val galleryGateway: MediaGalleryGateway = AndroidMediaGalleryGateway(appContext.contentResolver),
    scope: CoroutineScope,
) {
    private val presentation = NikonDeliveryPresentation(scope)
    val display get() = presentation.display
    val overlayState get() = presentation.overlayState
    val completionToast get() = presentation.completionToast
    val nativeState get() = presentation.nativeState
    var isExpanded: Boolean
        get() = presentation.isExpanded
        set(value) { presentation.isExpanded = value }
    val isActive get() = overlayState != null
    fun dismissToast() = presentation.dismissToast()
    fun cancel() = presentation.cancel()
    fun close() = presentation.close()
    fun trackExternalDelivery(job: Job?) = presentation.trackExternalDelivery(job)
    fun finishExternalDelivery(ticket: NikonDeliveryPresentation.ExternalTicket) = presentation.finishExternalDelivery(ticket)
    fun bindFrameioDeliveryState(ticket: NikonDeliveryPresentation.ExternalTicket, state: FrameioDeliveryState) =
        presentation.bindFrameioDeliveryState(ticket, state)

    suspend fun cacheFromCamera(destination: MediaDeliveryKind, selection: List<MediaDeliverySelection>,
        cameraConnectionOwner: Long?, ticket: NikonDeliveryPresentation.ExternalTicket? = null): MediaDeliveryCachePass {
        val captured = ticket ?: presentation.trackExternalDelivery(null)
        return cacheSelectionForDelivery(selection, cacheStore, cameraConnectionOwner != null,
            SwiftCoreMediaObjectTransferBridge(cameraConnectionOwner)) { index, count, item, fraction ->
            presentation.publishCache(captured, MediaDeliveryOverlayState(destination, count, index,
                fraction, item.clip.filename, isCaching = true))
        }
    }

    fun beginNativeShare(selection: List<MediaDeliverySelection>, configuration: MediaDeliveryConfiguration,
        cameraConnectionOwner: Long?, onShareReady: (List<StagedMediaShare>, String?) -> Unit) {
        beginNativeShareCaptured(selection, configuration, cameraConnectionOwner, MonitorDeliveryAdmission { true }, onShareReady = onShareReady)
    }
    fun beginNativeShareCaptured(selection: List<MediaDeliverySelection>, configuration: MediaDeliveryConfiguration,
        cameraConnectionOwner: Long?, admission: MonitorDeliveryAdmission, beforeIO: suspend () -> Unit = {},
        route: FrameioInternetLease? = null, completion: MonitorDeliveryAdmission = admission,
        onShareReady: (List<StagedMediaShare>, String?) -> Unit): MonitorDeliveryRunHandle? =
        beginCaptured(MediaDeliveryKind.NATIVE_SHARE, selection, configuration, cameraConnectionOwner, admission, onShareReady, beforeIO, route, completion)

    fun beginSaveToPhotos(selection: List<MediaDeliverySelection>, configuration: MediaDeliveryConfiguration,
        cameraConnectionOwner: Long?) {
        beginSaveToPhotosCaptured(selection, configuration, cameraConnectionOwner, MonitorDeliveryAdmission { true })
    }
    fun beginSaveToPhotosCaptured(selection: List<MediaDeliverySelection>, configuration: MediaDeliveryConfiguration,
        cameraConnectionOwner: Long?, admission: MonitorDeliveryAdmission, beforeIO: suspend () -> Unit = {},
        route: FrameioInternetLease? = null, completion: MonitorDeliveryAdmission = admission): MonitorDeliveryRunHandle? =
        beginCaptured(MediaDeliveryKind.SAVE_TO_PHOTOS, selection, configuration, cameraConnectionOwner, admission, null, beforeIO, route, completion)

    /** Same native progress context, used by the popup's pre-hop cache, never a separate cache Job. */
    fun cacheCaptured(selection: List<MediaDeliverySelection>, cameraConnectionOwner: Long?,
        admission: MonitorDeliveryAdmission, beforeIO: suspend () -> Unit = {}): MonitorDeliveryRunHandle? =
        presentation.beginNativeCaptured { publish, run ->
            beforeIO()
            val admitted = MonitorDeliveryAdmission { run.isCurrent() && admission.isCurrent() && run.isCurrent() }
            val originals = NikonDeliveryOriginals(selection, cacheStore, cameraConnectionOwner != null,
                SwiftCoreMediaObjectTransferBridge(cameraConnectionOwner), admitted)
            originals.loadCompleteEntries()
            val result = MonitorDeliveryModel.cacheOriginals(selection, MonitorDeliveryDestination.REMOTE_UPLOAD,
                admitted, originals.service, { it.clip.filename }, progress = {
                    publish(it.nativeOverlay(MediaDeliveryKind.FRAMEIO))
                })
            if (result == null) "Cancelled." else null
        }

    /** Actual remote producer consumes the same shared run and exact outgoing cleanup barrier. */
    fun beginFrameioCaptured(selection: List<MediaDeliverySelection>, configuration: MediaDeliveryConfiguration,
        cameraConnectionOwner: Long?, source: MonitorDeliveryAdmission,
        route: com.opencapture.openzcine.frameio.FrameioInternetLease?, beforeIO: suspend () -> Unit = {},
        completion: MonitorDeliveryAdmission = source, capturedProjects: FrameioCapturedProjectListing? = null,
        capturedDestination: FrameioDestination? = null): MonitorDeliveryRunHandle? {
        if (selection.isEmpty() || !source.isCurrent()) {
            route?.let(frameioController::restoreInternetHopAfterDismiss); return null
        }
        return presentation.beginNativeCaptured { publish, run ->
            try {
            beforeIO()
            fun accountCurrent(): Boolean = capturedProjects == null || frameioController.ownsProjects(capturedProjects)
            val admitted = MonitorDeliveryAdmission { run.isCurrent() && accountCurrent() && source.isCurrent() &&
                accountCurrent() && run.isCurrent() }
            if (!admitted.isCurrent()) return@beginNativeCaptured null
            val originals = NikonDeliveryOriginals(selection, cacheStore, cameraConnectionOwner != null,
                SwiftCoreMediaObjectTransferBridge(cameraConnectionOwner), admitted)
            originals.loadCompleteEntries()
            val stager = MediaShareStager(appContext.cacheDir.toPath())
            val result = frameioController.deliverCaptured(selection, configuration, admitted, route, originals.service,
                filename = { it.clip.filename }, stage = { record ->
                    val item = originals.workItem(record) ?: error("Cached clip is no longer available.")
                    withContext(Dispatchers.IO) {
                        val enteredContext = currentCoroutineContext()
                        val staged = stager.stage(item.entry, item.clip) { enteredContext.ensureActive() }
                        FrameioDeliveryArtifact(staged, Files.size(staged.file), FrameioArtifactContext(item.cameraID,
                            item.clip.captureDate, item.clip.contentKind == NikonMediaContentKind.PLAYABLE_PROXY,
                            item.clip.libraryKey(item.cameraID)))
                    }
                }, onBatchProgress = { publish(it.nativeOverlay(MediaDeliveryKind.FRAMEIO)) },
                completion = MonitorDeliveryAdmission { run.isCurrent() && accountCurrent() && completion.isCurrent() &&
                    accountCurrent() && run.isCurrent() }, capturedProjects = capturedProjects, capturedDestination = capturedDestination)
            if (!run.isCurrent() || !completion.isCurrent()) null else frameioDeliverySummary(result, frameioController.internetHopState,
                frameioController.errorMessage, selection.count { !originals.service.available(it) })
            } finally {
                route?.let { frameioController.endInternetHop(it) }
            }
        }
    }

    private fun beginCaptured(destination: MediaDeliveryKind, selection: List<MediaDeliverySelection>,
        configuration: MediaDeliveryConfiguration, cameraConnectionOwner: Long?, source: MonitorDeliveryAdmission,
        onShareReady: ((List<StagedMediaShare>, String?) -> Unit)?, beforeIO: suspend () -> Unit,
        route: FrameioInternetLease?, completion: MonitorDeliveryAdmission): MonitorDeliveryRunHandle? {
        if (selection.isEmpty() || !source.isCurrent()) {
            route?.let(frameioController::restoreInternetHopAfterDismiss); return null
        }
        val selected = if (destination == MediaDeliveryKind.SAVE_TO_PHOTOS) selection.filter {
            it.clip.contentKind == NikonMediaContentKind.PLAYABLE_PROXY || it.clip.contentKind == NikonMediaContentKind.STILL_PHOTO
        } else selection
        if (selected.isEmpty()) {
            presentation.showToast("No video or photo in the selection can be saved to Gallery.")
            route?.let(frameioController::restoreInternetHopAfterDismiss)
            return null
        }
        return presentation.beginNativeCaptured { publish, run ->
            try {
            beforeIO()
            val admitted = MonitorDeliveryAdmission { run.isCurrent() && source.isCurrent() && run.isCurrent() }
            val originals = NikonDeliveryOriginals(selected, cacheStore, cameraConnectionOwner != null,
                SwiftCoreMediaObjectTransferBridge(cameraConnectionOwner), admitted)
            originals.loadCompleteEntries()
            val stager = MediaShareStager(appContext.cacheDir.toPath())
            val failures = mutableListOf<MediaGalleryFailure>()
            val saver = MediaGallerySaver(galleryGateway)
            val outcome = MonitorDeliveryModel.runBatch<MediaDeliverySelection, PreparedClip, FrameioInternetLease>(
                records = selected, destination = MonitorDeliveryDestination.NATIVE_SHARE,
                action = if (destination == MediaDeliveryKind.SAVE_TO_PHOTOS) MonitorDeliveryPostExportAction.SAVE_TO_PHOTOS
                    else MonitorDeliveryPostExportAction.SYSTEM_SHARE,
                admission = admitted, originals = originals.service,
                exporter = MonitorDeliveryExportService(release = { frameioController.releaseExternalDelivery(it.prepared) },
                    prepare = { record, progress ->
                        val item = originals.workItem(record) ?: error("Cached clip is no longer available.")
                        val staged = withContext(Dispatchers.IO) {
                            val enteredContext = currentCoroutineContext()
                            stager.stage(item.entry, item.clip) { enteredContext.ensureActive() }
                        }
                        val artifact = FrameioDeliveryArtifact(staged, withContext(Dispatchers.IO) { Files.size(staged.file) },
                            FrameioArtifactContext(item.cameraID, item.clip.captureDate,
                                item.clip.contentKind == NikonMediaContentKind.PLAYABLE_PROXY, item.clip.libraryKey(item.cameraID)))
                        val prepared = frameioController.prepareForExternalDelivery(artifact, configuration) { progress(it) }
                        try {
                            // The chooser owns its private copy before the shared run releases an entered transient export.
                            val ready = if (prepared.transientExport == null || destination == MediaDeliveryKind.SAVE_TO_PHOTOS) prepared.share
                                else withContext(Dispatchers.IO) {
                                    val enteredContext = currentCoroutineContext()
                                    stager.stagePreparedArtifact(prepared.share.file, prepared.byteCount,
                                        prepared.share.displayName, prepared.share.mimeType) { enteredContext.ensureActive() }
                                }
                            PreparedClip(ready, prepared, item.clip)
                        } catch (failure: Throwable) {
                            withContext(kotlinx.coroutines.NonCancellable) { frameioController.releaseExternalDelivery(prepared) }
                            throw failure
                        }
                    }),
                share = { MonitorDeliveryShareFiles(it) },
                photos = MonitorDeliveryPhotosService.PerItem { prepared ->
                    withContext(Dispatchers.IO) {
                        val enteredContext = currentCoroutineContext()
                        val artifact = MediaGalleryArtifact.fromStagedShare(prepared.share,
                            mediaCaptureTimestampMillis(prepared.clip.captureDate).takeIf { configuration.includeMetadata })
                        val failure = saver.saveOne(artifact) { enteredContext.ensureActive() }
                        if (failure != null) failures += failure
                        failure == null
                    }
                },
                internet = route?.let { MonitorDeliveryInternetService(needsHop = { false },
                    begin = { error("This native run already owns its preparation route.") },
                    owns = frameioController::ownsInternetHop, wait = frameioController::waitInternetHop,
                    restoreEntered = { frameioController.endInternetHop(it) },
                    restore = frameioController::restoreInternetHopAfterDismiss) },
                initialLease = route,
                filename = { it.clip.filename }, artifactFilename = { it.share.displayName },
                metadata = { records -> if (configuration.includeMetadata) mediaDeliveryMetadataSummary(records.map { it.clip }) else null },
                policy = MonitorDeliveryBatchPolicy(
                    cacheFailure = { "${uncachedClipsMessage(it)} Check the camera connection and try again." },
                    emptySelection = "Nothing in the selection is ready to deliver.",
                    nativeSummary = { counts -> uncachedClipsMessage(counts.uncached).takeIf { counts.uncached > 0 } },
                    behavior = MonitorDeliveryBatchBehavior(photosFailures = MonitorDeliveryItemFailurePolicy.CONTINUE_ITEMS)),
                progress = { publish(it.nativeOverlay(destination)) })
            if (!run.isCurrent() || !completion.isCurrent()) return@beginNativeCaptured null
            when (outcome) {
                is MonitorDeliveryBatchOutcome.Share -> {
                    if (run.isCurrent() && completion.isCurrent()) withContext(Dispatchers.Main.immediate) {
                        if (run.isCurrent() && completion.isCurrent()) onShareReady?.invoke(outcome.urls.map { it.share }, outcome.metadataText)
                    }
                    null
                }
                is MonitorDeliveryBatchOutcome.SavedToPhotos -> MediaGalleryBatchResult(outcome.count, failures).operatorMessage(
                    MediaGalleryOmissions(nonVideoCount = selection.size - selected.size,
                        incompleteCount = selected.count { !originals.service.available(it) }))
                is MonitorDeliveryBatchOutcome.Failed -> outcome.message
                is MonitorDeliveryBatchOutcome.Uploaded -> outcome.summary
            }
            } finally {
                route?.let { frameioController.endInternetHop(it) }
            }
        }
    }
    private data class PreparedClip(val share: StagedMediaShare, val prepared: FrameioPreparedArtifact,
        val clip: NikonMediaClipRecord)
}

internal fun MonitorDeliveryBatchProgress.nativeOverlay(destination: MediaDeliveryKind): MediaDeliveryOverlayState =
    MediaDeliveryOverlayState(destination, totalClips, clipIndex, clipFraction, filename, isCaching)
