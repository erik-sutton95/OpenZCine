package com.opencapture.openzcine.media

import android.content.Context
import android.content.SharedPreferences
import com.opencapture.opencine.nikon.NikonMediaClipRecord
import com.opencapture.opencine.nikon.NikonMediaContentKind
import com.opencapture.opencine.nikon.NikonMediaObjectIdentity
import com.opencapture.opencine.nikon.NikonStillPhotoClassification
import com.opencapture.opencine.nikon.NikonStillPreviewStrategy
import java.io.ByteArrayInputStream
import java.io.ByteArrayOutputStream
import java.io.DataInputStream
import java.io.DataOutputStream
import java.security.MessageDigest
import java.time.LocalDate
import java.util.Base64
import java.util.concurrent.ConcurrentHashMap
import com.opencapture.opencine.appkit.MonitorMediaPreferenceStorage
import com.opencapture.opencine.appkit.MonitorMediaPreferences
import com.opencapture.opencine.appkit.MonitorMediaSort

/** The two safe library sources exposed by the Android browser. */
internal enum class MediaLibrarySource(val title: String) {
    CAMERA("Camera"),
    LOCAL("On device"),
}

/** Shared-core-action categories shown in the Android media browser. */
internal enum class MediaLibraryCategory(val title: String) {
    ALL("All"),
    VIDEOS("Videos"),
    PHOTOS("Photos"),
    FAVORITES("Favorites"),
}

/**
 * One value the media browser can offer in its FORMAT chip row — the Kotlin mirror of the shared
 * core's `MediaFormatChip` (`Sources/OpenZCineCore/MediaClipFilename.swift`).
 *
 * Kotlin never decides a still's format: the still titles are exactly the `formatLabel` token the
 * core puts on the listing wire, so a `.HIF` counts as HEIF because the core classified it that
 * way, not because this file knows Nikon's extensions.
 */
internal enum class MediaFormatFilter(val title: String) {
    MOV("MOV"),
    MP4("MP4"),
    JPEG("JPEG"),
    HEIF("HEIF"),
    NEF("NEF"),
    TIFF("TIFF"),
    PNG("PNG"),
}

/** Authoritative pixel-width buckets shown by the Android media browser. */
internal enum class MediaResolutionFilter(val title: String) {
    HD("HD"),
    FOUR_K("4K"),
    FIVE_FOUR_K("5.4K"),
    SIX_K("6K"),
}

/**
 * Nikon still image-size classes (L / M / S) — the Kotlin mirror of the core's
 * `MediaPhotoSizeClass`. A pixel width cannot name its own class (L is 6048 px on a ZR but
 * 8256 px on a Z8), so the class is ranked against the still sizes present in the listing.
 */
internal enum class MediaPhotoSizeFilter(val title: String) {
    LARGE("L"),
    MEDIUM("M"),
    SMALL("S"),
}

/** Relative capture-date windows — the Kotlin mirror of the core's `MediaDateWindow`. */
internal enum class MediaDateWindowFilter(val title: String, val dayCount: Long) {
    TODAY("TODAY", 1),
    LAST_7_DAYS("7 DAYS", 7),
    LAST_30_DAYS("30 DAYS", 30),
    ;

    fun contains(captureDate: String, today: LocalDate): Boolean =
        com.opencapture.opencine.nikon.NikonAndroidGalleryProjectionPolicy.windowContains(captureDate, dayCount, today)
}

