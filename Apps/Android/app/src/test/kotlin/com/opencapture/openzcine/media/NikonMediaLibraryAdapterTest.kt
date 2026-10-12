package com.opencapture.openzcine.media

import com.opencapture.opencine.appkit.*
import com.opencapture.opencine.core.CameraSessionID
import com.opencapture.opencine.core.ControlEpoch
import com.opencapture.opencine.media.MediaBrowseBinding
import com.opencapture.opencine.media.MediaCatalog
import com.opencapture.opencine.nikon.NikonMediaClipRecord
import com.opencapture.opencine.nikon.NikonMediaContentKind
import java.nio.file.Files
import java.util.concurrent.atomic.AtomicBoolean
import kotlin.io.path.createTempDirectory
import kotlin.test.*
import kotlinx.coroutines.test.runTest
import kotlinx.coroutines.async

class NikonMediaLibraryAdapterTest {
    @Test fun `playback eligibility preserves raw master kind and canonical source identity`() {
        val root = createTempDirectory("SIMULATED-nikon-playback-facts")
        try {
            val codec = NikonMediaLibraryCodec("SIMULATED", null, MediaCacheStore(root), { emptySet() }, { false })
            val facts = listOf(NikonMediaContentKind.PLAYABLE_PROXY to true, NikonMediaContentKind.R3D_MASTER to false,
                NikonMediaContentKind.STILL_PHOTO to true, NikonMediaContentKind.UNSUPPORTED to false)
            for ((kind, eligible) in facts) {
                val source = clip(100).copy(contentKind = kind)
                val record = codec.record(NikonLibraryClip("SIMULATED", source))
                assertEquals(eligible, record.facts.playbackEligible)
                assertEquals(source, record.payload.clip)
                assertEquals(source.filename, record.asset.filename)
                assertEquals(if (kind == NikonMediaContentKind.STILL_PHOTO) com.opencapture.opencine.media.MediaAssetKind.PHOTO
                    else com.opencapture.opencine.media.MediaAssetKind.VIDEO, record.asset.kind)
            }
        } finally { root.toFile().deleteRecursively() }
    }
    @Test fun `exact canonical preference bytes round trip without extra registry writes`() {
        val preferences = Preferences()
        val index = MediaLibraryIndex(preferences)
        val clip = clip(100)
        index.rememberCameraListing("SIMULATED", listOf(clip))
        val store = index.catalogByteStore("SIMULATED")
        val original = assertNotNull(store.read())
        assertEquals(listOf(clip), decodeMediaLibraryCatalogBytes(original))
        val writes = preferences.writes
        store.update({ true }) { null }
        assertEquals(writes, preferences.writes)
        assertContentEquals(original, store.read())
        var admitted = true
        assertFailsWith<IllegalStateException> {
            store.update({ admitted }) { admitted = false; byteArrayOf(1) }
        }
        assertContentEquals(original, store.read())
    }

    @Test fun `current resolved size survives captured sentinel and unchanged checkpoint skips encode write`() {
        val root = createTempDirectory("nikon-library-draft")
        try {
            val index = MediaLibraryIndex(Preferences())
            val current = clip(4_500_000_000L)
            index.rememberCameraListing("SIMULATED", listOf(current))
            val store = index.catalogByteStore("SIMULATED")
            val before = assertNotNull(store.read())
            val codec = NikonMediaLibraryCodec("SIMULATED", null, MediaCacheStore(root), { emptySet() }, { false })
            val stale = codec.record(NikonLibraryClip("SIMULATED", current.copy(sizeBytes = 0xFFFF_FFFFL)))
            assertNull(codec.encodeForPersistence(listOf(stale), before))
            assertContentEquals(before, store.read())
            assertEquals(current, index.persistedClips("SIMULATED").single())
        } finally { root.toFile().deleteRecursively() }
    }

