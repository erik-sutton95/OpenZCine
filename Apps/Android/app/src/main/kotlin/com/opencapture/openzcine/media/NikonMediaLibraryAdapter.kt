package com.opencapture.openzcine.media

import com.opencapture.opencine.appkit.*
import com.opencapture.opencine.media.*
import com.opencapture.opencine.nikon.NikonMediaClipRecord
import com.opencapture.opencine.nikon.NikonMediaLibraryAssets
import com.opencapture.opencine.nikon.NikonMediaService
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext

internal data class NikonLibraryClip(val bucket: String, val clip: NikonMediaClipRecord,
    /** An immutable census candidate, stripped before publication. Not a source metadata fact. */
    val requiresLocalRetention: Boolean = false)

/** Actual one-set favorite policy stays in native rating/heart actions. */
internal class NikonLibraryFavorites(private val index: MediaLibraryIndex, private val buckets: List<String>) : MonitorMediaFavoritesStore {
    override fun favorites(): Set<String> = buckets.flatMap { index.favoriteIDs(it) }.toSet()
    override fun saveFavorites(keys: Set<String>) {
        // Actual native actions own durable writes. Catalog projection cannot rewrite them.
    }

}

/** Pure legacy codec/address preparation; synchronous capture is fenced by its actual producer. */
internal class NikonMediaLibraryCodec(
    private val bucket: String,
    private val source: NikonMediaService?,
    private val cache: MediaCacheStore,
    private val favoriteKeys: () -> Set<String>,
    private val hasLocalCopy: (NikonMediaClipRecord) -> Boolean,
) : MonitorMediaCatalogCodec<NikonLibraryClip> {
    private val listed = linkedSetOf<String>()
    fun beginListing() { listed.clear() }
    fun record(value: NikonLibraryClip): MonitorMediaRecord<NikonLibraryClip> {
        val clip = value.clip
        val key = clip.libraryKey(value.bucket)
        val asset = NikonMediaLibraryAssets.asset(value.bucket, key, clip)
        return MonitorMediaRecord(asset, value,
            MonitorMediaCacheAddress(thumbnail = null,
                representations = mapOf(asset.representations.single().id to cache.libraryRelativeAddress(value.bucket, MediaCacheObjectIdentity(clip))),
                favoriteKey = key),
            favorite = false,
            facts = MonitorMediaFilterFacts(orderKey = clip.captureDate.ifEmpty { clip.filename }),
            favoriteAuthority = MonitorMediaFavoriteAuthority.LEGACY_COMBINED,
            sourceFavorite = null)
    }
    override fun decode(bytes: ByteArray): List<MonitorMediaRecord<NikonLibraryClip>> =
        decodeMediaLibraryCatalogBytes(bytes).map { record(NikonLibraryClip(bucket, it)) }
    override fun encode(records: List<MonitorMediaRecord<NikonLibraryClip>>): ByteArray =
        encodeMediaLibraryCatalogBytes(records.filter { it.payload.bucket == bucket }.map { it.payload.clip })
    override fun encodeForPersistence(records: List<MonitorMediaRecord<NikonLibraryClip>>, currentBytes: ByteArray?): ByteArray? {
        val current = currentBytes?.let(::decodeMediaLibraryCatalogBytes).orEmpty()
        val byIdentity = current.associateBy { it.libraryKey(bucket) }
        val candidate = records.filter { it.payload.bucket == bucket }.map {
            mergeAuthoritativeObjectSize(byIdentity[it.payload.clip.libraryKey(bucket)], it.payload.clip)
        }
        val ordered = MediaLibraryFiltering.sort(candidate, MediaLibrarySortOrder.NEWEST)
        // Same no-change checkpoint rule, one encode only after reconciliation says it is dirty.
        if (current.associateBy { it.libraryKey(bucket) } == ordered.associateBy { it.libraryKey(bucket) }) return null
        return encodeMediaLibraryCatalogBytes(ordered)
    }
    override fun capture(asset: MediaAsset, binding: MediaBrowseBinding): MonitorMediaRecord<NikonLibraryClip> {
        val service = source ?: throw MediaServiceException(MediaServiceFailure.RETIRED)
        if (!service.isCurrent(binding)) throw MediaServiceException(MediaServiceFailure.RETIRED)
        val clip = service.mediaCatalogRecord(asset.id, binding)?.clip
            ?: throw MediaServiceException(MediaServiceFailure.RETIRED)
        return record(NikonLibraryClip(bucket, clip))
    }
    override fun captureCatalog(delta: MediaCatalogDelta, binding: MediaBrowseBinding,
        existing: List<MonitorMediaRecord<NikonLibraryClip>>): MonitorMediaCatalogCapture<NikonLibraryClip> {
        val service = source ?: throw MediaServiceException(MediaServiceFailure.RETIRED)
        if (!service.isCurrent(binding)) throw MediaServiceException(MediaServiceFailure.RETIRED)
        if (delta.reset) listed.clear()
        val rows = LinkedHashMap<String, NikonLibraryClip>()
        existing.forEach { rows[it.payload.clip.libraryKey(it.payload.bucket)] = it.payload }
        for (asset in delta.upserts) {
            val incoming = capture(asset, binding).payload
            val key = incoming.clip.libraryKey(incoming.bucket)
            listed += key
            rows[key] = incoming.copy(clip = mergeAuthoritativeObjectSize(rows[key]?.clip, incoming.clip))
        }
        for (id in delta.removed) {
            val removal = service.mediaCatalogRecord(id, binding)?.identity
                ?: throw MediaServiceException(MediaServiceFailure.RETIRED)
            val key = removal.libraryKey(bucket)
            listed -= key; rows.remove(key)
        }
        // Confirmed whole census only. A failed/canceled partial pass never deletes unseen rows.
        val censusCandidates = if (delta.complete) rows.filter { (key, value) ->
            value.bucket == bucket && key !in listed
        }.keys else emptySet()
        if (!service.isCurrent(binding)) throw MediaServiceException(MediaServiceFailure.RETIRED)
        val next = rows.map { (key, value) -> record(value.copy(requiresLocalRetention = key in censusCandidates)) }
        val prior = existing.map { it.asset.id }.toSet()
        val retained = next.map { it.asset.id }.toSet()
        return MonitorMediaCatalogCapture(resetLibrary = false,
            upserts = next.filter { it.asset.id !in prior },
            removed = existing.filter { it.asset.id !in retained || it.payload.clip.libraryKey(it.payload.bucket) in censusCandidates }
                .map { it.asset.id },
            amendments = next.filter { it.asset.id in prior },
            order = next.map { it.asset.id }, sourceFavoriteKeys = favoriteKeys())
    }
    override suspend fun prepareCatalog(capture: MonitorMediaCatalogCapture<NikonLibraryClip>,
        binding: MediaBrowseBinding, existing: List<MonitorMediaRecord<NikonLibraryClip>>): MonitorMediaCatalogCapture<NikonLibraryClip> {
        // All candidate rows/content/removals were captured under the actual source before suspension.
        // The shared owner fences request/lifetime/binding/directory generation around this bounded IO.
        val candidates = capture.amendments.filter { it.payload.requiresLocalRetention }
        val keep = withContext(Dispatchers.IO) {
            candidates.filter { hasLocalCopy(it.payload.clip) }.map { it.asset.id }.toSet()
        }
        fun prepared(record: MonitorMediaRecord<NikonLibraryClip>): MonitorMediaRecord<NikonLibraryClip> =
            record.copy(payload = record.payload.copy(requiresLocalRetention = false))
        return capture.copy(
            removed = capture.removed.filter { it !in keep },
            upserts = capture.upserts.map(::prepared),
            amendments = capture.amendments.map(::prepared),
            sourceFavoriteKeys = favoriteKeys())
    }

}