/** Camera-scoped filters composed with AND semantics across filter groups. */
internal data class MediaLibraryFilters(
    val formats: Set<MediaFormatFilter> = emptySet(),
    val resolutions: Set<MediaResolutionFilter> = emptySet(),
    val photoSizes: Set<MediaPhotoSizeFilter> = emptySet(),
    /** Single window: the ranges nest, so they are mutually exclusive rather than a set. */
    val dateWindow: MediaDateWindowFilter? = null,
    val storageId: Long? = null,
) {
    /** Number displayed in the filter badge; category tabs are intentionally excluded. */
    val activeCount: Int
        get() =
            formats.size +
                resolutions.size +
                photoSizes.size +
                (if (dateWindow != null) 1 else 0) +
                (if (storageId != null) 1 else 0)

    /**
     * Drops every chip the current listing no longer offers (iOS
     * `pruneMediaFiltersToOfferedChips`). Switching from Videos to Photos must not leave an
     * invisible MOV filter behind — the grid would empty with nothing in the popup to explain it.
     * Storage slots are deliberately untouched: they are scoped by the inserted cards, not by the
     * category's media, and have their own staleness rule below.
     */
    fun retainingOfferedChips(options: MediaFilterOptions): MediaLibraryFilters =
        copy(
            formats = formats intersect options.formats.toSet(),
            resolutions = resolutions intersect options.resolutions.toSet(),
            photoSizes = photoSizes intersect options.photoSizes.toSet(),
            dateWindow = dateWindow?.takeIf { it in options.dateWindows },
        )

    /** Drops a stale card selection whenever the source or connected camera changes. */
    fun retainingAvailableStorage(
        source: MediaLibrarySource,
        clips: List<NikonMediaClipRecord>,
    ): MediaLibraryFilters =
        retainingAvailableStorage(source, clips.mapTo(linkedSetOf(), NikonMediaClipRecord::storageId))

    /** Drops a stale card selection against the authoritative connected-card generation. */
    fun retainingAvailableStorage(
        source: MediaLibrarySource,
        availableStorageIds: Set<Long>,
    ): MediaLibraryFilters {
        val selected = storageId ?: return this
        val remainsAvailable =
            source == MediaLibrarySource.CAMERA && selected in availableStorageIds
        return if (remainsAvailable) this else copy(storageId = null)
    }
}


/**
 * Minimal persistence boundary for the Android media index: the shared media preferences storage,
 * so the index, its wire codec and the shared favorites/view owner stay JVM-testable while the
 * production adapter remains a normal private SharedPreferences store.
 */
internal typealias MediaLibraryPreferences = MonitorMediaPreferenceStorage

/** Android-owned persistence adapter; this store is never visible to other apps. */
internal class SharedPreferencesMediaLibraryPreferences(context: Context) : MediaLibraryPreferences {
    private val preferences: SharedPreferences =
        context.getSharedPreferences(PREFERENCES_NAME, Context.MODE_PRIVATE)

    override fun getString(key: String): String? = preferences.getString(key, null)

    override fun putString(key: String, value: String?) {
        preferences.edit().apply {
            if (value == null) remove(key) else putString(key, value)
        }.apply()
    }

    private companion object {
        const val PREFERENCES_NAME = "openzcine.media-library"
    }
}

/** Stable link from one saved-camera card to its existing media cache bucket. */
internal data class MediaLibraryCameraBucket(
    val savedCameraID: String,
    val cameraID: String,
    val displayName: String,
)

/**
 * Camera-scoped metadata and favorite persistence for the Android media
 * library.
 *
 * Local browsing intentionally reads only this camera-derived index
 * and then asks [MediaCacheStore] for each identity-derived final path. It
 * never searches no-backup storage, so a stray file can never become a media
 * item or share candidate.
 */
internal class MediaLibraryIndex(private val preferences: MediaLibraryPreferences) {
    private val persistenceLock = Any()
    private var catalogGeneration = 0L

    /** Actual preference byte authority, including reread/encode/commit under the original lock. */
    fun catalogByteStore(cameraID: String): com.opencapture.opencine.appkit.MonitorMediaCatalogByteStore =
        object : com.opencapture.opencine.appkit.MonitorMediaCatalogByteStore {
            override val namespace: String = indexKey(cameraID)
            override val generation: Long get() = synchronized(persistenceLock) { catalogGeneration }
            override fun read(): ByteArray? = synchronized(persistenceLock) {
                preferences.getString(indexKey(cameraID))?.toByteArray(Charsets.UTF_8)
            }
            override fun write(bytes: ByteArray, ifCurrent: () -> Boolean) = synchronized(persistenceLock) {
                check(ifCurrent()) { "Catalog retired" }
                preferences.putString(indexKey(cameraID), bytes.toString(Charsets.UTF_8))
                rememberIndexedCameraLocked(cameraID)
            }
            override fun update(ifCurrent: () -> Boolean, encode: (ByteArray?) -> ByteArray?) = synchronized(persistenceLock) {
                check(ifCurrent()) { "Catalog retired" }
                val current = preferences.getString(indexKey(cameraID))?.toByteArray(Charsets.UTF_8)
                val bytes = encode(current) ?: return@synchronized
                check(ifCurrent()) { "Catalog retired" }
                preferences.putString(indexKey(cameraID), bytes.toString(Charsets.UTF_8))
                rememberIndexedCameraLocked(cameraID)
            }
        }