    @Test fun `census preparation uses original exact zero-length predicate off owner thread`() = runTest {
        val root = createTempDirectory("nikon-library-draft")
        try {
            val cache = MediaCacheStore(root)
            val old = clip(0)
            val identity = MediaCacheObjectIdentity(old)
            val location = root.resolve(cache.libraryRelativeAddress("SIMULATED", identity))
            Files.createDirectories(location.parent); Files.write(location, byteArrayOf())
            val ownerThread = Thread.currentThread()
            val checkedOffOwner = AtomicBoolean(false)
            val codec = NikonMediaLibraryCodec("SIMULATED", null, cache, { emptySet() }, {
                checkedOffOwner.set(Thread.currentThread() !== ownerThread)
                cache.completedEntryOrNull("SIMULATED", MediaCacheObjectIdentity(it), it.sizeBytes) != null
            })
            val before = codec.record(NikonLibraryClip("SIMULATED", old))
            val candidate = before.copy(payload = before.payload.copy(requiresLocalRetention = true))
            val capture = MonitorMediaCatalogCapture(resetLibrary = false, upserts = emptyList<NikonLibraryClip>().map(codec::record),
                removed = listOf(before.asset.id), amendments = listOf(candidate))
            val prepared = codec.prepareCatalog(capture, MediaBrowseBinding(CameraSessionID(), ControlEpoch(1)), listOf(before))
            assertTrue(checkedOffOwner.get())
            assertTrue(prepared.removed.isEmpty())
            assertEquals(old, prepared.amendments.single().payload.clip)
            assertFalse(prepared.amendments.single().payload.requiresLocalRetention)
            assertEquals(0L, Files.size(location))
            assertEquals(1L, Files.list(location.parent).use { it.count() })
        } finally { root.toFile().deleteRecursively() }
    }

    @Test fun `explicit source tombstone is not converted to a downloaded census survivor`() = runTest {
        val root = createTempDirectory("nikon-library-draft")
        try {
            var localProbes = 0
            val codec = NikonMediaLibraryCodec("SIMULATED", null, MediaCacheStore(root), { emptySet() }, {
                localProbes += 1; true
            })
            val old = codec.record(NikonLibraryClip("SIMULATED", clip(100)))
            val removed = MonitorMediaCatalogCapture<NikonLibraryClip>(resetLibrary = false,
                upserts = emptyList(), removed = listOf(old.asset.id))
            val prepared = codec.prepareCatalog(removed, MediaBrowseBinding(CameraSessionID(), ControlEpoch(1)), listOf(old))
            assertEquals(listOf(old.asset.id), prepared.removed)
            assertEquals(0, localProbes)
        } finally { root.toFile().deleteRecursively() }
    }

    @Test fun `actual settings clear retires captured byte commit without restoring cleared rows`() {
        val preferences = Preferences()
        val index = MediaLibraryIndex(preferences)
        val originalClip = clip(100)
        index.rememberCameraListing("SIMULATED", listOf(originalClip))
        index.setFavorite("SIMULATED", originalClip, true)
        val oldStore = index.catalogByteStore("SIMULATED")
        val before = assertNotNull(oldStore.read())
        val generation = oldStore.generation
        val favorites = index.favoriteIDs("SIMULATED")
        assertEquals(1, favorites.size)
        var writesAfterClear = -1
        assertFailsWith<IllegalStateException> {
            oldStore.update({ oldStore.generation == generation }) { current ->
                assertContentEquals(before, current)
                index.clearCameraCatalogs()
                writesAfterClear = preferences.writes
                before
            }
        }
        assertEquals(writesAfterClear, preferences.writes)
        assertNull(oldStore.read())
        assertTrue(index.persistedClips("SIMULATED").isEmpty())
        assertEquals(favorites, index.favoriteIDs("SIMULATED"))
        assertEquals(generation + 1, oldStore.generation)
        val successor = originalClip.copy(handle = 5, filename = "Successor.MOV")
        val successorBytes = encodeMediaLibraryCatalogBytes(listOf(successor))
        val successorStore = index.catalogByteStore("SIMULATED")
        val successorGeneration = successorStore.generation
        successorStore.update({ successorStore.generation == successorGeneration }) {
            assertNull(it)
            successorBytes
        }
        assertContentEquals(successorBytes, successorStore.read())
        assertEquals(listOf(successor), index.persistedClips("SIMULATED"))
    }

