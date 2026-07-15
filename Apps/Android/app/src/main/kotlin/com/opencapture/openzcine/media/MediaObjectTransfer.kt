package com.opencapture.openzcine.media

import com.opencapture.openzcine.bridge.SwiftCore
import java.io.IOException
import kotlinx.coroutines.sync.Mutex

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