    /**
     * Applies and commits one bounded listing delta. Multi-page callers should
     * use [beginCameraListing] so the unbounded catalog is encoded only once.
     */
    fun rememberCameraListing(
        cameraID: String,
        clips: List<NikonMediaClipRecord>,
        removedObjects: Collection<NikonMediaObjectIdentity> = emptyList(),
    ) {
        beginCameraListing(cameraID).apply {
            applyPage(clips, removedObjects)
            commit()
        }
    }

    /**
     * Loads the existing catalog once and accumulates true native page deltas
     * in memory. [MediaLibraryListingCheckpoint.commit] performs at most one
     * SharedPreferences write for the complete or retryable partial pass.
     */
    fun beginCameraListing(cameraID: String): MediaLibraryListingCheckpoint =
        MediaLibraryListingCheckpoint(
            cameraID = cameraID,
            initialClips = persistedClips(cameraID),
            commitCatalog = { candidateClips, shouldWrite ->
                synchronized(persistenceLock) {
                    val currentByIdentity =
                        persistedClipsLocked(cameraID).associateBy { clip ->
                            clip.libraryKey(cameraID)
                        }
                    val reconciled =
                        candidateClips.map { clip ->
                            mergeAuthoritativeObjectSize(
                                currentByIdentity[clip.libraryKey(cameraID)],
                                clip,
                            )
                        }
                    if (shouldWrite) {
                        preferences.putString(
                            indexKey(cameraID),
                            MediaLibraryRecordCodec.encode(reconciled),
                        )
                        rememberIndexedCameraLocked(cameraID)
                    }
                    reconciled
                }
            },
        )

    /**
     * Replaces a listing sentinel with the authoritative length resolved by
     * Swift immediately before transfer, keeping the completed cache valid
     * after process death and while disconnected.
     */
    fun rememberResolvedObjectSize(
        cameraID: String,
        clip: NikonMediaClipRecord,
        resolvedSizeBytes: Long,
    ) {
        require(resolvedSizeBytes >= 0) { "resolvedSizeBytes must not be negative." }
        if (resolvedSizeBytes == clip.sizeBytes) return
        rememberCameraListing(cameraID, listOf(clip.copy(sizeBytes = resolvedSizeBytes)))
    }

    /** Canonical action result admission shares the actual index lock; no native work runs here. */
    fun mutateCapturedAction(cameraID: String, clip: NikonMediaClipRecord, observed: NikonMediaClipRecord?,
        generation: Long, ifCurrent: () -> Boolean, mutate: () -> Unit): Boolean = synchronized(persistenceLock) {
        if (catalogGeneration != generation || !ifCurrent()) return@synchronized false
        val current = persistedClipLocked(cameraID, clip.libraryKey(cameraID))
        if (observed == null) {
            if (current != null && !sameNikonActionContent(clip, current)) return@synchronized false
        } else {
            if (current == null || !sameNikonActionContent(observed, current)) return@synchronized false
        }
        mutate()
        true
    }

    /** Returns only records previously received from the shared-core listing wire. */
    fun persistedClips(cameraID: String): List<NikonMediaClipRecord> =
        synchronized(persistenceLock) { persistedClipsLocked(cameraID) }

    /**
     * Drops every camera catalog the Settings cache-clear must not leave behind.
     * Favorites stay — they are a separate store — so a shot still on the card
     * can remain favorited after the next authoritative listing.
     */
    fun clearCameraCatalogs() {
        synchronized(persistenceLock) {
            catalogGeneration += 1
            indexedCameraIDsLocked().forEach { cameraID ->
                preferences.putString(indexKey(cameraID), null)
            }
            preferences.putString(INDEXED_CAMERAS_KEY, null)
        }
    }

    /**
     * Drops one deliberately deleted clip's index row and favorite (iOS
     * `MediaLibrary.purgeClip` counterpart — unlike a listing removal, a
     * downloaded copy does not keep the row alive). Cache artifacts are the
     * [MediaCacheStore]'s side of the purge.
     */
    fun purgeClip(cameraID: String, clip: NikonMediaClipRecord, ifCurrent: () -> Boolean = { true }) {
        val identity = clip.libraryKey(cameraID)
        synchronized(persistenceLock) {
            if (!ifCurrent()) return
            val remaining = persistedClipsLocked(cameraID).filter { it.libraryKey(cameraID) != identity }
            val encoded = MediaLibraryRecordCodec.encode(remaining).takeIf { remaining.isNotEmpty() }
            preferences.putString(indexKey(cameraID), encoded)
            // Write-through: the next check reuses these rows instead of decoding what was just encoded.
            if (encoded != null) decoded[cameraID] = DecodedIndex(encoded, remaining, cameraID) else decoded.remove(cameraID)
        }
        if (!ifCurrent()) return
        val store = mediaPreferences(cameraID)
        val favorites = store.favorites()
        if (identity in favorites && ifCurrent()) store.saveFavorites(favorites - identity)
    }