    @Test fun `catalog projection cannot rewrite actual favorite action during census preparation`() = runTest {
        val root = createTempDirectory("nikon-library-draft")
        try {
            val preferences = Preferences()
            val index = MediaLibraryIndex(preferences)
            val old = clip(100)
            index.rememberCameraListing("SIMULATED", listOf(old))
            index.setFavorite("SIMULATED", old, true)
            val key = old.libraryKey("SIMULATED")
            val codec = NikonMediaLibraryCodec("SIMULATED", null, MediaCacheStore(root),
                { index.favoriteIDs("SIMULATED") }, {
                    index.setFavorite("SIMULATED", old, false)
                    true
                })
            val prior = codec.record(NikonLibraryClip("SIMULATED", old))
            val captured = MonitorMediaCatalogCapture<NikonLibraryClip>(resetLibrary = false,
                upserts = emptyList(), removed = listOf(prior.asset.id),
                amendments = listOf(prior.copy(payload = prior.payload.copy(requiresLocalRetention = true))),
                sourceFavoriteKeys = setOf(key))
            val prepared = codec.prepareCatalog(captured, MediaBrowseBinding(CameraSessionID(), ControlEpoch(1)), listOf(prior))
            assertEquals(emptySet(), prepared.sourceFavoriteKeys)
            assertTrue(prepared.removed.isEmpty())
            val writesAfterAction = preferences.writes
            NikonLibraryFavorites(index, listOf("SIMULATED")).saveFavorites(setOf(key))
            assertEquals(writesAfterAction, preferences.writes)
            assertTrue(index.favoriteIDs("SIMULATED").isEmpty())
        } finally { root.toFile().deleteRecursively() }
    }

    @Test fun `actual captured rating callback cannot rewrite refreshed or rebound same-key content`() = runTest {
        val root = createTempDirectory("nikon-action-draft")
        try {
            val preferences = Preferences(); val index = MediaLibraryIndex(preferences)
            val cache = MediaCacheStore(root); val old = clip(100)
            index.rememberCameraListing("SIMULATED", listOf(old))
            val codec = NikonMediaLibraryCodec("SIMULATED", null, cache, { index.favoriteIDs("SIMULATED") }, { false })
            fun owner(row: NikonMediaClipRecord) = MonitorMediaLibraryModel(
                MonitorMediaCache(MonitorMediaCacheDirectory(root.toFile()), codec,
                    eligibility = MonitorMediaOriginalEligibility.ExactSize, preservedMetadata = emptyList(),
                    catalogAddress = index.catalogByteStore("SIMULATED").namespace,
                    catalogStore = index.catalogByteStore("SIMULATED")),
                NikonLibraryFavorites(index, listOf("SIMULATED")), scope = this,
                cacheScanning = MonitorMediaCacheScanning.IMMEDIATE, initialCatalog = MediaCatalog(),
                initialRecords = listOf(codec.record(NikonLibraryClip("SIMULATED", row))))
            val originalOwner = owner(old); var currentOwner: MonitorMediaLibraryModel<NikonLibraryClip>? = originalOwner
            val actions = NikonMediaLibraryActions(index, cache, { currentOwner }, { codec })
            val callback = actions.captureRatingCompletion(NikonLibraryClip("SIMULATED", old)) { fail("Retired favorite callback published") }
            val entered = kotlinx.coroutines.CompletableDeferred<Unit>(); val release = kotlinx.coroutines.CompletableDeferred<Unit>()
            val pending = async {
                entered.complete(Unit); release.await(); callback.mirror(4)
            }
            entered.await()
            val successor = old.copy(sizeBytes = 200)
            index.rememberCameraListing("SIMULATED", listOf(successor))
            originalOwner.applyLocalRecords(MonitorMediaCatalogCapture(resetLibrary = true,
                upserts = listOf(codec.record(NikonLibraryClip("SIMULATED", successor)))), originalOwner.actionToken)
            val bytes = assertNotNull(index.catalogByteStore("SIMULATED").read()); val writes = preferences.writes
            release.complete(Unit); assertFalse(pending.await())
            assertFalse(callback.isCurrent)
            assertContentEquals(bytes, index.catalogByteStore("SIMULATED").read())
            assertEquals(writes, preferences.writes); assertTrue(index.favoriteIDs("SIMULATED").isEmpty())
            val callbackAgain = actions.captureRatingCompletion(NikonLibraryClip("SIMULATED", successor)) { fail("Rebound callback published") }
            originalOwner.close(); val successorOwner = owner(successor); currentOwner = successorOwner
            assertFalse(callbackAgain.mirror(4)); assertFalse(callbackAgain.isCurrent)
            assertEquals(writes, preferences.writes)
            originalOwner.dispose(); successorOwner.dispose()
        } finally { root.toFile().deleteRecursively() }
    }

