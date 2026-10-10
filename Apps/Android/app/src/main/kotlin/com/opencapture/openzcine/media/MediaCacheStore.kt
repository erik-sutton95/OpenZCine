package com.opencapture.openzcine.media

import com.opencapture.opencine.nikon.NikonMediaClipRecord
import com.opencapture.opencine.media.*
import com.opencapture.opencine.appkit.MonitorMediaCacheDirectory
import java.nio.file.Path

public typealias MediaCacheState = ProgressiveMediaCacheState
public typealias MediaCacheEntry = ProgressiveMediaCacheEntry
public typealias MediaCacheException = ProgressiveMediaCacheException
public typealias UnsafeMediaCacheFilenameException = UnsafeProgressiveMediaCacheFilenameException
public typealias MediaCacheOffsetException = ProgressiveMediaCacheOffsetException
public typealias MediaCacheLengthException = ProgressiveMediaCacheLengthException
public typealias MediaCacheStateException = ProgressiveMediaCacheStateException
public typealias MediaCacheUsage = ProgressiveMediaCacheUsage
public typealias MediaCacheClearResult = ProgressiveMediaCacheClearResult

/**
 * Stable identity for one PTP object in a camera cache bucket.
 *
 * Nikon camera filenames are not globally unique: a card can be swapped,
 * another storage volume can contain the same basename, and handles can be
 * reused after deletion. Every field therefore contributes to the cache key;
 * [filename] is retained for validation and diagnostics, not used directly as
 * the on-disk artifact name.
 */
data class MediaCacheObjectIdentity(
    /** PTP storage volume containing the object. */
    val storageId: Long,
    /** PTP object handle within that storage volume. */
    val handle: Long,
    /** Camera capture timestamp, when supplied by ObjectInfo. */
    val captureDate: String,
    /** Safe camera basename, e.g. `C0001.MOV`. */
    val filename: String,
) {
    /** Builds the identity directly from the Android media-list wire record. */
    public constructor(clip: NikonMediaClipRecord) : this(
        storageId = clip.storageId,
        handle = clip.handle,
        captureDate = clip.captureDate,
        filename = clip.filename,
    )

    internal fun sharedIdentity(): ProgressiveMediaCacheIdentity = ProgressiveMediaCacheIdentity(
        filename, "$storageId\u0000$handle\u0000$captureDate\u0000$filename")
}

/** Source identity adapter over the shared progressive cache and canonical library lifetime. */
public class MediaCacheStore(rootDirectory: Path) {
    private val cache = ProgressiveMediaCache(rootDirectory)
    public val rootDirectory: Path get() = cache.rootDirectory
    public val libraryDirectory: MonitorMediaCacheDirectory = MonitorMediaCacheDirectory(cache.rootDirectory.toFile())
    public fun cacheUsage(): MediaCacheUsage = cache.cacheUsage()
    public fun clearCompletedEntries(): MediaCacheClearResult {
        libraryDirectory.retireWrites()
        return cache.clearCompletedEntries()
    }
    public fun libraryRelativeAddress(cameraID: String, identity: MediaCacheObjectIdentity): String =
        cache.libraryRelativeAddress(cameraID, identity.sharedIdentity())
    public fun openEntry(cameraID: String, identity: MediaCacheObjectIdentity, expectedLength: Long): MediaCacheEntry =
        cache.openEntry(cameraID, identity.sharedIdentity(), expectedLength)
    public fun completedEntryOrNull(cameraID: String, identity: MediaCacheObjectIdentity, expectedLength: Long): MediaCacheEntry? =
        cache.completedEntryOrNull(cameraID, identity.sharedIdentity(), expectedLength)
    public fun purgeEntry(cameraID: String, identity: MediaCacheObjectIdentity) {
        cache.purgeEntry(cameraID, identity.sharedIdentity())
    }
}