    /**
     * One decoded index per bucket, keyed by the exact stored string. Any write (ours or another
     * path through [preferences]) stores a different string, so a stale decode is never served,
     * and repeated checks (per clip, per deletion step) cost a lookup instead of a full decode.
     */
    private class DecodedIndex(val encoded: String, val clips: List<NikonMediaClipRecord>, val cameraID: String) {
        val byKey: Map<String, NikonMediaClipRecord> by lazy {
            HashMap<String, NikonMediaClipRecord>(clips.size * 2).also { map -> clips.forEach { map.putIfAbsent(it.libraryKey(cameraID), it) } }
        }
    }
    private val decoded = HashMap<String, DecodedIndex>()
    private fun decodedLocked(cameraID: String): DecodedIndex? {
        val encoded = preferences.getString(indexKey(cameraID)) ?: run { decoded.remove(cameraID); return null }
        decoded[cameraID]?.let { if (it.encoded === encoded || it.encoded == encoded) return it }
        return DecodedIndex(encoded, MediaLibraryRecordCodec.decode(encoded), cameraID).also { decoded[cameraID] = it }
    }
    private fun persistedClipsLocked(cameraID: String): List<NikonMediaClipRecord> = decodedLocked(cameraID)?.clips.orEmpty()
    private fun persistedClipLocked(cameraID: String, libraryKey: String): NikonMediaClipRecord? =
        decodedLocked(cameraID)?.byKey?.get(libraryKey)
    /** The persisted row with this library key, from the one decoded index (first row wins). */
    fun persistedClip(cameraID: String, libraryKey: String): NikonMediaClipRecord? =
        synchronized(persistenceLock) { persistedClipLocked(cameraID, libraryKey) }

    /** Remembers which durable saved profile owns an already-established cache bucket. */
    fun rememberCameraBucket(savedCameraID: String, cameraID: String, displayName: String) {
        val savedID = normalizedRegistryValue(savedCameraID) ?: return
        val bucketID = normalizedRegistryValue(cameraID) ?: return
        val label = normalizedRegistryValue(displayName) ?: return
        val merged = LinkedHashMap<String, MediaLibraryCameraBucket>()
        registeredCameraBuckets().forEach { merged[it.savedCameraID] = it }
        merged[savedID] = MediaLibraryCameraBucket(savedID, bucketID, label)
        preferences.putString(
            CAMERA_BUCKETS_KEY,
            MediaLibraryCameraBucketCodec.encode(merged.values.toList()),
        )
    }

    /** Returns registered buckets in saved-camera card order, excluding removed profiles. */
    fun registeredCameraBuckets(savedCameraIDs: List<String>): List<MediaLibraryCameraBucket> {
        val bySavedID = registeredCameraBuckets().associateBy(MediaLibraryCameraBucket::savedCameraID)
        return savedCameraIDs.mapNotNull(bySavedID::get)
    }

    /**
     * Returns only saved-camera buckets that still contain at least one exact,
     * complete cache artifact. Missing, symlinked, truncated, or stale files
     * fail closed and never create an offline entry point.
     */
    fun completedCameraBuckets(
        savedCameraIDs: List<String>,
        cacheStore: MediaCacheStore,
    ): List<MediaLibraryCameraBucket> =
        registeredCameraBuckets(savedCameraIDs).filter { bucket ->
            persistedClips(bucket.cameraID).any { clip ->
                runCatching {
                    cacheStore.completedEntryOrNull(
                        bucket.cameraID,
                        MediaCacheObjectIdentity(clip),
                        clip.sizeBytes,
                    )
                }.getOrNull() != null
            }
        }

    /**
     * One camera bucket's favorites and the browser view options, in the shared media preferences
     * owner. The keys and the newline separator are the ones this index always wrote, so existing
     * favorites and view choices read back unchanged.
     */
    fun mediaPreferences(cameraID: String): MonitorMediaPreferences =
        MonitorMediaPreferences(preferences, favoritesKey(cameraID), LAST_CAMERA_KEY, "\n", viewKeyPrefix = VIEW_KEY_PREFIX)

    /** Reads the persisted favorite identities for the given camera bucket. */
    fun favoriteIDs(cameraID: String): Set<String> = mediaPreferences(cameraID).favorites()

