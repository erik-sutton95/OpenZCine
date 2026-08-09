package com.opencapture.openzcine.media

import android.content.Context
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import com.opencapture.openzcine.frameio.FrameioArtifactContext
import com.opencapture.openzcine.frameio.FrameioDeliveryArtifact
import com.opencapture.openzcine.frameio.FrameioDeliveryController
import com.opencapture.openzcine.frameio.FrameioDeliveryState
import com.opencapture.openzcine.frameio.FrameioPreparedArtifact
import com.opencapture.openzcine.frameio.MediaDeliveryConfiguration
import java.nio.file.Files
import java.util.concurrent.atomic.AtomicLong
import kotlin.coroutines.coroutineContext
import kotlin.math.min
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.delay
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.launch
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
) {
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)
    private val generation = AtomicLong(0L)
    private var workJob: Job? = null

    /**
     * The Frame.io run stays on the media surface that owns the network hop, project pick, and
     * result sentence — but the overlay's Cancel is here, so the running job is registered here
     * too. Cancelling only [workJob] (null for the whole upload) left Cancel doing nothing while
     * a multi-gigabyte upload continued.
     */
    private var externalJob: Job? = null

    /** Cache pre-pass store; the same private root the media surfaces resolve artifacts from. */
    private val cacheStore: MediaCacheStore by lazy {
        MediaCacheStore(appContext.noBackupFilesDir.resolve("media-cache").toPath())
    }

    var overlayState by mutableStateOf<MediaDeliveryOverlayState?>(null)
        private set
    var completionToast by mutableStateOf<String?>(null)
        private set
    var isExpanded by mutableStateOf(false)

    val isActive: Boolean
        get() = overlayState != null

    fun dismissToast() {
        completionToast = null
    }

    fun cancel() {
        generation.incrementAndGet()
        workJob?.cancel()
        workJob = null
        externalJob?.cancel()
        externalJob = null
        overlayState = null
        isExpanded = false
    }

    /**
     * Registers the media surface's Frame.io job so [cancel] reaches the upload it is narrating.
     * Pass null when that job finishes.
     */
    fun trackExternalDelivery(job: Job?) {
        externalJob = job
        // A run that ends during the cache pre-pass — nothing cached, so no upload state ever
        // follows — must still take its own progress bar down.
        if (job == null && overlayState?.isCaching == true && workJob?.isActive != true) {
            overlayState = null
            isExpanded = false
        }
    }

    /**
     * Caches the selection from the camera and reports it on the shared overlay, for the one
     * destination whose upload the media surface still drives itself (Frame.io).
     */
    suspend fun cacheFromCamera(
        destination: MediaDeliveryKind,
        selection: List<MediaDeliverySelection>,
        cameraTransferAvailable: Boolean,
    ): MediaDeliveryCachePass = runCachePass(destination, selection, cameraTransferAvailable)

    /**
     * Stages complete cache entries, optionally bakes a LUT, then opens the
     * system share sheet. Progress is published for the full prep path.
     */
    fun beginNativeShare(
        selection: List<MediaDeliverySelection>,
        configuration: MediaDeliveryConfiguration,
        cameraTransferAvailable: Boolean,
        onShareReady: (List<StagedMediaShare>, String?) -> Unit,
    ) {
        if (selection.isEmpty()) return
        start(
            destination = MediaDeliveryKind.NATIVE_SHARE,
            selection = selection,
            configuration = configuration,
            cameraTransferAvailable = cameraTransferAvailable,
        ) { prepared, items, uncachedCount, gen ->
            if (generation.get() != gen) return@start
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
                    if (generation.get() != gen) return@withContext
                    onShareReady(published, metadata)
                }
                finish(gen, toast = null)
            } finally {
                cleanupPrepared(prepared)
            }
        }
    }

    /** Stages + optional LUT bake, then writes complete videos to Gallery. */
    fun beginSaveToPhotos(
        selection: List<MediaDeliverySelection>,
        configuration: MediaDeliveryConfiguration,
        cameraTransferAvailable: Boolean,
    ) {
        if (selection.isEmpty()) return
        val savableSelection =
            selection.filter {
                it.clip.contentKind == MediaContentKind.PLAYABLE_PROXY ||
                    it.clip.contentKind == MediaContentKind.STILL_PHOTO
            }
        if (savableSelection.isEmpty()) {
            showToast("No video or photo in the selection can be saved to Gallery.")
            return
        }
        start(
            destination = MediaDeliveryKind.SAVE_TO_PHOTOS,
            selection = savableSelection,
            configuration = configuration,
            cameraTransferAvailable = cameraTransferAvailable,
        ) { prepared, items, uncachedCount, gen ->
            if (generation.get() != gen) return@start
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
                if (generation.get() != gen) return@start
                finish(
                    gen,
                    toast =
                        result.operatorMessage(
                            MediaGalleryOmissions(
                                nonVideoCount = selection.size - savableSelection.size,
                                incompleteCount = uncachedCount,
                            ),
                        ),
                )
            } finally {
                cleanupPrepared(prepared)
            }
        }
    }

    /**
     * Mirrors [FrameioDeliveryController.deliveryState] into the same overlay
     * so Frame.io uploads use one persistent chrome style.
     */
    fun bindFrameioDeliveryState(state: FrameioDeliveryState) {
        when (state) {
            is FrameioDeliveryState.Uploading -> {
                if (workJob?.isActive == true) return
                publish(
                    MediaDeliveryOverlayState(
                        destination = MediaDeliveryKind.FRAMEIO,
                        totalClips = state.itemCount,
                        clipIndex = state.itemIndex,
                        clipFraction = state.progress.coerceIn(0.0, 1.0),
                        filename = state.filename,
                    ),
                )
            }
            is FrameioDeliveryState.Completed -> {
                if (workJob?.isActive == true) return
                overlayState = null
                isExpanded = false
                showToast(
                    buildString {
                        append("Uploaded ${state.uploadedCount}")
                        if (state.failedCount > 0) append(", ${state.failedCount} failed")
                        if (state.skippedCount > 0) append(", ${state.skippedCount} skipped")
                    },
                )
            }
            is FrameioDeliveryState.Failed -> {
                if (workJob?.isActive == true) return
                overlayState = null
                isExpanded = false
                showToast(state.message)
            }
            FrameioDeliveryState.Idle -> {
                // Idle also arrives while the media surface is still caching this run's clips
                // from the camera; clearing then would erase the pre-pass overlay mid-transfer.
                if (workJob?.isActive != true && externalJob?.isActive != true) {
                    // Leave toast alone; only clear active bar when idle and no local job.
                    if (overlayState?.destination == MediaDeliveryKind.FRAMEIO) {
                        overlayState = null
                        isExpanded = false
                    }
                }
            }
        }
    }

    /** Publishes the sequential camera-cache pre-pass on the shared overlay (iOS `isCaching`). */
    private suspend fun runCachePass(
        destination: MediaDeliveryKind,
        selection: List<MediaDeliverySelection>,
        cameraTransferAvailable: Boolean,
    ): MediaDeliveryCachePass =
        cacheSelectionForDelivery(
            selection = selection,
            cacheStore = cacheStore,
            cameraTransferAvailable = cameraTransferAvailable,
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
        cameraTransferAvailable: Boolean,
        afterPrepare: suspend (List<PreparedClip>, List<MediaDeliveryWorkItem>, Int, Long) -> Unit,
    ) {
        val gen = generation.incrementAndGet()
        workJob?.cancel()
        isExpanded = false
        publish(
            MediaDeliveryOverlayState(
                destination = destination,
                totalClips = selection.size,
                clipIndex = 1,
                clipFraction = 0.0,
                filename = selection.first().clip.filename,
            ),
        )
        workJob =
            scope.launch {
                val shareCache = appContext.cacheDir.toPath()
                val stager = MediaShareStager(shareCache)
                val prepared = ArrayList<PreparedClip>(selection.size)
                try {
                    // One job spans cache → export → hand-off, so Cancel stops the whole run.
                    val pass = runCachePass(destination, selection, cameraTransferAvailable)
                    val items = pass.items
                    if (generation.get() != gen) return@launch
                    if (items.isEmpty()) {
                        finish(
                            gen,
                            toast =
                                if (pass.uncachedCount > 0) {
                                    "${uncachedClipsMessage(pass.uncachedCount)} " +
                                        "Check the camera connection and try again."
                                } else {
                                    "Nothing in the selection is ready to deliver."
                                },
                        )
                        return@launch
                    }
                    items.forEachIndexed { index, item ->
                        ensureActive()
                        if (generation.get() != gen) return@launch
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
                                if (generation.get() != gen) return@prepareForExternalDelivery
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
                    afterPrepare(prepared, items, pass.uncachedCount, gen)
                } catch (error: CancellationException) {
                    cleanupPrepared(prepared)
                    if (generation.get() == gen) {
                        overlayState = null
                        isExpanded = false
                    }
                    throw error
                } catch (error: Exception) {
                    cleanupPrepared(prepared)
                    if (generation.get() == gen) {
                        finish(
                            gen,
                            toast = error.message ?: "Couldn't prepare media for delivery.",
                        )
                    }
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

    private fun finish(gen: Long, toast: String?) {
        if (generation.get() != gen) return
        workJob = null
        overlayState = null
        isExpanded = false
        if (toast != null) showToast(toast)
    }

    private fun publish(state: MediaDeliveryOverlayState) {
        overlayState = state
    }

    private fun showToast(message: String) {
        completionToast = message
        scope.launch {
            delay(2_500)
            if (completionToast == message) completionToast = null
        }
    }

    private data class PreparedClip(
        val share: StagedMediaShare,
        val prepared: FrameioPreparedArtifact,
    )
}
