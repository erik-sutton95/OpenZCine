package com.opencapture.openzcine.media

import com.opencapture.openzcine.bridge.SwiftCore
import java.io.IOException
import kotlin.coroutines.CoroutineContext
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.delay
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.withContext

/** Narrow Kotlin adapter for Swift-owned generic object-transfer operations. */
internal interface MediaObjectTransferBridge {
    /** Whether the bundled Swift core can service a transfer request. */
    val isAvailable: Boolean

    /** Resolves the authoritative camera-object size before opening its cache entry. */
    fun resolveMediaSize(handle: Int, reportedSize: Long): Long

    /** Starts or resumes one Swift-serialized camera-object transfer. */
    fun startMediaTransfer(
        handle: Int,
        reportedSize: Long,
        resumeOffset: Long,
        listener: SwiftCore.MediaTransferListener,
    )

    /** Stops the in-flight transfer this bridge started; a synchronous fake has none. */
    fun stopMediaTransfer() = Unit
}

/** Production bridge that leaves all camera protocol work in the Swift core. */
private object SwiftCoreMediaObjectTransferBridge : MediaObjectTransferBridge {
    override val isAvailable: Boolean
        get() = SwiftCore.isAvailable

    override fun resolveMediaSize(handle: Int, reportedSize: Long): Long =
        SwiftCore.sessionResolveMediaSize(handle, reportedSize)

    override fun startMediaTransfer(
        handle: Int,
        reportedSize: Long,
        resumeOffset: Long,
        listener: SwiftCore.MediaTransferListener,
    ) {
        SwiftCore.sessionStartMediaTransfer(handle, reportedSize, resumeOffset, listener)
    }

    override fun stopMediaTransfer() {
        if (SwiftCore.isAvailable) SwiftCore.sessionStopMediaTransfer()
    }
}

/** One camera-object transfer's preparation result, shared by player and still viewer. */
internal sealed interface MediaTransferPreparation {
    data object Loading : MediaTransferPreparation

    data class Ready(val entry: MediaCacheEntry) : MediaTransferPreparation

    data class Failed(val message: String) : MediaTransferPreparation

    data object Cancelled : MediaTransferPreparation
}

/**
 * Serializes one media-transfer preparation and teardown sequence.
 *
 * Native preparation may start the transfer before it returns. Holding the
 * mutex across that setup makes a close wait for it, so teardown cannot race
 * ahead and leave a hidden transfer running.
 */
internal class MediaTransferCoordinator(
    private val prepareTransfer: suspend () -> MediaTransferPreparation,
    private val stopTransfer: suspend () -> Unit,
) {
    private val mutex = Mutex()
    private var closed = false

    suspend fun prepare(): MediaTransferPreparation {
        mutex.lock()
        return try {
            if (closed) MediaTransferPreparation.Cancelled else prepareTransfer()
        } finally {
            mutex.unlock()
        }
    }

    suspend fun close() {
        mutex.lock()
        try {
            if (closed) return
            closed = true
            stopTransfer()
        } finally {
            mutex.unlock()
        }
    }
}

/**
 * Opens the resumable private cache and starts one generic Swift-owned camera
 * object transfer for either proxy playback or still preview.
 *
 * Swift remains the source of truth for object-size resolution, standard vs.
 * Nikon extended partial reads, offset/chunk ordering, and camera-command
 * serialization. Kotlin only persists validated callbacks into the cache;
 * both media surfaces therefore share identical resume, cancellation, and
 * completion behavior.
 */