    /** Changes one favorite and returns the complete updated set for UI state. */
    fun toggleFavorite(cameraID: String, clip: NikonMediaClipRecord): Set<String> {
        val store = mediaPreferences(cameraID)
        val identity = clip.libraryKey(cameraID)
        val updated = store.favorites().let { if (identity in it) it - identity else it + identity }
        store.saveFavorites(updated)
        return updated
    }

    /**
     * Sets one favorite explicitly (add when [favorite], remove otherwise) and returns the
     * complete updated set. This is the mirror a camera star write performs: a shot rated
     * >= 1 star becomes a favorite so the Favorites tab — which reads this set, not the camera
     * property — agrees with shots starred during a shoot. iOS `mirrorRatingIntoIndex`.
     */
    fun setFavorite(cameraID: String, clip: NikonMediaClipRecord, favorite: Boolean): Set<String> {
        val store = mediaPreferences(cameraID)
        val identity = clip.libraryKey(cameraID)
        val current = store.favorites()
        val updated = if (favorite) current + identity else current - identity
        if (updated != current) store.saveFavorites(updated)
        return updated
    }

    private fun indexKey(cameraID: String): String = "index.${digest(cameraID)}"

    private fun favoritesKey(cameraID: String): String = "favorites.${digest(cameraID)}"

    private fun rememberIndexedCameraLocked(cameraID: String) {
        val ids = indexedCameraIDsLocked()
        if (cameraID in ids) return
        preferences.putString(
            INDEXED_CAMERAS_KEY,
            (ids + cameraID).sorted().joinToString(separator = "\n"),
        )
    }

    private fun indexedCameraIDsLocked(): Set<String> {
        val recorded =
            preferences.getString(INDEXED_CAMERAS_KEY)
                ?.lineSequence()
                ?.filter { it.isNotBlank() }
                ?.toSet()
                .orEmpty()
        return recorded + registeredCameraBuckets().map { it.cameraID }
    }

    private fun registeredCameraBuckets(): List<MediaLibraryCameraBucket> =
        preferences.getString(CAMERA_BUCKETS_KEY)
            ?.let(MediaLibraryCameraBucketCodec::decode)
            .orEmpty()

    private companion object {
        const val CAMERA_BUCKETS_KEY = "camera-buckets"
        const val INDEXED_CAMERAS_KEY = "indexed-cameras"
        const val LAST_CAMERA_KEY = "last-camera"
        const val VIEW_KEY_PREFIX = "view"
    }
}

/** One in-memory camera-listing transaction with a single durable commit. */
internal class MediaLibraryListingCheckpoint(
    private val cameraID: String,
    initialClips: List<NikonMediaClipRecord>,
    private val commitCatalog: (List<NikonMediaClipRecord>, Boolean) -> List<NikonMediaClipRecord>,
) {
    private val clipsByIdentity = LinkedHashMap<String, NikonMediaClipRecord>()
    private val listedIdentities = LinkedHashSet<String>()
    private var dirty = false
    private var committed = false

    init {
        initialClips.forEach { clip -> clipsByIdentity[clip.libraryKey(cameraID)] = clip }
    }

    /** Applies additions and exact removals from one native page without disk I/O. */
    fun applyPage(
        addedClips: Collection<NikonMediaClipRecord>,
        removedObjects: Collection<NikonMediaObjectIdentity>,
    ) {
        check(!committed) { "Camera listing checkpoint is already committed." }
        addedClips.forEach { incoming ->
            val key = incoming.libraryKey(cameraID)
            listedIdentities += key
            val merged = mergeAuthoritativeObjectSize(clipsByIdentity[key], incoming)
            if (clipsByIdentity[key] != merged) {
                clipsByIdentity[key] = merged
                dirty = true
            }
        }
        removedObjects.forEach { identity ->
            val key = identity.libraryKey(cameraID)
            listedIdentities -= key
            if (clipsByIdentity.remove(key) != null) dirty = true
        }
    }

    /**
     * Encodes the final newest-first catalog once; repeated commits are
     * rejected. A clip may begin transfer while later camera pages are still
     * loading, so commit re-reads exact current identities and carries any
     * authoritative size resolved during that window over the stale sentinel
     * held by this checkpoint.
     *
     * The index is a CACHE of what the card holds; the camera is the truth. A
     * pass that walked every object may therefore drop the rows it never saw —
     * clips deleted in-camera, which otherwise stayed in the grid forever as
     * ghosts that cannot play, share, or be deleted (iOS `applyCameraRemoval`).
     * Only a COMPLETE pass may prune: a cancelled or failed one has simply not
     * reached the rest of the card yet. A row with a complete local copy
     * survives with its identity intact, because the cache artifact is keyed on
     * exactly that (storage, handle, date, name).
     */
    fun commit(
        prunesUnlistedClips: Boolean = false,
        hasLocalCopy: (NikonMediaClipRecord) -> Boolean = { false },
    ): List<NikonMediaClipRecord> {
        check(!committed) { "Camera listing checkpoint is already committed." }
        committed = true
        if (prunesUnlistedClips) {
            val ghosts =
                clipsByIdentity.filterKeys { it !in listedIdentities }
                    .filterValues { !hasLocalCopy(it) }
                    .keys
            if (ghosts.isNotEmpty()) {
                ghosts.forEach(clipsByIdentity::remove)
                dirty = true
            }
        }
        val candidate =
            MediaLibraryFiltering.sort(
                clipsByIdentity.values.toList(),
                MonitorMediaSort.NEWEST,
            )
        return commitCatalog(candidate, dirty)
    }
}

