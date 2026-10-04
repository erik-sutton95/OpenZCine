package com.opencapture.openzcine.media

import kotlin.coroutines.CoroutineContext
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.sync.withLock

typealias MediaObjectIdentity = com.opencapture.opencine.nikon.NikonMediaObjectIdentity
typealias MediaBrowsePage = com.opencapture.opencine.nikon.NikonMediaBrowsePage
typealias MediaBrowseSnapshot = com.opencapture.opencine.nikon.NikonMediaBrowseSnapshot
typealias MediaBrowseStart = com.opencapture.opencine.nikon.NikonMediaBrowseStart
typealias MediaBrowseGateway = com.opencapture.opencine.nikon.NikonMediaBrowseGateway
typealias MediaBrowsePagingException = com.opencapture.opencine.nikon.NikonMediaBrowsePagingException

internal object MediaBrowseStarts {
    fun parse(wire: String?): MediaBrowseStart? = com.opencapture.opencine.nikon.NikonMediaBrowseStarts.parse(wire)
}
internal object MediaBrowsePages {
    fun parse(wire: String): MediaBrowsePage? = com.opencapture.opencine.nikon.NikonMediaBrowsePages.parse(wire)
}

/** Legacy primitive JNI facade retained for unmigrated callers; no parser, pager or gallery owner. */
internal class SwiftMediaBrowseGateway(private val connectionOwner: Long?) : MediaBrowseGateway {
    override fun begin(): String? = connectionOwner?.let(com.opencapture.opencine.nikon.NikonNative::sessionBeginMediaBrowse)

    override fun next(cursor: Long, maxObjects: Int): String? =
        com.opencapture.opencine.nikon.NikonNative.sessionNextMediaBrowsePage(cursor, maxObjects)

    override fun cancel(cursor: Long) = com.opencapture.opencine.nikon.NikonNative.sessionCancelMediaBrowse(cursor)
}


/** Original tests and unmigrated helpers delegate to the same real producer pager. */
internal suspend fun loadCameraMediaPages(
    pageSize: Int, gateway: MediaBrowseGateway,
    ioContext: CoroutineContext = Dispatchers.IO,
    onStart: suspend (List<com.opencapture.opencine.nikon.CameraStorageSlotStatus>) -> Unit = {},
    onPage: suspend (MediaBrowseSnapshot) -> Unit,
): List<MediaClipRecord> = com.opencapture.opencine.nikon.collectNikonMediaPages(
    pageSize, gateway, ioContext, onStart, onPage)

/** Gallery lease survives recompose/player covers; only its actual gallery retires it. */
internal class NikonMediaGalleryCatalog(private val source: com.opencapture.opencine.nikon.NikonMediaService) {
    private val opening = kotlinx.coroutines.sync.Mutex()
    @Volatile private var browse: com.opencapture.opencine.media.CameraMediaBrowse? = null
    @Volatile private var retired = false
    suspend fun open(): com.opencapture.opencine.media.CameraMediaBrowse = opening.withLock {
        check(!retired)
        browse?.takeIf { source.isCurrent(it.binding) } ?: source.openBrowse().also {
            if (retired) { source.retireBrowse(it.binding); throw kotlinx.coroutines.CancellationException("Gallery retired") }
            browse = it
        }
    }
    fun admit(binding: com.opencapture.opencine.media.MediaBrowseBinding) {
        if (retired || browse?.binding != binding || !source.isCurrent(binding)) {
            throw kotlinx.coroutines.CancellationException("Gallery source retired")
        }
    }
    fun capture(
        delta: com.opencapture.opencine.media.MediaCatalogDelta,
        catalog: com.opencapture.opencine.media.MediaCatalog,
        binding: com.opencapture.opencine.media.MediaBrowseBinding,
    ): NikonMediaGalleryPage {
        admit(binding)
        val additions = delta.upserts.map { asset ->
            source.mediaCatalogRecord(asset.id, binding)?.clip
                ?: throw MediaBrowsePagingException("Source record retired.")
        }
        val removals = delta.removed.map { asset ->
            source.mediaCatalogRecord(asset, binding)?.identity
                ?: throw MediaBrowsePagingException("Source removal retired.")
        }
        val next = catalog.applying(delta)
        val clips = MediaClips.newestFirst(next.assets.map { asset ->
            source.mediaCatalogRecord(asset.id, binding)?.clip
                ?: throw MediaBrowsePagingException("Source record retired.")
        })
        admit(binding)
        return NikonMediaGalleryPage(next, clips, additions, removals)
    }
    fun retire() {
        retired = true
        val old = browse; browse = null
        if (old != null) source.retireBrowse(old.binding)
    }
    suspend fun close() {
        retired = true
        val old = browse; browse = null
        old?.close()
    }
}

internal data class NikonMediaGalleryPage(
    val catalog: com.opencapture.opencine.media.MediaCatalog,
    val clips: List<MediaClipRecord>,
    val additions: List<MediaClipRecord>,
    val removals: List<MediaObjectIdentity>,
)
