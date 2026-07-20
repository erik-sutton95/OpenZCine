package com.opencapture.openzcine.media

import android.content.Context
import android.content.SharedPreferences
import java.io.ByteArrayInputStream
import java.io.ByteArrayOutputStream
import java.io.DataInputStream
import java.io.DataOutputStream
import java.security.MessageDigest
import java.time.LocalDate
import java.time.format.DateTimeFormatter
import java.util.Base64
import java.util.Locale

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

/** Operator-selectable arrangement for the Android media library. */
internal enum class MediaLibraryLayout(val accessibilityLabel: String) {
    GRID("Switch to list view"),
    LIST("Switch to grid view"),
}

/** Persisted adaptive-grid density, matching the current iOS media browser. */
internal enum class MediaThumbnailSize(
    val accessibilityLabel: String,
    val minimumCellWidthDp: Int,
) {
    SMALL("Small thumbnails", 148),
    MEDIUM("Medium thumbnails", 210),
    LARGE("Large thumbnails", 280),
}

/** Operator-selected camera container metadata filters. */
internal enum class MediaContainerFilter(val title: String) {
    MOV("MOV"),
    MP4("MP4"),
}

/** Authoritative pixel-width buckets shown by the Android media browser. */
internal enum class MediaResolutionFilter(val title: String) {
    HD("HD"),
    FOUR_K("4K"),
    FIVE_FOUR_K("5.4K"),
    SIX_K("6K"),
}