    @Test fun `actual delete capsule preserves successor bytes progress and pending batch authority`() = runTest {
        val root = createTempDirectory("nikon-action-draft")
        try {
            val index = MediaLibraryIndex(Preferences()); val cache = MediaCacheStore(root); val old = clip(100)
            index.rememberCameraListing("SIMULATED", listOf(old))
            val codec = NikonMediaLibraryCodec("SIMULATED", null, cache, { emptySet() }, { false })
            val owner = MonitorMediaLibraryModel(MonitorMediaCache(MonitorMediaCacheDirectory(root.toFile()), codec,
                eligibility = MonitorMediaOriginalEligibility.ExactSize, catalogAddress = "SIMULATED/index.json",
                preservedMetadata = emptyList(), catalogStore = index.catalogByteStore("SIMULATED")),
                NikonLibraryFavorites(index, listOf("SIMULATED")), scope = this,
                cacheScanning = MonitorMediaCacheScanning.IMMEDIATE, initialCatalog = MediaCatalog(),
                initialRecords = listOf(codec.record(NikonLibraryClip("SIMULATED", old))))
            val actions = NikonMediaLibraryActions(index, cache, { owner }, { codec })
            val value = NikonLibraryClip("SIMULATED", old)
            val capture = owner.close().let { actions.capture(listOf(value)) }
            val entered = kotlinx.coroutines.CompletableDeferred<Unit>(); val release = kotlinx.coroutines.CompletableDeferred<Unit>()
            var progress: Pair<Int, Int>? = null
            val pending = async {
                capture.deleteBatch(listOf(value), { entered.complete(Unit); release.await(); true },
                    { done, total -> progress = done to total })
            }
            entered.await()
            val successor = old.copy(sizeBytes = 200)
            index.rememberCameraListing("SIMULATED", listOf(successor))
            owner.applyLocalRecords(MonitorMediaCatalogCapture(resetLibrary = true,
                upserts = listOf(codec.record(NikonLibraryClip("SIMULATED", successor)))), owner.actionToken)
            val path = root.resolve(cache.libraryRelativeAddress("SIMULATED", MediaCacheObjectIdentity(successor)))
            Files.createDirectories(path.parent); val content = ByteArray(200) { 9 }; Files.write(path, content)
            val bytes = assertNotNull(index.catalogByteStore("SIMULATED").read()); progress = 7 to 8
            release.complete(Unit); assertEquals(0, pending.await())
            assertFalse(capture.isCurrent); assertEquals(7 to 8, progress)
            assertContentEquals(content, Files.readAllBytes(path))
            assertContentEquals(bytes, index.catalogByteStore("SIMULATED").read())
            assertEquals(200L, owner.state.value.records.single().payload.clip.sizeBytes)
            owner.dispose()
        } finally { root.toFile().deleteRecursively() }
    }

