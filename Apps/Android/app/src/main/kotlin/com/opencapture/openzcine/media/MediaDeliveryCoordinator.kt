package com.opencapture.openzcine.media

import android.content.Context
import com.opencapture.openzcine.frameio.FrameioArtifactContext
import com.opencapture.openzcine.frameio.FrameioDeliveryArtifact
import com.opencapture.openzcine.frameio.FrameioDeliveryController
import com.opencapture.openzcine.frameio.FrameioDeliveryState
import com.opencapture.openzcine.frameio.FrameioPreparedArtifact
import com.opencapture.openzcine.frameio.MediaDeliveryConfiguration
import java.nio.file.Files
import kotlin.coroutines.coroutineContext
import kotlin.math.min
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.NonCancellable
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
    val clip: MediaClipRecord,
    val entry: MediaCacheEntry,
)

/**
 * Owns share / gallery-save / Frame.io prep progress independently of any
 * Compose media surface. [MainActivity] hosts the global overlay; media
 * screens can render a local copy while they are visible.
 */
internal class MediaDeliveryCoordinator(
    private val appContext: Context,
    private val frameioController: FrameioDeliveryController,
    private val galleryGateway: MediaGalleryGateway = AndroidMediaGalleryGateway(appContext.contentResolver),
    scope: CoroutineScope,
) {
    private val presentation = NikonDeliveryPresentation(scope)
    val display get() = presentation.display

    /** Cache pre-pass store; the same private root the media surfaces resolve artifacts from. */
    private val cacheStore: MediaCacheStore by lazy {
        MediaCacheStore(appContext.noBackupFilesDir.resolve("media-cache").toPath())
    }

    val overlayState: MediaDeliveryOverlayState? get() = presentation.overlayState
    val completionToast: String? get() = presentation.completionToast
    var isExpanded: Boolean
        get() = presentation.isExpanded
        set(value) { presentation.isExpanded = value }
    val isActive: Boolean get() = overlayState != null
    fun dismissToast() = presentation.dismissToast()
    fun cancel() = presentation.cancel()
    fun close() = presentation.close()
    fun trackExternalDelivery(job: Job?): NikonDeliveryPresentation.ExternalTicket =
        presentation.trackExternalDelivery(job)
    fun finishExternalDelivery(ticket: NikonDeliveryPresentation.ExternalTicket) =
        presentation.finishExternalDelivery(ticket)

    /**
     * Caches the selection from the camera and reports it on the shared overlay, for the one
     * destination whose upload the media surface still drives itself (Frame.io).
     */
    suspend fun cacheFromCamera(
        destination: MediaDeliveryKind,
        selection: List<MediaDeliverySelection>,
        cameraConnectionOwner: Long?,
        ticket: NikonDeliveryPresentation.ExternalTicket? = null,
    ): MediaDeliveryCachePass {
        // The popup pre-hop cache has no upload Job yet; it owns only captured preparation facts.
        val captured = ticket ?: presentation.trackExternalDelivery(null)
        return runCachePass(destination, selection, cameraConnectionOwner) { progress ->
            presentation.publishCache(captured, progress)
        }
    }

    /**
     * Stages complete cache entries, optionally bakes a LUT, then opens the
     * system share sheet. Progress is published for the full prep path.
     */
    fun beginNativeShare(
        selection: List<MediaDeliverySelection>,
        configuration: MediaDeliveryConfiguration,
        cameraConnectionOwner: Long?,
        onShareReady: (List<StagedMediaShare>, String?) -> Unit,
    ) {
        if (selection.isEmpty()) return
        start(
            destination = MediaDeliveryKind.NATIVE_SHARE,
            selection = selection,
            configuration = configuration,
            cameraConnectionOwner = cameraConnectionOwner,
        ) { prepared, items, uncachedCount, publish ->
            coroutineContext.ensureActive()
            publish(
                MediaDeliveryOverlayState(
                    destination = MediaDeliveryKind.NATIVE_SHARE,
                    totalClips = items.size,
                    clipIndex = items.size,
                    clipFraction = 1.0,
                    filename = items.last().clip.filename,
                ),
            )
            // A clip the camera wouldn't hand over rides along in the share text rather than
            // disappearing between selection and chooser (iOS `partialNote`).
            val metadata =
                listOfNotNull(
                    uncachedClipsMessage(uncachedCount).takeIf { uncachedCount > 0 },
                    mediaDeliveryMetadataSummary(items.map { it.clip })
                        .takeIf { configuration.includeMetadata },
                ).joinToString(separator = "\n").ifEmpty { null }
            val shareCache = appContext.cacheDir.toPath()
            val stager = MediaShareStager(shareCache)
            try {
                val published =
                    withContext(Dispatchers.IO) {
                        prepared.map { item ->
                            if (item.prepared.transientExport == null) {
                                item.share
                            } else {
                                stager.stagePreparedArtifact(
                                    source = item.share.file,
                                    expectedBytes = item.prepared.byteCount,
                                    displayName = item.share.displayName,
                                    mimeType = item.share.mimeType,
                                ) {
                                    coroutineContext.ensureActive()
                                }
                            }
                        }
                    }
                withContext(Dispatchers.Main.immediate) {
                    coroutineContext.ensureActive()
                    onShareReady(published, metadata)
                }
                null
            } finally {
                cleanupPrepared(prepared)
            }
        }
    }

    /** Stages + optional LUT bake, then writes complete videos to Gallery. */
    fun beginSaveToPhotos(
        selection: List<MediaDeliverySelection>,
        configuration: MediaDeliveryConfiguration,
        cameraConnectionOwner: Long?,
    ) {
        if (selection.isEmpty()) return
        val savableSelection =
            selection.filter {
                it.clip.contentKind == MediaContentKind.PLAYABLE_PROXY ||
                    it.clip.contentKind == MediaContentKind.STILL_PHOTO
            }
        if (savableSelection.isEmpty()) {
            presentation.showToast("No video or photo in the selection can be saved to Gallery.")
            return
        }
        start(
            destination = MediaDeliveryKind.SAVE_TO_PHOTOS,
            selection = savableSelection,
            configuration = configuration,
            cameraConnectionOwner = cameraConnectionOwner,
        ) { prepared, items, uncachedCount, publish ->
            coroutineContext.ensureActive()
            publish(
                MediaDeliveryOverlayState(
                    destination = MediaDeliveryKind.SAVE_TO_PHOTOS,
                    totalClips = items.size,
                    clipIndex = items.size,
                    clipFraction = 0.85,
                    filename = items.last().clip.filename,
                ),
            )
            val artifacts =
                prepared.mapIndexed { index, preparedArtifact ->
                    MediaGalleryArtifact.fromStagedShare(
                        preparedArtifact.share,
                        mediaCaptureTimestampMillis(items[index].clip.captureDate)
                            .takeIf { configuration.includeMetadata },
                    )
                }
            try {
                val result =
                    withContext(Dispatchers.IO) {
                        MediaGallerySaver(galleryGateway).save(artifacts) {
                            coroutineContext.ensureActive()
                        }
                    }
                coroutineContext.ensureActive()
                result.operatorMessage(
                            MediaGalleryOmissions(
                                nonVideoCount = selection.size - savableSelection.size,
                                incompleteCount = uncachedCount,
                            ),
                        )
            } finally {
                cleanupPrepared(prepared)
            }
        }
    }

    fun bindFrameioDeliveryState(
        ticket: NikonDeliveryPresentation.ExternalTicket,
        state: FrameioDeliveryState,
    ) = presentation.bindFrameioDeliveryState(ticket, state)

    /** Publishes the sequential camera-cache pre-pass on the shared overlay (iOS `isCaching`). */
    private suspend fun runCachePass(
        destination: MediaDeliveryKind,
        selection: List<MediaDeliverySelection>,
        cameraConnectionOwner: Long?,
        publish: (MediaDeliveryOverlayState) -> Unit,
    ): MediaDeliveryCachePass =
        cacheSelectionForDelivery(
            selection = selection,
            cacheStore = cacheStore,
            cameraTransferAvailable = cameraConnectionOwner != null,
            bridge = SwiftCoreMediaObjectTransferBridge(cameraConnectionOwner),
        ) { index, count, item, fraction ->
            publish(
                MediaDeliveryOverlayState(
                    destination = destination,
                    totalClips = count,
                    clipIndex = index,
                    clipFraction = fraction,
                    filename = item.clip.filename,
                    isCaching = true,
                ),
            )
        }

    private fun start(
        destination: MediaDeliveryKind,
        selection: List<MediaDeliverySelection>,
        configuration: MediaDeliveryConfiguration,
        cameraConnectionOwner: Long?,
        afterPrepare: suspend (List<PreparedClip>, List<MediaDeliveryWorkItem>, Int,
            (MediaDeliveryOverlayState) -> Unit) -> String?,
    ) {
        presentation.beginNative { publish ->
            publish(MediaDeliveryOverlayState(destination, selection.size, 1, 0.0,
                selection.first().clip.filename))
            val shareCache = appContext.cacheDir.toPath()
            val stager = MediaShareStager(shareCache)
            val prepared = ArrayList<PreparedClip>(selection.size)
            try {
                val pass = runCachePass(destination, selection, cameraConnectionOwner, publish)
                val items = pass.items
                coroutineContext.ensureActive()
                if (items.isEmpty()) {
                    return@beginNative if (pass.uncachedCount > 0) {
                        "${uncachedClipsMessage(pass.uncachedCount)} " +
                            "Check the camera connection and try again."
                    } else {
                        "Nothing in the selection is ready to deliver."
                    }
                }
                items.forEachIndexed { index, item ->
                    coroutineContext.ensureActive()
                    publish(
                        MediaDeliveryOverlayState(
                            destination = destination,
                            totalClips = items.size,
                            clipIndex = index + 1,
                            clipFraction = 0.0,
                            filename = item.clip.filename,
                        ),
                    )
                    val staged =
                        withContext(Dispatchers.IO) {
                            stager.stage(item.entry, item.clip) {
                                coroutineContext.ensureActive()
                            }
                        }
                    val artifact =
                        FrameioDeliveryArtifact(
                            share = staged,
                            byteCount = withContext(Dispatchers.IO) { Files.size(staged.file) },
                            context =
                                FrameioArtifactContext(
                                    cameraID = item.cameraID,
                                    captureDate = item.clip.captureDate,
                                    supportsLutBake =
                                        item.clip.contentKind ==
                                            MediaContentKind.PLAYABLE_PROXY,
                                    stableClipIdentity =
                                        item.clip.libraryKey(item.cameraID),
                                ),
                        )
                    val baked =
                        frameioController.prepareForExternalDelivery(
                            artifact,
                            configuration,
                        ) { fraction ->
                            coroutineContext.ensureActive()
                            publish(
                                MediaDeliveryOverlayState(
                                    destination = destination,
                                    totalClips = items.size,
                                    clipIndex = index + 1,
                                    clipFraction = fraction.coerceIn(0.0, 1.0),
                                    filename = item.clip.filename,
                                ),
                            )
                        }
                    prepared += PreparedClip(share = baked.share, prepared = baked)
                }
                afterPrepare(prepared, items, pass.uncachedCount, publish)
            } catch (error: CancellationException) {
                cleanupPrepared(prepared)
                throw error
            } catch (error: Exception) {
                cleanupPrepared(prepared)
                error.message ?: "Couldn't prepare media for delivery."
            }
        }
    }

    private suspend fun cleanupPrepared(prepared: List<PreparedClip>) {
        withContext(NonCancellable) {
            prepared.forEach { item ->
                runCatching { frameioController.releaseExternalDelivery(item.prepared) }
            }
        }
    }

    private data class PreparedClip(
        val share: StagedMediaShare,
        val prepared: FrameioPreparedArtifact,
    )
}
