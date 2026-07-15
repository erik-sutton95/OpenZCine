package com.opencapture.openzcine.media

/**
 * Test-only shorthand for cache cases that do not need to vary PTP identity.
 * Production callers must pass [MediaCacheObjectIdentity] from their media
 * record so same-named clips cannot collide.
 */
internal fun MediaCacheStore.openEntry(
    cameraID: String,
    filename: String,
    expectedLength: Long,
): MediaCacheEntry =
    openEntry(
        cameraID,
        MediaCacheObjectIdentity(
            storageId = 1L,
            handle = filename.hashCode().toLong(),
            captureDate = "",
            filename = filename,
        ),
        expectedLength,
    )