    @Test fun `actual delete capsule holds grid and publishes successful removals with protected favorites once`() = runTest {
        val root = createTempDirectory("nikon-action-draft")
        try {
            val preferences = Preferences(); val index = MediaLibraryIndex(preferences); val cache = MediaCacheStore(root)
            val removed = clip(100); val protected = removed.copy(handle = removed.handle + 1, filename = "SIMULATED-protected.MOV")
            index.rememberCameraListing("SIMULATED", listOf(removed, protected))
            index.setFavorite("SIMULATED", protected, true)
            val codec = NikonMediaLibraryCodec("SIMULATED", null, cache, { index.favoriteIDs("SIMULATED") }, { false })
            val rows = listOf(removed, protected).map { codec.record(NikonLibraryClip("SIMULATED", it)) }
            val owner = MonitorMediaLibraryModel(MonitorMediaCache(MonitorMediaCacheDirectory(root.toFile()), codec,
                eligibility = MonitorMediaOriginalEligibility.ExactSize, catalogAddress = "SIMULATED/index.json",
                preservedMetadata = emptyList(), catalogStore = index.catalogByteStore("SIMULATED")),
                NikonLibraryFavorites(index, listOf("SIMULATED")), scope = this,
                cacheScanning = MonitorMediaCacheScanning.IMMEDIATE, initialCatalog = MediaCatalog(), initialRecords = rows)
            owner.select(rows.map { it.asset.id }.toSet(), selecting = true)
            val actions = NikonMediaLibraryActions(index, cache, { owner }, { codec })
            val values = listOf(removed, protected).map { NikonLibraryClip("SIMULATED", it) }
            val capture = owner.close().let { actions.capture(values) }
            val publishedRows = owner.state.value.records
            var wireCalls = 0
            val count = capture.deleteBatch(values, { value ->
                assertEquals(publishedRows, owner.state.value.records)
                wireCalls += 1; value.clip.handle != protected.handle
            }, { _, _ -> })
            assertEquals(2, wireCalls); assertEquals(1, count)
            assertEquals(listOf(protected), index.persistedClips("SIMULATED"))
            assertEquals(listOf(protected), owner.state.value.records.map { it.payload.clip })
            assertEquals(setOf(protected.libraryKey("SIMULATED")), index.favoriteIDs("SIMULATED"))
            assertTrue(owner.state.value.records.single().favorite)
            assertEquals(setOf(owner.state.value.records.single().asset.id), owner.state.value.selectedIDs)
            assertTrue(owner.state.value.catalog.assets.isEmpty())
            owner.dispose()
        } finally { root.toFile().deleteRecursively() }
    }

    @Test fun `actual captured rating admits resolved sentinel size and retains one-set zero-rating policy`() = runTest {
        val root = createTempDirectory("nikon-action-draft")
        try {
            val index = MediaLibraryIndex(Preferences()); val cache = MediaCacheStore(root); val old = clip(0xFFFF_FFFFL)
            index.rememberCameraListing("SIMULATED", listOf(old)); index.setFavorite("SIMULATED", old, true)
            val codec = NikonMediaLibraryCodec("SIMULATED", null, cache, { index.favoriteIDs("SIMULATED") }, { false })
            val owner = MonitorMediaLibraryModel(MonitorMediaCache(MonitorMediaCacheDirectory(root.toFile()), codec,
                eligibility = MonitorMediaOriginalEligibility.ExactSize, catalogAddress = "SIMULATED/index.json",
                preservedMetadata = emptyList(), catalogStore = index.catalogByteStore("SIMULATED")),
                NikonLibraryFavorites(index, listOf("SIMULATED")), scope = this,
                cacheScanning = MonitorMediaCacheScanning.IMMEDIATE, initialCatalog = MediaCatalog(),
                initialRecords = listOf(codec.record(NikonLibraryClip("SIMULATED", old))))
            val actions = NikonMediaLibraryActions(index, cache, { owner }, { codec })
            var projected: Set<String>? = null
            val callback = actions.captureRatingCompletion(NikonLibraryClip("SIMULATED", old)) { projected = it }
            index.rememberResolvedObjectSize("SIMULATED", old, 4_500_000_000L)
            assertTrue(callback.isCurrent); assertTrue(callback.mirror(0))
            assertEquals(emptySet(), projected); assertTrue(index.favoriteIDs("SIMULATED").isEmpty())
            assertEquals(4_500_000_000L, index.persistedClips("SIMULATED").single().sizeBytes)
            assertEquals(4_500_000_000L, owner.state.value.records.single().payload.clip.sizeBytes)
            assertFalse(owner.state.value.records.single().favorite)
            owner.dispose()
        } finally { root.toFile().deleteRecursively() }
    }