internal fun prepareMediaObjectTransfer(
    cacheStore: MediaCacheStore,
    cameraID: String,
    clip: MediaClipRecord,
    objectLabel: String,
    bridge: MediaObjectTransferBridge = SwiftCoreMediaObjectTransferBridge,
    cameraTransferAvailable: Boolean = true,
    onResolvedSize: (Long) -> Unit = {},
): MediaTransferPreparation {
    val cached =
        try {
            cacheStore.completedEntryOrNull(
                cameraID,
                MediaCacheObjectIdentity(clip),
                clip.sizeBytes,
            )
        } catch (error: Exception) {
            return MediaTransferPreparation.Failed(
                error.message ?: "Cached $objectLabel could not be opened.",
            )
        }
    // A validated final artifact is self-contained. Opening it must not depend
    // on a native library or active camera session, which is what makes the
    // saved-camera library useful after relaunch and while disconnected.
    if (cached != null) return MediaTransferPreparation.Ready(cached)
    if (!cameraTransferAvailable) {
        return MediaTransferPreparation.Failed("Cached $objectLabel is no longer available.")
    }
    if (!bridge.isAvailable) {
        return MediaTransferPreparation.Failed("Camera core is not bundled in this build.")
    }
    return try {
        val totalBytes = bridge.resolveMediaSize(clip.handle.toInt(), clip.sizeBytes)
        if (totalBytes < 0) throw IOException("Camera did not provide the $objectLabel size.")
        onResolvedSize(totalBytes)

        val entry = cacheStore.openEntry(cameraID, MediaCacheObjectIdentity(clip), totalBytes)
        when (entry.state) {
            MediaCacheState.FAILED,
            MediaCacheState.CANCELLED,
            -> entry.resume()
            MediaCacheState.ACTIVE,
            MediaCacheState.COMPLETE,
            -> Unit
        }
        if (entry.state != MediaCacheState.COMPLETE) {
            bridge.startMediaTransfer(
                handle = clip.handle.toInt(),
                reportedSize = totalBytes,
                resumeOffset = entry.downloadedBytes,
                listener = entry.mediaTransferListener(),
            )
        }
        MediaTransferPreparation.Ready(entry)
    } catch (error: Exception) {
        MediaTransferPreparation.Failed(error.message ?: "Camera $objectLabel could not be opened.")
    }
}

/** One operator-selected clip, before the run knows whether its bytes are already local. */
internal data class MediaDeliverySelection(
    val cameraID: String,
    val clip: MediaClipRecord,
)

/** What the delivery cache pre-pass produced, plus the clips the camera never handed over. */
internal data class MediaDeliveryCachePass(
    val items: List<MediaDeliveryWorkItem>,
    val uncachedCount: Int,
)

/**
 * Pulls every selected clip that has no complete cache artifact off the camera before delivery
 * starts (iOS `MediaDeliveryRunner`'s pre-pass, `MediaDeliveryOverlay.swift`). Without it the
 * delivery paths filtered the selection down to whatever happened to be cached already, so
 * selecting ten clips with two cached shared two and dropped eight without a word.
 *
 * Sequential by contract: the Swift core serializes one PTP data channel, so a parallel pass
 * would only queue behind itself. A clip the camera still refuses is counted, never dropped
 * silently, so the run can say how many did not come across.
 */
internal suspend fun cacheSelectionForDelivery(
    selection: List<MediaDeliverySelection>,
    cacheStore: MediaCacheStore,
    cameraTransferAvailable: Boolean,
    bridge: MediaObjectTransferBridge = SwiftCoreMediaObjectTransferBridge,
    ioContext: CoroutineContext = Dispatchers.IO,
    pollIntervalMillis: Long = CACHE_PASS_POLL_MILLIS,
    /** `(1-based index among clips being cached, count being cached, clip, 0…1)`. */
    onProgress: (Int, Int, MediaDeliverySelection, Double) -> Unit = { _, _, _, _ -> },
): MediaDeliveryCachePass {
    val resolved =
        withContext(ioContext) {
            selection.map { item -> completedDeliveryEntryOrNull(cacheStore, item) }
        }.toMutableList()
    val cachingCount = resolved.count { it == null }
    var cachingIndex = 0
    selection.forEachIndexed { index, item ->
        if (resolved[index] != null) return@forEachIndexed
        currentCoroutineContext().ensureActive()
        cachingIndex += 1
        if (!cameraTransferAvailable) return@forEachIndexed
        onProgress(cachingIndex, cachingCount, item, 0.0)
        val position = cachingIndex
        resolved[index] =
            cacheOneClipForDelivery(
                cacheStore = cacheStore,
                item = item,
                bridge = bridge,
                ioContext = ioContext,
                pollIntervalMillis = pollIntervalMillis,
                report = { fraction -> onProgress(position, cachingCount, item, fraction) },
            )
    }
    val items =
        selection.mapIndexedNotNull { index, item ->
            resolved[index]?.let { entry -> MediaDeliveryWorkItem(item.cameraID, item.clip, entry) }
        }
    return MediaDeliveryCachePass(items, uncachedCount = selection.size - items.size)
}