/** Camera-scoped filters composed with AND semantics across filter groups. */
internal data class MediaLibraryFilters(
    val containers: Set<MediaContainerFilter> = emptySet(),
    val resolutions: Set<MediaResolutionFilter> = emptySet(),
    val todayOnly: Boolean = false,
    val storageId: Long? = null,
) {
    /** Number displayed in the filter badge; category tabs are intentionally excluded. */
    val activeCount: Int
        get() =
            containers.size +
                resolutions.size +
                (if (todayOnly) 1 else 0) +
                (if (storageId != null) 1 else 0)

    /** Drops a stale card selection whenever the source or connected camera changes. */
    fun retainingAvailableStorage(
        source: MediaLibrarySource,
        clips: List<MediaClipRecord>,
    ): MediaLibraryFilters =
        retainingAvailableStorage(source, clips.mapTo(linkedSetOf(), MediaClipRecord::storageId))

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

/** Stable ordering choices for a media-library result set. */
internal enum class MediaLibrarySortOrder(val title: String) {
    NEWEST("Newest"),
    OLDEST("Oldest"),
    NAME("Name"),
}

/** Persisted browser controls, independent of any camera command state. */
internal data class MediaLibraryViewOptions(
    val source: MediaLibrarySource,
    val category: MediaLibraryCategory = MediaLibraryCategory.ALL,
    val layout: MediaLibraryLayout = MediaLibraryLayout.GRID,
    val sortOrder: MediaLibrarySortOrder = MediaLibrarySortOrder.NEWEST,
    val thumbnailSize: MediaThumbnailSize = MediaThumbnailSize.MEDIUM,
)

/**
 * Minimal persistence boundary for the Android media index.
 *
 * A narrow interface keeps the index and its wire codec JVM-testable while
 * the production adapter remains a normal private SharedPreferences store.
 */
internal interface MediaLibraryPreferences {
    fun getString(key: String): String?

    fun putString(key: String, value: String?)
}

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

    /**
     * Applies and commits one bounded listing delta. Multi-page callers should
     * use [beginCameraListing] so the unbounded catalog is encoded only once.
     */
    fun rememberCameraListing(
        cameraID: String,
        clips: List<MediaClipRecord>,
        removedObjects: Collection<MediaObjectIdentity> = emptyList(),
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
        clip: MediaClipRecord,
        resolvedSizeBytes: Long,
    ) {
        require(resolvedSizeBytes >= 0) { "resolvedSizeBytes must not be negative." }
        if (resolvedSizeBytes == clip.sizeBytes) return
        rememberCameraListing(cameraID, listOf(clip.copy(sizeBytes = resolvedSizeBytes)))
    }

    /** Returns only records previously received from the shared-core listing wire. */
    fun persistedClips(cameraID: String): List<MediaClipRecord> =
        synchronized(persistenceLock) { persistedClipsLocked(cameraID) }

    private fun persistedClipsLocked(cameraID: String): List<MediaClipRecord> =
        preferences.getString(indexKey(cameraID))
            ?.let(MediaLibraryRecordCodec::decode)
            .orEmpty()

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

    /** Reads the persisted favorite identities for the given camera bucket. */
    fun favoriteIDs(cameraID: String): Set<String> =
        preferences.getString(favoritesKey(cameraID))
            ?.lineSequence()
            ?.filter { it.isNotBlank() }
            ?.toSet()
            .orEmpty()

    /** Changes one favorite and returns the complete updated set for UI state. */
    fun toggleFavorite(cameraID: String, clip: MediaClipRecord): Set<String> {
        val updated = favoriteIDs(cameraID).toMutableSet()
        val identity = clip.libraryKey(cameraID)
        if (!updated.add(identity)) updated.remove(identity)
        preferences.putString(
            favoritesKey(cameraID),
            updated.sorted().joinToString(separator = "\n").ifEmpty { null },
        )
        return updated
    }

    /** Restores browser controls without trusting a corrupted preference value. */
    fun viewOptions(defaultSource: MediaLibrarySource): MediaLibraryViewOptions =
        MediaLibraryViewOptions(
            source = enumValue(PREF_SOURCE, defaultSource),
            category = enumValue(PREF_CATEGORY, MediaLibraryCategory.ALL),
            layout = enumValue(PREF_LAYOUT, MediaLibraryLayout.GRID),
            sortOrder = enumValue(PREF_SORT, MediaLibrarySortOrder.NEWEST),
            thumbnailSize = enumValue(PREF_THUMBNAIL_SIZE, MediaThumbnailSize.MEDIUM),
        )

    /** Persists only local browsing preferences; camera commands are never stored here. */
    fun saveViewOptions(options: MediaLibraryViewOptions) {
        preferences.putString(PREF_SOURCE, options.source.name)
        preferences.putString(PREF_CATEGORY, options.category.name)
        preferences.putString(PREF_LAYOUT, options.layout.name)
        preferences.putString(PREF_SORT, options.sortOrder.name)
        preferences.putString(PREF_THUMBNAIL_SIZE, options.thumbnailSize.name)
    }

    private inline fun <reified Value : Enum<Value>> enumValue(key: String, fallback: Value): Value =
        preferences.getString(key)
            ?.let { value -> enumValues<Value>().firstOrNull { it.name == value } }
            ?: fallback

    private fun indexKey(cameraID: String): String = "index.${digest(cameraID)}"

    private fun favoritesKey(cameraID: String): String = "favorites.${digest(cameraID)}"

    private fun registeredCameraBuckets(): List<MediaLibraryCameraBucket> =
        preferences.getString(CAMERA_BUCKETS_KEY)
            ?.let(MediaLibraryCameraBucketCodec::decode)
            .orEmpty()

    private companion object {
        const val CAMERA_BUCKETS_KEY = "camera-buckets"
        const val PREF_SOURCE = "view.source"
        const val PREF_CATEGORY = "view.category"
        const val PREF_LAYOUT = "view.layout"
        const val PREF_SORT = "view.sort"
        const val PREF_THUMBNAIL_SIZE = "view.thumbnail-size"
    }
}

/** One in-memory camera-listing transaction with a single durable commit. */
internal class MediaLibraryListingCheckpoint(
    private val cameraID: String,
    initialClips: List<MediaClipRecord>,
    private val commitCatalog: (List<MediaClipRecord>, Boolean) -> List<MediaClipRecord>,
) {
    private val clipsByIdentity = LinkedHashMap<String, MediaClipRecord>()
    private var dirty = false
    private var committed = false

    init {
        initialClips.forEach { clip -> clipsByIdentity[clip.libraryKey(cameraID)] = clip }
    }

    /** Applies additions and exact removals from one native page without disk I/O. */
    fun applyPage(
        addedClips: Collection<MediaClipRecord>,
        removedObjects: Collection<MediaObjectIdentity>,
    ) {
        check(!committed) { "Camera listing checkpoint is already committed." }
        addedClips.forEach { incoming ->
            val key = incoming.libraryKey(cameraID)
            val merged = mergeAuthoritativeObjectSize(clipsByIdentity[key], incoming)
            if (clipsByIdentity[key] != merged) {
                clipsByIdentity[key] = merged
                dirty = true
            }
        }
        removedObjects.forEach { identity ->
            if (clipsByIdentity.remove(identity.libraryKey(cameraID)) != null) dirty = true
        }
    }

    /**
     * Encodes the final newest-first catalog once; repeated commits are
     * rejected. A clip may begin transfer while later camera pages are still
     * loading, so commit re-reads exact current identities and carries any
     * authoritative size resolved during that window over the stale sentinel
     * held by this checkpoint.
     */
    fun commit(): List<MediaClipRecord> {
        check(!committed) { "Camera listing checkpoint is already committed." }
        committed = true
        val candidate =
            MediaLibraryFiltering.sort(
                clipsByIdentity.values.toList(),
                MediaLibrarySortOrder.NEWEST,
            )
        return commitCatalog(candidate, dirty)
    }
}