    @Test fun `actual canonical delete preference reentry cannot erase successor favorite or bytes`() = runTest {
        val root = createTempDirectory("nikon-action-draft")
        try {
            val preferences = Preferences(); val index = MediaLibraryIndex(preferences); val cache = MediaCacheStore(root)
            val old = clip(100); index.rememberCameraListing("SIMULATED", listOf(old)); index.setFavorite("SIMULATED", old, true)
            val codec = NikonMediaLibraryCodec("SIMULATED", null, cache, { index.favoriteIDs("SIMULATED") }, { false })
            val owner = MonitorMediaLibraryModel(MonitorMediaCache(MonitorMediaCacheDirectory(root.toFile()), codec,
                eligibility = MonitorMediaOriginalEligibility.ExactSize, catalogAddress = "SIMULATED/index.json",
                preservedMetadata = emptyList(), catalogStore = index.catalogByteStore("SIMULATED")),
                NikonLibraryFavorites(index, listOf("SIMULATED")), scope = this,
                cacheScanning = MonitorMediaCacheScanning.IMMEDIATE, initialCatalog = MediaCatalog(),
                initialRecords = listOf(codec.record(NikonLibraryClip("SIMULATED", old))))
            val actions = NikonMediaLibraryActions(index, cache, { owner }, { codec })
            val value = NikonLibraryClip("SIMULATED", old)
            val capture = owner.close().let { actions.capture(listOf(value)) }
            val successor = old.copy(sizeBytes = 200)
            val path = root.resolve(cache.libraryRelativeAddress("SIMULATED", MediaCacheObjectIdentity(successor)))
            val content = ByteArray(200) { 8 }; var reentered = false
            preferences.onWrite = { key ->
                if (key.startsWith("index.")) {
                    preferences.onWrite = null; reentered = true
                    index.clearCameraCatalogs(); index.rememberCameraListing("SIMULATED", listOf(successor))
                    index.setFavorite("SIMULATED", successor, true)
                    Files.createDirectories(path.parent); Files.write(path, content)
                    owner.applyLocalRecords(MonitorMediaCatalogCapture(resetLibrary = true,
                        upserts = listOf(codec.record(NikonLibraryClip("SIMULATED", successor))),
                        sourceFavoriteKeys = setOf(successor.libraryKey("SIMULATED"))), owner.actionToken)
                }
            }
            val count = capture.deleteBatch(listOf(value), { true }, { _, _ -> fail("Retired progress published") })
            assertTrue(reentered); assertEquals(1, count); assertFalse(capture.isCurrent)
            assertEquals(listOf(successor), index.persistedClips("SIMULATED"))
            assertEquals(setOf(successor.libraryKey("SIMULATED")), index.favoriteIDs("SIMULATED"))
            assertContentEquals(content, Files.readAllBytes(path))
            assertEquals(200L, owner.state.value.records.single().payload.clip.sizeBytes)
            assertTrue(owner.state.value.records.single().favorite)
            owner.dispose()
        } finally { root.toFile().deleteRecursively() }
    }

    @Test fun `actual captured rating accepts matching row first persisted during native operation`() = runTest {
        val root = createTempDirectory("nikon-action-draft")
        try {
            val index = MediaLibraryIndex(Preferences()); val cache = MediaCacheStore(root); val observed = clip(100)
            val codec = NikonMediaLibraryCodec("SIMULATED", null, cache, { index.favoriteIDs("SIMULATED") }, { false })
            val owner = MonitorMediaLibraryModel(MonitorMediaCache(MonitorMediaCacheDirectory(root.toFile()), codec,
                eligibility = MonitorMediaOriginalEligibility.ExactSize, catalogAddress = "SIMULATED/index.json",
                preservedMetadata = emptyList(), catalogStore = index.catalogByteStore("SIMULATED")),
                NikonLibraryFavorites(index, listOf("SIMULATED")), scope = this,
                cacheScanning = MonitorMediaCacheScanning.IMMEDIATE, initialCatalog = MediaCatalog(),
                initialRecords = listOf(codec.record(NikonLibraryClip("SIMULATED", observed))))
            assertTrue(index.persistedClips("SIMULATED").isEmpty())
            val actions = NikonMediaLibraryActions(index, cache, { owner }, { codec })
            var projected: Set<String>? = null
            val callback = actions.captureRatingCompletion(NikonLibraryClip("SIMULATED", observed)) { projected = it }
            val entered = kotlinx.coroutines.CompletableDeferred<Unit>(); val release = kotlinx.coroutines.CompletableDeferred<Unit>()
            val pending = async { entered.complete(Unit); release.await(); callback.mirror(4) }
            entered.await(); index.rememberCameraListing("SIMULATED", listOf(observed))
            release.complete(Unit); assertTrue(pending.await())
            val favorite = setOf(observed.libraryKey("SIMULATED"))
            assertEquals(favorite, projected); assertEquals(favorite, index.favoriteIDs("SIMULATED"))
            assertEquals(listOf(observed), index.persistedClips("SIMULATED"))
            assertEquals(observed, owner.state.value.records.single().payload.clip)
            assertTrue(owner.state.value.records.single().favorite)
            assertTrue(owner.state.value.catalog.assets.isEmpty())
            owner.dispose()
        } finally { root.toFile().deleteRecursively() }
    }