/** Legacy source callers delegate to the same captured neutral projection owner as the gallery. */
internal object MediaLibraryFiltering {
    fun displayed(clips: List<NikonMediaClipRecord>, category: MediaLibraryCategory,
        favoriteIDs: Set<String>, cameraID: String, sortOrder: MonitorMediaSort,
        filters: MediaLibraryFilters = MediaLibraryFilters(), today: LocalDate = LocalDate.now(),
        libraryKey: (NikonMediaClipRecord) -> String = { it.libraryKey(cameraID) },
        ownerOf: (NikonMediaClipRecord) -> String = { cameraID }): List<NikonMediaClipRecord> =
        NikonAppGalleryProjection(clips, emptyMap(), category, favoriteIDs, cameraID,
            sortOrder, filters, today, libraryKey, ownerOf).displayedClips
    fun sort(clips: List<NikonMediaClipRecord>, sortOrder: MonitorMediaSort): List<NikonMediaClipRecord> =
        NikonAppGalleryProjection.sorted(clips, sortOrder)
}

/** Legacy metadata helpers map pure Nikon-owned facts into existing UI values. */
internal fun NikonMediaClipRecord.formatFilter(): MediaFormatFilter? =
    com.opencapture.opencine.nikon.NikonAndroidGalleryProjectionPolicy.formatKey(this)?.let { key ->
        MediaFormatFilter.entries.firstOrNull { it.title == key }
    }
internal data class MediaFilterOptions(
    val formats: List<MediaFormatFilter> = emptyList(),
    val resolutions: List<MediaResolutionFilter> = emptyList(),
    val photoSizes: List<MediaPhotoSizeFilter> = emptyList(),
    val dateWindows: List<MediaDateWindowFilter> = emptyList(),
) {
    val isEmpty get() = formats.isEmpty() && resolutions.isEmpty() && photoSizes.isEmpty() && dateWindows.isEmpty()
}

/** Stable private favorite/index identity — never a filename-only key. */
internal fun NikonMediaClipRecord.libraryKey(cameraID: String): String =
    mediaLibraryKey(cameraID, storageId, handle, captureDate, filename)

/**
 * Bucket-independent object identity used to map offline multi-camera clips
 * back to their owning cache cameraID.
 */
internal fun NikonMediaClipRecord.offlineObjectKey(): String =
    listOf(storageId.toString(), handle.toString(), captureDate, filename)
        .joinToString(separator = "\u0000")

internal fun NikonMediaObjectIdentity.libraryKey(cameraID: String): String =
    mediaLibraryKey(cameraID, storageID, handle, captureDate, filename)

private fun mediaLibraryKey(
    cameraID: String,
    storageID: Long,
    handle: Long,
    captureDate: String,
    filename: String,
): String =
    digest(
        listOf(cameraID, storageID.toString(), handle.toString(), captureDate, filename)
            .joinToString(separator = "\u0000"),
    )

internal fun mergeAuthoritativeObjectSize(
    existing: NikonMediaClipRecord?,
    incoming: NikonMediaClipRecord,
): NikonMediaClipRecord =
    if (
        incoming.sizeBytes == PTP_UINT32_SENTINEL &&
            existing != null &&
            existing.sizeBytes != PTP_UINT32_SENTINEL
    ) {
        incoming.copy(sizeBytes = existing.sizeBytes)
    } else {
        incoming
    }

