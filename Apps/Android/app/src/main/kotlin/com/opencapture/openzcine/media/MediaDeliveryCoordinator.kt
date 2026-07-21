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
        overlayState = null
        isExpanded = false
    }

    /**
     * Stages complete cache entries, optionally bakes a LUT, then opens the
     * system share sheet. Progress is published for the full prep path.
     */
    fun beginNativeShare(
        items: List<MediaDeliveryWorkItem>,
        configuration: MediaDeliveryConfiguration,
        onShareReady: (List<StagedMediaShare>, String?) -> Unit,
    ) {
        if (items.isEmpty()) return
        start(
            destination = MediaDeliveryKind.NATIVE_SHARE,
            items = items,
            configuration = configuration,
        ) { prepared, gen ->
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
            val metadata =
                mediaDeliveryMetadataSummary(items.map { it.clip })
                    .takeIf { configuration.includeMetadata }
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
        items: List<MediaDeliveryWorkItem>,
        configuration: MediaDeliveryConfiguration,
    ) {
        if (items.isEmpty()) return
        val videoItems =
            items.filter { it.clip.contentKind == MediaContentKind.PLAYABLE_PROXY }
        if (videoItems.isEmpty()) {
            showToast("No complete cached video is ready. Non-video items stay private.")
            return
        }
        start(
            destination = MediaDeliveryKind.SAVE_TO_PHOTOS,
            items = videoItems,
            configuration = configuration,
        ) { prepared, gen ->
            if (generation.get() != gen) return@start
            publish(
                MediaDeliveryOverlayState(
                    destination = MediaDeliveryKind.SAVE_TO_PHOTOS,
                    totalClips = videoItems.size,
                    clipIndex = videoItems.size,
                    clipFraction = 0.85,
                    filename = videoItems.last().clip.filename,
                ),
            )
            val artifacts =
                prepared.mapIndexed { index, preparedArtifact ->
                    MediaGalleryArtifact.fromStagedShare(
                        preparedArtifact.share,
                        mediaCaptureTimestampMillis(videoItems[index].clip.captureDate)
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
                finish(gen, toast = result.operatorMessage(MediaGalleryOmissions()))
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
                if (workJob?.isActive != true) {
                    // Leave toast alone; only clear active bar when idle and no local job.
                    if (overlayState?.destination == MediaDeliveryKind.FRAMEIO) {
                        overlayState = null
                        isExpanded = false
                    }
                }
            }
        }
    }

    private fun start(
        destination: MediaDeliveryKind,
        items: List<MediaDeliveryWorkItem>,
        configuration: MediaDeliveryConfiguration,
        afterPrepare: suspend (List<PreparedClip>, Long) -> Unit,
    ) {
        val gen = generation.incrementAndGet()
        workJob?.cancel()
        isExpanded = false
        publish(
            MediaDeliveryOverlayState(
                destination = destination,
                totalClips = items.size,
                clipIndex = 1,
                clipFraction = 0.0,
                filename = items.first().clip.filename,
            ),
        )
        workJob =
            scope.launch {
                val shareCache = appContext.cacheDir.toPath()
                val stager = MediaShareStager(shareCache)
                val prepared = ArrayList<PreparedClip>(items.size)
                try {
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
                    afterPrepare(prepared, gen)
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
