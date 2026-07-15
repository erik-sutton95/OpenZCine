package com.opencapture.openzcine.media

import com.opencapture.openzcine.bridge.SwiftCore
import kotlin.coroutines.CoroutineContext
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.withContext
import kotlinx.coroutines.yield

/** Stable object identity shared by page additions and R3D-pair removals. */
internal data class MediaObjectIdentity(val storageID: Long, val handle: Long)

/** One decoded page from the shared Swift media-browse cursor. */
internal data class MediaBrowsePage(
    val clips: List<MediaClipRecord>,
    val removedObjects: List<MediaObjectIdentity>,
    val inspectedObjectCount: Int,
    val hasMore: Boolean,
)

/** Incremental catalog state delivered to the Compose media browser. */
internal data class MediaBrowseSnapshot(
    val clips: List<MediaClipRecord>,
    val removedObjects: List<MediaObjectIdentity>,
    val hasMore: Boolean,
)

/** Stable parser for `MediaBrowsePageWire` from the Swift facade. */
internal object MediaBrowsePages {
    private const val VERSION = "OZCMEDIA1"
    private const val MAXIMUM_PAGE_SIZE = 128

    fun parse(wire: String): MediaBrowsePage? {
        val lines = wire.split('\n')
        val header = lines.firstOrNull()?.split('\t') ?: return null
        if (header.size != 4 || header[0] != VERSION) return null
        val hasMore =
            when (header[1]) {
                "0" -> false
                "1" -> true
                else -> return null
            }
        val inspectedObjectCount =
            header[2].toIntOrNull()?.takeIf { it in 0..MAXIMUM_PAGE_SIZE } ?: return null
        val removalCount =
            header[3].toIntOrNull()?.takeIf { it in 0..MAXIMUM_PAGE_SIZE } ?: return null
        if (lines.size < 1 + removalCount) return null
        val removedObjects =
            lines.drop(1).take(removalCount).map { line ->
                val fields = line.split('\t')
                if (fields.size != 3 || fields[0] != "-") return null
                MediaObjectIdentity(
                    storageID = fields[1].unsignedObjectValueOrNull() ?: return null,
                    handle = fields[2].unsignedObjectValueOrNull() ?: return null,
                )
            }
        val records = lines.drop(1 + removalCount).joinToString(separator = "\n")
        val clips = MediaClips.parse(records)
        if (clips.size + removedObjects.size > MAXIMUM_PAGE_SIZE) return null
        return MediaBrowsePage(
            clips = clips,
            removedObjects = removedObjects,
            inspectedObjectCount = inspectedObjectCount,
            hasMore = hasMore,
        )
    }
}

/** Small injectable boundary around the three blocking JNI cursor calls. */
internal interface MediaBrowseGateway {
    fun begin(): Long

    fun next(cursor: Long, maxObjects: Int): String?

    fun cancel(cursor: Long)
}

private object SwiftMediaBrowseGateway : MediaBrowseGateway {
    override fun begin(): Long = SwiftCore.sessionBeginMediaBrowse()

    override fun next(cursor: Long, maxObjects: Int): String? =
        SwiftCore.sessionNextMediaBrowsePage(cursor, maxObjects)

    override fun cancel(cursor: Long) = SwiftCore.sessionCancelMediaBrowse(cursor)
}

/** Sanitized failure from an incomplete or malformed native listing pass. */
internal class MediaBrowsePagingException(message: String) : IllegalStateException(message)

/**
 * Collects every bounded native page, publishing the growing newest-first
 * catalog after each one. JNI work runs off-main; cancellation is checked on
 * both sides of every page and always invalidates the native cursor.
 */
internal suspend fun loadCameraMediaPages(
    pageSize: Int,
    gateway: MediaBrowseGateway = SwiftMediaBrowseGateway,
    ioContext: CoroutineContext = Dispatchers.IO,
    onPage: suspend (MediaBrowseSnapshot) -> Unit,
): List<MediaClipRecord> {
    require(pageSize in 1..128) { "Camera media page size must be between 1 and 128." }
    val cursor = withContext(ioContext) { gateway.begin() }
    if (cursor <= 0) throw MediaBrowsePagingException("Camera media listing could not start.")

    val clipsByIdentity = LinkedHashMap<MediaObjectIdentity, MediaClipRecord>()
    try {
        while (true) {
            currentCoroutineContext().ensureActive()
            val wire =
                withContext(ioContext) { gateway.next(cursor, pageSize) }
                    ?: throw MediaBrowsePagingException("Camera media listing stopped early.")
            currentCoroutineContext().ensureActive()
            val page =
                MediaBrowsePages.parse(wire)
                    ?: throw MediaBrowsePagingException("Camera returned an invalid media page.")
            if (
                page.inspectedObjectCount > pageSize ||
                    page.clips.size + page.removedObjects.size > pageSize
            ) {
                throw MediaBrowsePagingException("Camera exceeded the requested media page size.")
            }
            page.clips.forEach { clip ->
                clipsByIdentity[MediaObjectIdentity(clip.storageId, clip.handle)] = clip
            }
            page.removedObjects.forEach(clipsByIdentity::remove)
            val clips = MediaClips.newestFirst(clipsByIdentity.values.toList())
            onPage(
                MediaBrowseSnapshot(
                    clips = clips,
                    removedObjects = page.removedObjects,
                    hasMore = page.hasMore,
                ),
            )
            if (!page.hasMore) return clips
            yield()
        }
    } finally {
        withContext(ioContext + NonCancellable) { gateway.cancel(cursor) }
    }
}

private fun String.unsignedObjectValueOrNull(): Long? =
    toLongOrNull()?.takeIf { it in 0..0xFFFF_FFFFL }