/** Pure category filtering and ordering based on the shared core's action wire. */
internal object MediaLibraryFiltering {
    fun displayed(
        clips: List<MediaClipRecord>,
        category: MediaLibraryCategory,
        favoriteIDs: Set<String>,
        cameraID: String,
        sortOrder: MediaLibrarySortOrder,
        filters: MediaLibraryFilters = MediaLibraryFilters(),
        todayToken: String = LocalDate.now().format(DateTimeFormatter.BASIC_ISO_DATE),
        /** Offline multi-camera libraries resolve favorites with the owning bucket. */
        libraryKey: (MediaClipRecord) -> String = { clip -> clip.libraryKey(cameraID) },
    ): List<MediaClipRecord> {
        var filtered =
            when (category) {
                MediaLibraryCategory.ALL -> clips
                MediaLibraryCategory.VIDEOS ->
                    clips.filter {
                        it.contentKind == MediaContentKind.PLAYABLE_PROXY ||
                            it.contentKind == MediaContentKind.R3D_MASTER
                    }
                MediaLibraryCategory.PHOTOS ->
                    clips.filter { it.contentKind == MediaContentKind.STILL_PHOTO }
                MediaLibraryCategory.FAVORITES ->
                    clips.filter { libraryKey(it) in favoriteIDs }
            }
        if (filters.containers.isNotEmpty()) {
            filtered = filtered.filter { clip -> clip.containerFilter() in filters.containers }
        }
        if (filters.resolutions.isNotEmpty()) {
            filtered = filtered.filter { clip -> clip.resolutionFilter() in filters.resolutions }
        }
        if (filters.todayOnly) {
            filtered = filtered.filter { clip -> clip.captureDate.startsWith(todayToken) }
        }
        filters.storageId?.let { selectedStorage ->
            filtered = filtered.filter { clip -> clip.storageId == selectedStorage }
        }
        return sort(filtered, sortOrder)
    }

    fun sort(
        clips: List<MediaClipRecord>,
        sortOrder: MediaLibrarySortOrder,
    ): List<MediaClipRecord> =
        when (sortOrder) {
            MediaLibrarySortOrder.NEWEST ->
                clips.sortedWith(
                    compareByDescending<MediaClipRecord> { it.captureDate.ifEmpty { it.filename } }
                        .thenByDescending { it.filename.lowercase(Locale.US) },
                )
            MediaLibrarySortOrder.OLDEST ->
                clips.sortedWith(
                    compareBy<MediaClipRecord> { it.captureDate.ifEmpty { it.filename } }
                        .thenBy { it.filename.lowercase(Locale.US) },
                )
            MediaLibrarySortOrder.NAME ->
                clips.sortedBy { it.filename.lowercase(Locale.US) }
        }
}

/** Container metadata is the sanitized camera object filename supplied by the shared core. */
internal fun MediaClipRecord.containerFilter(): MediaContainerFilter? =
    when (codecLabel) {
        "MOV", "M4V" -> MediaContainerFilter.MOV
        "MP4" -> MediaContainerFilter.MP4
        else -> null
    }

/** Resolution filtering follows shared source, proxy, then filename precedence. */
internal fun MediaClipRecord.resolutionFilter(): MediaResolutionFilter? =
    resolutionFilter(sourcePixelWidth)
        ?: resolutionFilter(pixelWidth)
        ?: resolutionFilter(filename)