/** Operator sentence for a pre-pass that could not bring every selected clip across. */
internal fun uncachedClipsMessage(uncachedCount: Int): String =
    "$uncachedCount clip${if (uncachedCount == 1) "" else "s"} couldn't be cached from the camera."

private fun completedDeliveryEntryOrNull(
    cacheStore: MediaCacheStore,
    item: MediaDeliverySelection,
): MediaCacheEntry? =
    runCatching {
        cacheStore.completedEntryOrNull(
            item.cameraID,
            MediaCacheObjectIdentity(item.clip),
            item.clip.sizeBytes,
        )
    }.getOrNull()

/**
 * Streams one clip into the cache and waits for the validated final artifact. The entry itself
 * is the answer — it carries the length Swift resolved immediately before transfer, which a
 * fresh lookup keyed on the listing's 32-bit sentinel would reject.
 */
private suspend fun cacheOneClipForDelivery(
    cacheStore: MediaCacheStore,
    item: MediaDeliverySelection,
    bridge: MediaObjectTransferBridge,
    ioContext: CoroutineContext,
    pollIntervalMillis: Long,
    report: (Double) -> Unit,
): MediaCacheEntry? {
    val preparation =
        withContext(ioContext) {
            prepareMediaObjectTransfer(
                cacheStore = cacheStore,
                cameraID = item.cameraID,
                clip = item.clip,
                objectLabel = "clip",
                bridge = bridge,
            )
        }
    val entry = (preparation as? MediaTransferPreparation.Ready)?.entry ?: return null
    var completed = false
    try {
        while (true) {
            when (entry.state) {
                MediaCacheState.COMPLETE -> {
                    completed = true
                    return entry
                }
                MediaCacheState.FAILED,
                MediaCacheState.CANCELLED,
                -> return null
                MediaCacheState.ACTIVE -> {
                    report(entry.progress)
                    delay(pollIntervalMillis)
                }
            }
        }
    } finally {
        // A cancelled or failed clip must not leave the camera pumping bytes nobody is waiting
        // for; the resumable `.part` survives, exactly as when the player or viewer closes.
        if (!completed) withContext(NonCancellable + ioContext) { bridge.stopMediaTransfer() }
    }
}

private const val CACHE_PASS_POLL_MILLIS = 200L

/** Persists one Swift-owned generic object transfer into a validated cache entry. */
private fun MediaCacheEntry.mediaTransferListener(): SwiftCore.MediaTransferListener =
    object : SwiftCore.MediaTransferListener {
        override fun onStarted(totalBytes: Long) {
            if (totalBytes != expectedLength) {
                fail(MediaCacheLengthException(expectedLength, totalBytes))
            }
        }

        override fun onChunk(offset: Long, bytes: ByteArray): Boolean =
            try {
                append(offset, bytes)
                true
            } catch (error: Exception) {
                fail(error.asMediaTransferIOException())
                false
            }

        override fun onCompleted(totalBytes: Long) {
            try {
                if (totalBytes != expectedLength) {
                    throw MediaCacheLengthException(expectedLength, totalBytes)
                }
                complete()
            } catch (error: Exception) {
                fail(error.asMediaTransferIOException())
            }
        }

        override fun onStopped(cachedBytes: Long) {
            cancel()
        }

        override fun onFailed(message: String) {
            fail(IOException(message))
        }
    }

private fun Exception.asMediaTransferIOException(): IOException =
    this as? IOException ?: IOException(message ?: "Media cache write failed.", this)