/** Synchronous native action state while the caller keeps its Compose subscription. */
internal class NikonMediaLibrarySelection(
    private val owner: () -> MonitorMediaLibraryModel<NikonLibraryClip>?,
    private val observe: () -> MonitorMediaLibraryState<NikonLibraryClip>,
) {
    var selecting: Boolean
        get() {
            observe()
            return owner()?.state?.value?.selecting ?: false
        }
        set(value) {
            owner()?.let { it.select(it.state.value.selectedIDs, selecting = value) }
        }
    var selectedKeys: Set<String>
        get() {
            observe()
            val snapshot = owner()?.state?.value ?: return emptySet()
            return snapshot.records.filter { it.asset.id in snapshot.selectedIDs }
                .map { it.payload.clip.libraryKey(it.payload.bucket) }.toSet()
        }
        set(value) {
            owner()?.let { actual ->
                val snapshot = actual.state.value
                actual.select(snapshot.records.filter {
                    it.payload.clip.libraryKey(it.payload.bucket) in value
                }.map { it.asset.id }.toSet(), selecting = snapshot.selecting)
            }
        }
}

/** Actual host action completion; native calls retain their existing owner/admission and wire order. */
internal class NikonMediaLibraryActions(
    private val index: MediaLibraryIndex,
    private val cache: MediaCacheStore,
    private val currentOwner: () -> MonitorMediaLibraryModel<NikonLibraryClip>?,
    private val currentCodec: () -> NikonMediaLibraryCodec?,
) {
    fun capture(values: List<NikonLibraryClip>): Capture = Capture(values)
    fun captureRatingCompletion(value: NikonLibraryClip, onFavorites: (Set<String>) -> Unit): NikonMediaRatingCompletion {
        val captured = capture(listOf(value))
        return NikonMediaRatingCompletion({ captured.canPublish(value) }) { stars ->
            captured.mirrorRating(value, stars)?.let { onFavorites(it); true } ?: false
        }
    }
    fun beginDeletion(values: List<NikonLibraryClip>, retireListing: () -> Unit): Capture {
        retireListing()
        return capture(values)
    }
    inner class Capture(values: List<NikonLibraryClip>) {
        private val owner = currentOwner()
        private val token = owner?.actionToken
        private val codec = currentCodec()
        private val root = cache.rootDirectory
        private val stores = values.map { it.bucket }.distinct().associateWith(index::catalogByteStore)
        private val generations = stores.mapValues { it.value.generation }
        private val namespaces = stores.mapValues { it.value.namespace }
        private val expected = values.associate { value ->
            val current = index.persistedClips(value.bucket).firstOrNull {
                it.libraryKey(value.bucket) == value.clip.libraryKey(value.bucket)
            }
            value.clip.libraryKey(value.bucket) to if (current != null && sameNikonActionContent(value.clip, current)) current else null
        }
        private val requested = values.associateBy { it.clip.libraryKey(it.bucket) }
        private val favoritesAtCapture = values.map { it.bucket }.distinct().associateWith(index::favoriteIDs)
        fun favoriteTarget(value: NikonLibraryClip): Boolean = value.clip.libraryKey(value.bucket) !in favoritesAtCapture[value.bucket].orEmpty()
        private val capturedRecords = owner?.state?.value?.records.orEmpty().filter {
            requested[it.payload.clip.libraryKey(it.payload.bucket)]?.let { original ->
                sameNikonActionContent(original.clip, it.payload.clip)
            } == true
        }
        val isCurrent: Boolean get() {
            owner?.state?.value // Establish the same synchronous published-state observation as actions.
            return currentOwner() === owner && cache.rootDirectory == root &&
                (token == null || owner?.isCurrent(token) == true) &&
                stores.all { (bucket, store) -> store.generation == generations[bucket] && store.namespace == namespaces[bucket] } &&
                requested.values.all { old ->
                    val current = index.persistedClips(old.bucket).firstOrNull { it.libraryKey(old.bucket) == old.clip.libraryKey(old.bucket) }
                    current == null || sameNikonActionContent(expected[old.clip.libraryKey(old.bucket)] ?: old.clip, current)
                }
        }
        private fun mutate(value: NikonLibraryClip, operation: () -> Unit): Boolean {
            val key = value.clip.libraryKey(value.bucket)
            val requestedValue = requested[key] ?: return false
            val observed = expected[key]
            // A conflicting row at capture is not an absent row eligible for an upsert.
            if (observed == null && index.persistedClips(value.bucket).any {
                    it.libraryKey(value.bucket) == key && !sameNikonActionContent(requestedValue.clip, it) }) return false
            return index.mutateCapturedAction(value.bucket, value.clip, observed,
                generations[value.bucket] ?: return false, { isCurrent }, operation)
        }
        fun canPublish(value: NikonLibraryClip): Boolean = mutate(value) {}
        fun toggleFavorite(value: NikonLibraryClip): Set<String>? {
            var result: Set<String>? = null
            if (!mutate(value) { result = index.toggleFavorite(value.bucket, value.clip) }) return null
            publish(); return result
        }
        fun mirrorRating(value: NikonLibraryClip, stars: Int): Set<String>? {
            var result: Set<String>? = null
            if (!mutate(value) { result = index.setFavorite(value.bucket, value.clip, stars >= 1) }) return null
            publish(); return result.takeIf { isCurrent }
        }
        /** Caller drains native transfer first and supplies each admitted native boolean result. */
        suspend fun deleteBatch(values: List<NikonLibraryClip>,
            deleteObject: suspend (NikonLibraryClip) -> Boolean,
            onProgress: (Int, Int) -> Unit): Int {
            var removed = 0
            values.forEachIndexed { index, value ->
                if (deleteObject(value)) {
                    val purged = withContext(Dispatchers.IO) {
                        mutate(value) {
                            runCatching { cache.purgeEntry(value.bucket, MediaCacheObjectIdentity(value.clip)) }
                            this@NikonMediaLibraryActions.index.purgeClip(value.bucket, value.clip) { isCurrent }
                        }
                    }
                    if (purged) removed += 1
                }
                if (isCurrent) onProgress(index + 1, values.size)
            }
            publish()
            return removed
        }
        fun publish() {
            if (!isCurrent) return
            val actual = owner ?: return
            val capturedToken = token ?: return
            val capturedCodec = codec ?: return
            val amendments = mutableListOf<MonitorMediaRecord<NikonLibraryClip>>()
            val removed = mutableListOf<MediaAssetID>()
            capturedRecords.forEach { old ->
                val value = old.payload
                val current = index.persistedClips(value.bucket).firstOrNull {
                    it.libraryKey(value.bucket) == value.clip.libraryKey(value.bucket)
                }
                if (current == null) removed += old.asset.id
                else if (sameNikonActionContent(value.clip, current)) {
                    val record = capturedCodec.record(NikonLibraryClip(value.bucket, current))
                    if (record.asset.id == old.asset.id) amendments += record
                }
            }
            val favorites = actual.state.value.records.map { it.payload.bucket }.distinct()
                .flatMap(index::favoriteIDs).toSet()
            try {
                actual.applyLocalRecords(MonitorMediaCatalogCapture(resetLibrary = false,
                    upserts = emptyList(), removed = removed, amendments = amendments,
                    sourceFavoriteKeys = favorites), capturedToken, persist = false)
            } catch (error: MediaServiceException) {
                if (error.failure != MediaServiceFailure.RETIRED) throw error
            }
        }
    }
}

/** Captured at the actual viewer operation start, never reconstructed after native suspension. */
internal class NikonMediaRatingCompletion(
    private val admitted: () -> Boolean,
    private val apply: (Int) -> Boolean,
) {
    val isCurrent: Boolean get() = admitted()
    fun mirror(stars: Int): Boolean = apply(stars)
}