    @Test fun `actual gated rating admits zero and sentinel strengthening but rejects known size conflict`() = runTest {
        for ((oldSize, newSize, admitted) in listOf(Triple(0L, 4L, true), Triple(0xFFFF_FFFFL, 4L, true), Triple(4L, 8L, false))) {
            val root = createTempDirectory("nikon-rating-identity-draft")
            try {
                val preferences = Preferences(); val index = MediaLibraryIndex(preferences); val cache = MediaCacheStore(root)
                val old = clip(oldSize); index.rememberCameraListing("SIMULATED", listOf(old)); index.setFavorite("SIMULATED", old, true)
                val codec = NikonMediaLibraryCodec("SIMULATED", null, cache, { index.favoriteIDs("SIMULATED") }, { false })
                val owner = MonitorMediaLibraryModel(MonitorMediaCache(MonitorMediaCacheDirectory(root.toFile()), codec,
                    eligibility = MonitorMediaOriginalEligibility.ExactSize, catalogAddress = "SIMULATED/index.json",
                    preservedMetadata = emptyList(), catalogStore = index.catalogByteStore("SIMULATED")),
                    NikonLibraryFavorites(index, listOf("SIMULATED")), scope = this,
                    cacheScanning = MonitorMediaCacheScanning.IMMEDIATE, initialCatalog = MediaCatalog(),
                    initialRecords = listOf(codec.record(NikonLibraryClip("SIMULATED", old))))
                val actions = NikonMediaLibraryActions(index, cache, { owner }, { codec })
                var projected: Set<String>? = null
                val completion = actions.captureRatingCompletion(NikonLibraryClip("SIMULATED", old)) { projected = it }
                val entered = kotlinx.coroutines.CompletableDeferred<Unit>(); val release = kotlinx.coroutines.CompletableDeferred<Unit>()
                val pending = async { entered.complete(Unit); release.await(); completion.mirror(0) }
                entered.await()
                val successor = old.copy(sizeBytes = newSize)
                index.rememberCameraListing("SIMULATED", listOf(successor))
                owner.applyLocalRecords(MonitorMediaCatalogCapture(resetLibrary = true,
                    upserts = listOf(codec.record(NikonLibraryClip("SIMULATED", successor))),
                    sourceFavoriteKeys = index.favoriteIDs("SIMULATED")), owner.actionToken)
                val canonical = assertNotNull(index.catalogByteStore("SIMULATED").read()); val writes = preferences.writes
                assertEquals(admitted, completion.isCurrent)
                release.complete(Unit); assertEquals(admitted, pending.await())
                assertEquals(newSize, index.persistedClips("SIMULATED").single().sizeBytes)
                assertEquals(newSize, owner.state.value.records.single().payload.clip.sizeBytes)
                if (admitted) {
                    assertEquals(emptySet(), projected); assertTrue(index.favoriteIDs("SIMULATED").isEmpty())
                    assertFalse(owner.state.value.records.single().favorite)
                } else {
                    assertNull(projected); assertEquals(writes, preferences.writes)
                    assertContentEquals(canonical, index.catalogByteStore("SIMULATED").read())
                    assertEquals(setOf(successor.libraryKey("SIMULATED")), index.favoriteIDs("SIMULATED"))
                    assertTrue(owner.state.value.records.single().favorite)
                }
                assertTrue(owner.state.value.catalog.assets.isEmpty()); owner.dispose()
            } finally { root.toFile().deleteRecursively() }
        }
    }

