package com.opencapture.openzcine.media

import com.opencapture.openzcine.bridge.CameraPropertySnapshotWire
import com.opencapture.openzcine.bridge.NativePropertyRefreshResult
import com.opencapture.openzcine.bridge.SwiftCore
import com.opencapture.openzcine.core.CameraStorageSlotStatus
import kotlin.coroutines.CoroutineContext
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.withContext
import kotlinx.coroutines.yield

/** Stable persisted identity shared by page additions and R3D-pair removals. */
internal data class MediaObjectIdentity(
    val storageID: Long,
    val handle: Long,
    val captureDate: String,
    val filename: String,
) {
    constructor(clip: MediaClipRecord) :
        this(clip.storageId, clip.handle, clip.captureDate, clip.filename)
}

/** One decoded page from the shared Swift media-browse cursor. */
internal data class MediaBrowsePage(
    val clips: List<MediaClipRecord>,
    val removedObjects: List<MediaObjectIdentity>,
    val inspectedObjectCount: Int,
    val hasMore: Boolean,
)

/** Incremental catalog state delivered to the Compose media browser. */
internal data class MediaBrowseSnapshot(
    /** Full newest-first catalog for the incremental Compose presentation. */
    val clips: List<MediaClipRecord>,
    /** Additions from this native page only, for bounded persistence work. */
    val addedClips: List<MediaClipRecord>,
    val removedObjects: List<MediaObjectIdentity>,
    val hasMore: Boolean,
)

/** One native cursor and the card generation captured before media ownership. */
internal data class MediaBrowseStart(
    val cursor: Long,
    val storageSlots: List<CameraStorageSlotStatus>,
)

/** Stable parser for `MediaBrowseStartWire` from the Swift facade. */
internal object MediaBrowseStarts {
    private const val VERSION = "OZCMEDIASTART1"

    fun parse(wire: String?): MediaBrowseStart? {
        val separator = wire?.indexOf('\n')?.takeIf { it > 0 } ?: return null
        val header = wire.substring(0, separator).split('\t')
        if (header.size != 2 || header[0] != VERSION) return null
        val cursor = header[1].toLongOrNull()?.takeIf { it > 0 } ?: return null
        val readback = CameraPropertySnapshotWire.decode(wire.substring(separator + 1))
        if (!readback.isValid || readback.result != NativePropertyRefreshResult.MEDIA_BUSY) {
            return null
        }
        return MediaBrowseStart(cursor, readback.snapshot.storageSlots)
    }
}

/** Stable parser for `MediaBrowsePageWire` from the Swift facade. */
internal object MediaBrowsePages {
    private const val VERSION = "OZCMEDIA2"
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
                if (fields.size != 5 || fields[0] != "-") return null
                MediaObjectIdentity(
                    storageID = fields[1].unsignedObjectValueOrNull() ?: return null,
                    handle = fields[2].unsignedObjectValueOrNull() ?: return null,
                    captureDate = fields[3],
                    filename = fields[4].ifEmpty { return null },
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
    fun begin(): String?

    fun next(cursor: Long, maxObjects: Int): String?

    fun cancel(cursor: Long)
}

private object SwiftMediaBrowseGateway : MediaBrowseGateway {
    override fun begin(): String? = SwiftCore.sessionBeginMediaBrowse()

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
    onStart: suspend (List<CameraStorageSlotStatus>) -> Unit = {},
    onPage: suspend (MediaBrowseSnapshot) -> Unit,
): List<MediaClipRecord> {
    require(pageSize in 1..128) { "Camera media page size must be between 1 and 128." }
    var cursor = -1L
    try {
        val start =
            withContext(ioContext) {
                val parsed =
                    MediaBrowseStarts.parse(gateway.begin())
                        ?: throw MediaBrowsePagingException("Camera media listing could not start.")
                cursor = parsed.cursor
                parsed
            }
        onStart(start.storageSlots)

        val clipsByIdentity = LinkedHashMap<MediaObjectIdentity, MediaClipRecord>()
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
                clipsByIdentity[MediaObjectIdentity(clip)] = clip
            }
            page.removedObjects.forEach(clipsByIdentity::remove)
            val clips = MediaClips.newestFirst(clipsByIdentity.values.toList())
            onPage(
                MediaBrowseSnapshot(
                    clips = clips,
                    addedClips = page.clips,
                    removedObjects = page.removedObjects,
                    hasMore = page.hasMore,
                ),
            )
            if (!page.hasMore) return clips
            yield()
        }
    } finally {
        if (cursor > 0) {
            withContext(ioContext + NonCancellable) { gateway.cancel(cursor) }
        }
    }
}

private fun String.unsignedObjectValueOrNull(): Long? =
    toLongOrNull()?.takeIf { it in 0..0xFFFF_FFFFL }
