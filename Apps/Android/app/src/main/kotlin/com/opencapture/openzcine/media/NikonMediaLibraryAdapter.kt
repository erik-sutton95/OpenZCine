package com.opencapture.openzcine.media

import com.opencapture.opencine.appkit.*
import com.opencapture.opencine.media.*
import com.opencapture.opencine.nikon.NikonMediaClipRecord
import com.opencapture.opencine.nikon.NikonMediaContentKind
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
        recordMappings += 1
        val clip = value.clip
        val key = clip.libraryKey(value.bucket)
        val asset = NikonMediaLibraryAssets.asset(value.bucket, key, clip)
        return MonitorMediaRecord(asset, value,
            MonitorMediaCacheAddress(thumbnail = null,
                representations = mapOf(asset.representations.single().id to cache.libraryRelativeAddress(value.bucket, MediaCacheObjectIdentity(clip))),
                favoriteKey = key),
            favorite = false,
            facts = MonitorMediaFilterFacts(orderKey = clip.captureDate.ifEmpty { clip.filename },
                playbackEligible = clip.contentKind == NikonMediaContentKind.PLAYABLE_PROXY ||
                    clip.contentKind == NikonMediaContentKind.STILL_PHOTO),
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
        val ordered = MediaLibraryFiltering.sort(candidate, MonitorMediaSort.NEWEST)
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
        val incoming = delta.upserts.map { asset ->
            val clip = service.mediaCatalogRecord(asset.id, binding)?.clip
                ?: throw MediaServiceException(MediaServiceFailure.RETIRED)
            NikonLibraryClip(bucket, clip)
        }
        val removedKeys = delta.removed.map { id ->
            (service.mediaCatalogRecord(id, binding)?.identity ?: throw MediaServiceException(MediaServiceFailure.RETIRED))
                .libraryKey(bucket)
        }
        if (!service.isCurrent(binding)) throw MediaServiceException(MediaServiceFailure.RETIRED)
        return assembleCatalog(existing, incoming, removedKeys, reset = delta.reset, complete = delta.complete)
    }
    /** Record mappings performed (test accounting for per-page cost). */
    internal var recordMappings: Int = 0
        private set
    /** The pure page step of [captureCatalog], after every source read is captured. */
    internal fun assembleCatalog(existing: List<MonitorMediaRecord<NikonLibraryClip>>, incoming: List<NikonLibraryClip>,
        removedKeys: List<String>, reset: Boolean, complete: Boolean): MonitorMediaCatalogCapture<NikonLibraryClip> {
        if (reset) listed.clear()
        val rows = LinkedHashMap<String, NikonLibraryClip>()
        // Existing rows keep their mapped record; only rows this page touches are mapped again.
        val existingByKey = HashMap<String, MonitorMediaRecord<NikonLibraryClip>>(existing.size * 2)
        existing.forEach { record ->
            val key = record.payload.clip.libraryKey(record.payload.bucket)
            rows[key] = record.payload; existingByKey.putIfAbsent(key, record)
        }
        for (value in incoming) {
            val key = value.clip.libraryKey(value.bucket)
            listed += key
            rows[key] = value.copy(clip = mergeAuthoritativeObjectSize(rows[key]?.clip, value.clip))
        }
        for (key in removedKeys) { listed -= key; rows.remove(key) }
        // Confirmed whole census only. A failed/canceled partial pass never deletes unseen rows.
        val censusCandidates = if (complete) rows.filter { (key, value) ->
            value.bucket == bucket && key !in listed
        }.keys else emptySet()
        // An untouched row (same payload instance, not a census candidate) is its existing record:
        // it is neither re-mapped nor reported as an amendment, so a page costs its own size.
        // A row whose favorite projection would change is re-mapped too (projection ORs a kept flag).
        val favorites = favoriteKeys()
        val changed = ArrayList<MonitorMediaRecord<NikonLibraryClip>>()
        val next = rows.map { (key, value) ->
            val old = existingByKey[key]
            if (old != null && old.payload === value && key !in censusCandidates &&
                old.favorite == (old.address.favoriteKey in favorites)) old
            else record(value.copy(requiresLocalRetention = key in censusCandidates)).also { changed += it }
        }
        val prior = existing.mapTo(HashSet(existing.size * 2)) { it.asset.id }
        val retained = next.mapTo(HashSet(next.size * 2)) { it.asset.id }
        return MonitorMediaCatalogCapture(resetLibrary = false,
            upserts = changed.filter { it.asset.id !in prior },
            removed = existing.filter { it.asset.id !in retained || it.payload.clip.libraryKey(it.payload.bucket) in censusCandidates }
                .map { it.asset.id },
            amendments = changed.filter { it.asset.id in prior },
            order = next.map { it.asset.id }, sourceFavoriteKeys = favorites)
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
    inner class Capture(values: List<NikonLibraryClip>) {
        private val owner = currentOwner()
        private val capturedToken = owner?.actionToken
        private var deletionAuthority: MonitorMediaLibraryDeletionAuthority? = null
        private val token: MonitorMediaLibraryActionToken? get() = deletionAuthority?.actionToken ?: capturedToken
        private val codec = currentCodec()
        private val root = cache.rootDirectory
        private val stores = values.map { it.bucket }.distinct().associateWith(index::catalogByteStore)
        private val generations = stores.mapValues { it.value.generation }
        private val namespaces = stores.mapValues { it.value.namespace }
        private val expected = values.associate { value ->
            val key = value.clip.libraryKey(value.bucket)
            val current = index.persistedClip(value.bucket, key)
            key to if (current != null && sameNikonActionContent(value.clip, current)) current else null
        }
        private val requested = values.associateBy { it.clip.libraryKey(it.bucket) }
        private val capturedRecords = owner?.state?.value?.records.orEmpty().filter {
            requested[it.payload.clip.libraryKey(it.payload.bucket)]?.let { original ->
                sameNikonActionContent(original.clip, it.payload.clip)
            } == true
        }
        val sourceIsCurrent: Boolean get() {
            owner?.state?.value // Establish the same synchronous published-state observation as actions.
            return currentOwner() === owner && currentCodec() === codec && cache.rootDirectory == root &&
                stores.all { (bucket, store) -> store.generation == generations[bucket] && store.namespace == namespaces[bucket] } &&
                requested.all { (key, old) ->
                    val current = index.persistedClip(old.bucket, key)
                    current == null || sameNikonActionContent(expected[key] ?: old.clip, current)
                } && currentOwner() === owner && currentCodec() === codec && cache.rootDirectory == root &&
                stores.all { (bucket, store) -> store.generation == generations[bucket] && store.namespace == namespaces[bucket] }
        }
        val isCurrent: Boolean get() = sourceIsCurrent && deletionAuthority?.isCurrent != false &&
            (token?.let { owner?.isCurrent(it) == true } ?: true)
        fun captureDeletionAuthority(): MonitorMediaLibraryDeletionAuthority? =
            owner?.captureDeletion(MonitorMediaLibraryIOKey("catalog-deletion")) { sourceIsCurrent }
        private fun mutate(value: NikonLibraryClip, operation: () -> Unit): Boolean {
            val key = value.clip.libraryKey(value.bucket)
            val requestedValue = requested[key] ?: return false
            val observed = expected[key]
            // A conflicting row at capture is not an absent row eligible for an upsert.
            if (observed == null && index.persistedClip(value.bucket, key)
                    ?.let { !sameNikonActionContent(requestedValue.clip, it) } == true) return false
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
            onProgress: (Int, Int) -> Unit): Int =
            deleteBatch(values, deleteObject, onProgress, accepted = null)
        suspend fun deleteBatch(values: List<NikonLibraryClip>,
            deleteObject: suspend (NikonLibraryClip) -> Boolean,
            onProgress: (Int, Int) -> Unit,
            accepted: MonitorMediaLibraryDeletionAuthority?,
            preparation: MonitorMediaDeletionPreparation = MonitorMediaDeletionPreparation.PRESERVE_GALLERY,
            prepare: () -> Unit = {},
            afterFinish: (suspend (MonitorMediaLibraryDeletionAuthority) -> Unit)? = null): Int {
            val authority = accepted ?: captureDeletionAuthority()
            if (preparation == MonitorMediaDeletionPreparation.RETIRE_GALLERY) deletionAuthority = authority
            val targets = values.map { MonitorMediaDeletionTarget(it, listOf(it)) }
            val port = MonitorMediaDeletionPort<NikonLibraryClip, NikonLibraryClip>(remove = {
                if (deleteObject(it)) MonitorMediaDeleteAcknowledgement.REMOVED else MonitorMediaDeleteAcknowledgement.RETAINED
            }, commit = { value, survivors ->
                if (survivors.isNotEmpty()) false else withContext(Dispatchers.IO) {
                    mutate(value) {
                        runCatching { cache.purgeEntry(value.bucket, MediaCacheObjectIdentity(value.clip)) }
                        index.purgeClip(value.bucket, value.clip) { isCurrent }
                    }
                }
            }, finish = {
                publish()
                if (authority?.isCompleting == true && sourceIsCurrent) afterFinish?.invoke(authority)
            })
            val progress: (MonitorMediaDeletionProgress) -> Unit = { value ->
                if (value.completed > 0 && isCurrent) onProgress(value.completed, value.total)
            }
            return if (owner != null && authority != null) owner.deleteHostBatch(authority, targets, values.size,
                preparation, prepare, progress, port)
            else MonitorMediaOrderedDeletion.run(targets, values.size, { isCurrent }, port, progress)
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
                val current = index.persistedClip(value.bucket, value.clip.libraryKey(value.bucket))
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