private const val PTP_UINT32_SENTINEL = 0xFFFF_FFFFL

/** Serialized records remain core-authorized metadata, never inferred locally from filenames. */
private object MediaLibraryRecordCodec {
    private const val MAGIC = 0x4F5A434D // OZCM
    private const val VERSION = 2
    private const val LEGACY_VERSION = 1
    private const val LEGACY_MINIMUM_RECORD_BYTES = 39
    private const val CURRENT_MINIMUM_RECORD_BYTES = 47

    fun encode(clips: List<NikonMediaClipRecord>): String {
        val bytes =
            ByteArrayOutputStream().use { raw ->
                DataOutputStream(raw).use { output ->
                    output.writeInt(MAGIC)
                    output.writeInt(VERSION)
                    output.writeInt(clips.size)
                    clips.forEach { clip -> writeClip(output, clip) }
                }
                raw.toByteArray()
            }
        return Base64.getUrlEncoder().withoutPadding().encodeToString(bytes)
    }

    fun decode(encoded: String): List<NikonMediaClipRecord> =
        try {
            val bytes = Base64.getUrlDecoder().decode(encoded)
            DataInputStream(ByteArrayInputStream(bytes)).use { input ->
                check(input.readInt() == MAGIC)
                val version = input.readInt()
                check(version == LEGACY_VERSION || version == VERSION)
                val count = input.readInt()
                val minimumRecordBytes =
                    if (version == LEGACY_VERSION) {
                        LEGACY_MINIMUM_RECORD_BYTES
                    } else {
                        CURRENT_MINIMUM_RECORD_BYTES
                    }
                check(count >= 0 && count <= input.available() / minimumRecordBytes)
                val clips = List(count) { readClip(input, version) }
                check(input.available() == 0)
                clips
            }
        } catch (_: Exception) {
            emptyList()
        }

    private fun writeClip(output: DataOutputStream, clip: NikonMediaClipRecord) {
        output.writeLong(clip.handle)
        output.writeLong(clip.storageId)
        output.writeLong(clip.sizeBytes)
        output.writeUTF(clip.captureDate)
        output.writeInt(clip.pixelWidth)
        output.writeInt(clip.pixelHeight)
        output.writeInt(clip.sourcePixelWidth)
        output.writeInt(clip.sourcePixelHeight)
        output.writeUTF(clip.filename)
        output.writeUTF(clip.contentKind.name)
        val stillPhoto = clip.stillPhoto
        output.writeBoolean(stillPhoto != null)
        if (stillPhoto != null) {
            output.writeUTF(stillPhoto.formatLabel)
            output.writeUTF(stillPhoto.previewStrategy.name)
        }
    }

    private fun readClip(input: DataInputStream, version: Int): NikonMediaClipRecord {
        val handle = input.readLong()
        val storageID = input.readLong()
        val sizeBytes = input.readLong()
        val captureDate = input.readUTF()
        val pixelWidth = input.readInt()
        val pixelHeight = input.readInt()
        val sourcePixelWidth = if (version >= VERSION) input.readInt() else 0
        val sourcePixelHeight = if (version >= VERSION) input.readInt() else 0
        val filename = input.readUTF()
        val contentKind = NikonMediaContentKind.valueOf(input.readUTF())
        val stillPhoto =
            if (input.readBoolean()) {
                val formatLabel = input.readUTF()
                val previewStrategy = NikonStillPreviewStrategy.valueOf(input.readUTF())
                NikonStillPhotoClassification(formatLabel, previewStrategy)
            } else {
                null
            }
        check(sizeBytes >= 0)
        check(pixelWidth >= 0)
        check(pixelHeight >= 0)
        check(sourcePixelWidth >= 0)
        check(sourcePixelHeight >= 0)
        check(isSafePersistedFilename(filename))
        check((contentKind == NikonMediaContentKind.STILL_PHOTO) == (stillPhoto != null))
        return NikonMediaClipRecord(
            handle = handle,
            storageId = storageID,
            sizeBytes = sizeBytes,
            captureDate = captureDate,
            pixelWidth = pixelWidth,
            pixelHeight = pixelHeight,
            filename = filename,
            contentKind = contentKind,
            stillPhoto = stillPhoto,
            sourcePixelWidth = sourcePixelWidth,
            sourcePixelHeight = sourcePixelHeight,
        )
    }