    @Test fun `actual gated delete admits zero and sentinel strengthening but preserves known replacement bytes`() = runTest {
        for ((oldSize, newSize, admitted) in listOf(Triple(0L, 4L, true), Triple(0xFFFF_FFFFL, 4L, true), Triple(4L, 8L, false))) {
            val root = createTempDirectory("nikon-delete-identity-draft")
            try {
                val preferences = Preferences(); val index = MediaLibraryIndex(preferences); val cache = MediaCacheStore(root)
                val old = clip(oldSize); index.rememberCameraListing("SIMULATED", listOf(old)); index.setFavorite("SIMULATED", old, true)
                val codec = NikonMediaLibraryCodec("SIMULATED", null, cache, { index.favoriteIDs("SIMULATED") }, { false })
                val owner = MonitorMediaLibraryModel(MonitorMediaCache(MonitorMediaCacheDirectory(root.toFile()), codec,
                    eligibility = MonitorMediaOriginalEligibility.ExactSize, catalogAddress = "SIMULATED/index.json",
                    preservedMetadata = emptyList(), catalogStore = index.catalogByteStore("SIMULATED")),
                    NikonLibraryFavorites(index, listOf("SIMULATED")), scope = this,
                    cacheScanning = MonitorMediaCacheScanning.IMMEDIATE, initialCatalog = MediaCatalog(),
                    initialRecords = listOf(codec.record(NikonLibraryClip("SIMULATED", old))))
                val actions = NikonMediaLibraryActions(index, cache, { owner }, { codec }); val value = NikonLibraryClip("SIMULATED", old)
                val capture = owner.close().let { actions.capture(listOf(value)) }
                val entered = kotlinx.coroutines.CompletableDeferred<Unit>(); val release = kotlinx.coroutines.CompletableDeferred<Unit>()
                var progress: Pair<Int, Int>? = null; var nativeCalls = 0
                val pending = async { capture.deleteBatch(listOf(value), {
                    nativeCalls += 1; entered.complete(Unit); release.await(); true
                }, { done, total -> progress = done to total }) }
                entered.await()
                val successor = old.copy(sizeBytes = newSize)
                index.rememberCameraListing("SIMULATED", listOf(successor))
                owner.applyLocalRecords(MonitorMediaCatalogCapture(resetLibrary = true,
                    upserts = listOf(codec.record(NikonLibraryClip("SIMULATED", successor))),
                    sourceFavoriteKeys = index.favoriteIDs("SIMULATED")), owner.actionToken)
                val path = root.resolve(cache.libraryRelativeAddress("SIMULATED", MediaCacheObjectIdentity(successor)))
                Files.createDirectories(path.parent); val content = ByteArray(newSize.toInt()) { 9 }; Files.write(path, content)
                val canonical = assertNotNull(index.catalogByteStore("SIMULATED").read()); val writes = preferences.writes
                progress = 7 to 8
                assertEquals(admitted, capture.isCurrent)
                release.complete(Unit); assertEquals(if (admitted) 1 else 0, pending.await())
                assertEquals(1, nativeCalls)
                if (admitted) {
                    assertFalse(Files.exists(path)); assertTrue(index.persistedClips("SIMULATED").isEmpty())
                    assertTrue(index.favoriteIDs("SIMULATED").isEmpty()); assertTrue(owner.state.value.records.isEmpty())
                    assertEquals(1 to 1, progress)
                } else {
                    assertContentEquals(content, Files.readAllBytes(path)); assertEquals(writes, preferences.writes)
                    assertContentEquals(canonical, index.catalogByteStore("SIMULATED").read())
                    assertEquals(listOf(successor), index.persistedClips("SIMULATED"))
                    assertEquals(setOf(successor.libraryKey("SIMULATED")), index.favoriteIDs("SIMULATED"))
                    assertEquals(newSize, owner.state.value.records.single().payload.clip.sizeBytes)
                    assertTrue(owner.state.value.records.single().favorite); assertEquals(7 to 8, progress)
                }
                assertTrue(owner.state.value.catalog.assets.isEmpty()); owner.dispose()
            } finally { root.toFile().deleteRecursively() }
        }
    }

    private fun clip(size: Long) = NikonMediaClipRecord(handle = 4, storageId = 65_537, sizeBytes = size,
        captureDate = "20261004T120000", pixelWidth = 3840, pixelHeight = 2160,
        filename = "Göteborg.MOV", contentKind = NikonMediaContentKind.PLAYABLE_PROXY, stillPhoto = null)
    private class Preferences : MediaLibraryPreferences {
        private val values = mutableMapOf<String, String>()
        var writes = 0
        var onWrite: ((String) -> Unit)? = null
        override fun getString(key: String): String? = values[key]
        override fun putString(key: String, value: String?) {
            writes += 1
            if (value == null) values.remove(key) else values[key] = value
            onWrite?.invoke(key)
        }
    }
}
