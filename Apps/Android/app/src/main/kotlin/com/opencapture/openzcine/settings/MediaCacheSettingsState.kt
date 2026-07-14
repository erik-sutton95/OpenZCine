package com.opencapture.openzcine.settings

import com.opencapture.openzcine.media.MediaCacheClearResult
import com.opencapture.openzcine.media.MediaCacheStore
import com.opencapture.openzcine.media.MediaCacheUsage

/**
 * Immutable storage readout rendered by Operator Settings.
 *
 * The caller runs its filesystem work off the main thread, then stores this
 * plain snapshot in Compose state. Keeping it separate from the composable
 * makes the clear-cache policy independently testable.
 */
internal data class MediaCacheStorageSnapshot(
    val usage: MediaCacheUsage,
    val clearResult: MediaCacheClearResult? = null,
)

/**
 * Small settings-domain boundary for the app-owned progressive media cache.
 *
 * This class does not reach into camera sessions, share-provider storage, or
 * account state. [clearCompleted] delegates to the cache store's strict
 * completed-only purge, preserving every incomplete transfer artifact.
 */
internal class MediaCacheSettingsState(private val cacheStore: MediaCacheStore) {
    /** Reads the current cache accounting without changing any files. */
    fun refresh(): MediaCacheStorageSnapshot =
        MediaCacheStorageSnapshot(usage = cacheStore.cacheUsage())

    /** Removes completed local cache entries, then returns the fresh accounting. */
    fun clearCompleted(): MediaCacheStorageSnapshot {
        val result = cacheStore.clearCompletedEntries()
        return MediaCacheStorageSnapshot(usage = cacheStore.cacheUsage(), clearResult = result)
    }
}