    private fun isSafePersistedFilename(filename: String): Boolean =
        filename.isNotBlank() &&
            filename == filename.trim() &&
            filename != "." &&
            filename != ".." &&
            filename.indexOf('\u0000') < 0 &&
            !filename.contains('/') &&
            !filename.contains('\\') &&
            filename.none { character -> character.code < 0x20 || character.code == 0x7F }
}

/** Small, corruption-tolerant registry codec; fields are URL-safe Base64, one bucket per line. */
private object MediaLibraryCameraBucketCodec {
    fun encode(buckets: List<MediaLibraryCameraBucket>): String =
        buckets.joinToString(separator = "\n") { bucket ->
            listOf(bucket.savedCameraID, bucket.cameraID, bucket.displayName)
                .joinToString(separator = "\t", transform = ::encodeField)
        }

    fun decode(encoded: String): List<MediaLibraryCameraBucket> =
        encoded.lineSequence().mapNotNull { line ->
            val fields = line.split('\t')
            if (fields.size != 3) return@mapNotNull null
            val values = fields.map(::decodeField)
            val savedCameraID = values[0] ?: return@mapNotNull null
            val cameraID = values[1] ?: return@mapNotNull null
            val displayName = values[2] ?: return@mapNotNull null
            MediaLibraryCameraBucket(savedCameraID, cameraID, displayName)
        }.distinctBy(MediaLibraryCameraBucket::savedCameraID).toList()

    private fun encodeField(value: String): String =
        Base64.getUrlEncoder().withoutPadding().encodeToString(value.toByteArray(Charsets.UTF_8))

    private fun decodeField(value: String): String? =
        runCatching {
            val decoded = Base64.getUrlDecoder().decode(value).toString(Charsets.UTF_8)
            normalizedRegistryValue(decoded)
        }.getOrNull()
}

private fun normalizedRegistryValue(value: String): String? =
    value.trim().takeIf { candidate ->
        candidate.isNotEmpty() &&
            candidate.length <= 1_024 &&
            candidate.none { character -> character == '\u0000' || character.code < 0x20 }
    }

// Library/pair keys are hashed on every recomposition of the browse grid — once for each visible
// cell and, while anything is selected, once for every clip in the library. `getInstance` is a JCA
// provider lookup, so doing it per call dominated the cost and made multiselect crawl. The digest
// is a pure function of its input, so memoize it and keep one digester per thread.
// ponytail: capacity-capped rather than LRU — distinct keys are bounded by the card's object count,
// and a full clear on overflow just re-hashes lazily.
private const val DIGEST_CACHE_LIMIT = 50_000
private val digestCache = ConcurrentHashMap<String, String>()
private val digester = ThreadLocal.withInitial { MessageDigest.getInstance("SHA-256") }

private fun digest(value: String): String =
    digestCache[value] ?: computeDigest(value).also {
        if (digestCache.size >= DIGEST_CACHE_LIMIT) digestCache.clear()
        digestCache[value] = it
    }

private fun computeDigest(value: String): String {
    val hex = "0123456789abcdef"
    val bytes = digester.get().digest(value.toByteArray(Charsets.UTF_8))
    return buildString(bytes.size * 2) {
        bytes.forEach { byte ->
            val unsigned = byte.toInt() and 0xFF
            append(hex[unsigned ushr 4])
            append(hex[unsigned and 0x0F])
        }
    }
}

/** Pure access to the exact legacy Base64/binary codec; no preference or registry side effects. */
internal fun decodeMediaLibraryCatalogBytes(bytes: ByteArray): List<NikonMediaClipRecord> =
    MediaLibraryRecordCodec.decode(bytes.toString(Charsets.UTF_8))
internal fun encodeMediaLibraryCatalogBytes(clips: List<NikonMediaClipRecord>): ByteArray =
    MediaLibraryRecordCodec.encode(clips).toByteArray(Charsets.UTF_8)

/** Same legacy cache identity; unknown size may strengthen, conflicting known bytes retire. */
internal fun sameNikonActionContent(old: NikonMediaClipRecord, current: NikonMediaClipRecord): Boolean {
    if (old.filename != current.filename || old.storageId != current.storageId || old.handle != current.handle) return false
    if (old.captureDate.isNotEmpty() && current.captureDate.isNotEmpty() && old.captureDate != current.captureDate) return false
    if (old.sizeBytes > 0 && current.sizeBytes > 0 &&
        old.sizeBytes != PTP_UINT32_SENTINEL && current.sizeBytes != PTP_UINT32_SENTINEL &&
        old.sizeBytes != current.sizeBytes) return false
    return true
}