private fun resolutionFilter(pixelWidth: Int): MediaResolutionFilter? =
    when (pixelWidth) {
        in 6_000..Int.MAX_VALUE -> MediaResolutionFilter.SIX_K
        in 5_300..<6_000 -> MediaResolutionFilter.FIVE_FOUR_K
        in 3_500..<5_300 -> MediaResolutionFilter.FOUR_K
        in 1_000..<3_500 -> MediaResolutionFilter.HD
        else -> null
    }

private fun resolutionFilter(filename: String): MediaResolutionFilter? {
    val upper = filename.uppercase(Locale.US)
    return when {
        upper.contains("6K") -> MediaResolutionFilter.SIX_K
        upper.contains("5.4K") || upper.contains("54K") -> MediaResolutionFilter.FIVE_FOUR_K
        upper.contains("4K") || upper.contains("UHD") -> MediaResolutionFilter.FOUR_K
        upper.contains("HD") || upper.contains("1080") -> MediaResolutionFilter.HD
        else -> null
    }
}

/** Pure set updates used by long-press, tap, and sweep selection. */
internal object MediaLibrarySelection {
    fun begin(identity: String): Set<String> = setOf(identity)

    fun toggle(current: Set<String>, identity: String): Set<String> =
        current.toMutableSet().apply {
            if (!add(identity)) remove(identity)
        }

    /** Sweeps only add unseen items, avoiding a repeated drag toggling an item back off. */
    fun addSweep(current: Set<String>, identities: Collection<String>): Set<String> = current + identities

    fun retainVisible(current: Set<String>, visible: Set<String>): Set<String> = current.intersect(visible)
}

/** Stable private favorite/index identity — never a filename-only key. */
internal fun MediaClipRecord.libraryKey(cameraID: String): String =
    mediaLibraryKey(cameraID, storageId, handle, captureDate, filename)

/**
 * Bucket-independent object identity used to map offline multi-camera clips
 * back to their owning cache cameraID.
 */
internal fun MediaClipRecord.offlineObjectKey(): String =
    listOf(storageId.toString(), handle.toString(), captureDate, filename)
        .joinToString(separator = "\u0000")

private fun MediaObjectIdentity.libraryKey(cameraID: String): String =
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

private fun mergeAuthoritativeObjectSize(
    existing: MediaClipRecord?,
    incoming: MediaClipRecord,
): MediaClipRecord =
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

    fun encode(clips: List<MediaClipRecord>): String {
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

    fun decode(encoded: String): List<MediaClipRecord> =
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

    private fun writeClip(output: DataOutputStream, clip: MediaClipRecord) {
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

    private fun readClip(input: DataInputStream, version: Int): MediaClipRecord {
        val handle = input.readLong()
        val storageID = input.readLong()
        val sizeBytes = input.readLong()
        val captureDate = input.readUTF()
        val pixelWidth = input.readInt()
        val pixelHeight = input.readInt()
        val sourcePixelWidth = if (version >= VERSION) input.readInt() else 0
        val sourcePixelHeight = if (version >= VERSION) input.readInt() else 0
        val filename = input.readUTF()
        val contentKind = MediaContentKind.valueOf(input.readUTF())
        val stillPhoto =
            if (input.readBoolean()) {
                val formatLabel = input.readUTF()
                val previewStrategy = StillPreviewStrategy.valueOf(input.readUTF())
                StillPhotoClassification(formatLabel, previewStrategy)
            } else {
                null
            }
        check(sizeBytes >= 0)
        check(pixelWidth >= 0)
        check(pixelHeight >= 0)
        check(sourcePixelWidth >= 0)
        check(sourcePixelHeight >= 0)
        check(isSafePersistedFilename(filename))
        check((contentKind == MediaContentKind.STILL_PHOTO) == (stillPhoto != null))
        return MediaClipRecord(
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

private fun digest(value: String): String {
    val hex = "0123456789abcdef"
    val bytes = MessageDigest.getInstance("SHA-256").digest(value.toByteArray(Charsets.UTF_8))
    return buildString(bytes.size * 2) {
        bytes.forEach { byte ->
            val unsigned = byte.toInt() and 0xFF
            append(hex[unsigned ushr 4])
            append(hex[unsigned and 0x0F])
        }
    }
}
