@file:androidx.media3.common.util.UnstableApi

package com.opencapture.openzcine.media

import androidx.media3.common.Player
import androidx.media3.common.MediaItem
import com.opencapture.opencine.appkit.*
import com.opencapture.opencine.core.MonotonicInstant
import com.opencapture.opencine.media.*
import com.opencapture.opencine.nikon.NikonMediaClipRecord
import com.opencapture.opencine.nikon.NikonMediaContentKind
import java.lang.reflect.Proxy
import kotlin.io.path.createTempDirectory
import kotlin.test.*
import kotlin.time.Duration.Companion.milliseconds
import kotlin.time.Duration.Companion.seconds
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.withContext
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.async
import kotlinx.coroutines.test.runCurrent
import kotlinx.coroutines.test.runTest

@OptIn(ExperimentalCoroutinesApi::class)
class NikonPlaybackOwnerAdoptionTest {
    @Test fun `actual attached native buffer publishes seconds and rejects SDK and source retirement`() = runTest {
        val fixture = Fixture(this)
        try {
            for (scenario in listOf("positive", "unset", "missing", "item-replaced", "source-retired", "source-reentry", "read-reentry")) {
                var accepted = true
                var admissionReentry: (() -> Unit)? = null
                val port = NikonPlaybackNativePort(sourceCurrent = {
                    val callback = admissionReentry; admissionReentry = null; callback?.invoke()
                    accepted
                })
                val token = MonitorPlaybackItemToken(java.util.UUID.randomUUID(), 0)
                port.retireItem(token)
                port.candidates(fixture.records[0], fixture.library)
                var nativeItem: MediaItem? = MediaItem.Builder().setMediaId("SIMULATED-buffer").build()
                var milliseconds = 2_500L
                var onRead: (() -> Unit)? = null
                var reads = 0
                val player = Proxy.newProxyInstance(Player::class.java.classLoader, arrayOf(Player::class.java)) { _, method, _ ->
                    when (method.name) {
                        "getCurrentMediaItem" -> nativeItem
                        "getBufferedPosition" -> { reads += 1; onRead?.invoke(); milliseconds }
                        else -> when (method.returnType) {
                            java.lang.Boolean.TYPE -> false
                            java.lang.Integer.TYPE -> 0
                            java.lang.Long.TYPE -> 0L
                            java.lang.Float.TYPE -> 0f
                            java.lang.Double.TYPE -> 0.0
                            else -> null
                        }
                    }
                } as Player
                val attached = port.attach(player, token, {}) { _, _ -> }
                assertEquals(2.5, port.updateBuffer(attached))
                assertEquals(2.5, port.preparedSource.value?.bufferedThroughSeconds)
                when (scenario) {
                    "unset" -> milliseconds = -1
                    "missing" -> nativeItem = null
                    "item-replaced" -> onRead = { nativeItem = MediaItem.Builder().setMediaId("SIMULATED-successor").build() }
                    "source-retired" -> accepted = false
                    "source-reentry" -> admissionReentry = { port.retireItem(token.copy(revision = 1)) }
                    "read-reentry" -> onRead = { port.retireItem(token.copy(revision = 1)) }
                }
                if (scenario == "positive") assertEquals(2.5, port.updateBuffer(attached))
                else assertNull(port.updateBuffer(attached), "$scenario cannot publish a native buffer observation")
                if (scenario in setOf("unset", "missing", "item-replaced")) {
                    assertNull(port.preparedSource.value?.bufferedThroughSeconds)
                }
                port.close(token.copy(revision = 1))
                val closedReads = reads
                assertNull(port.updateBuffer(attached))
                assertEquals(closedReads, reads)
                assertNull(port.preparedSource.value)
            }
        } finally { fixture.close() }
    }

    @Test fun `actual pending native attachment cannot overwrite or dispose successor`() = runTest {
        val fixture = Fixture(this)
        try {
            val port = NikonPlaybackNativePort()
            val identity = java.util.UUID.randomUUID()
            port.retireItem(MonitorPlaybackItemToken(identity, 0))
            val old = MonitorPlaybackItemToken(identity, 1)
            port.retireItem(old)
            val first = (port.candidates(fixture.records[0], fixture.library).single() as MonitorPlaybackCandidate.Cached).item
            val outgoing = async { runCatching { port.prepare(first, old, null) } }
            runCurrent()
            assertFalse(outgoing.isCompleted)
            val next = MonitorPlaybackItemToken(identity, 2)
            port.retireItem(next)
            val second = (port.candidates(fixture.records[1], fixture.library).single() as MonitorPlaybackCandidate.Cached).item
            val pending = async { port.prepare(second, next, null) }
            val events = mutableListOf<Pair<MonitorPlaybackItemToken, MonitorPlaybackEvent>>()
            port.onEvent = { token, event -> events += token to event }
            val calls = mutableListOf<String>()
            val successor = player("next", calls)
            val attached = port.attach(successor, next, { calls += "detach:next" }) { _, _ -> }
            pending.await()
            assertTrue(outgoing.await().isFailure)
            val late = port.attach(player("late", calls), old, { calls += "detach:late" }) { _, _ -> }
            port.publish(late, MonitorPlaybackEvent.Position(99.0))
            port.detach(late)
            port.publish(attached, MonitorPlaybackEvent.Position(2.0))
            assertEquals(listOf("detach:late", "pause:late", "release:late"), calls)
            assertEquals(listOf(next to MonitorPlaybackEvent.ItemInstalled, next to MonitorPlaybackEvent.Position(2.0)), events)
            port.close(MonitorPlaybackItemToken(identity, 3))
            port.detach(attached)
            assertEquals(listOf("detach:late", "pause:late", "release:late", "detach:next", "pause:next", "release:next"), calls)
        } finally { fixture.close() }
    }

    @Test fun `actual borrowed gallery retirement releases exact attached player once`() = runTest {
        val fixture = Fixture(this)
        try {
            val calls = mutableListOf<String>()
            val native = NikonPlaybackNativePort()
            val owner = nikonPlaybackModel(fixture.library, native, this).also { it.load(fixture.records[0], fixture.records) }
            runCurrent()
            val token = owner.state.value.token
            val attached = native.attach(player("native", calls), token, { calls += "detach:native" }) { _, _ -> }
            runCurrent()
            assertTrue(owner.state.value.ready)
            calls.clear()
            fixture.library.close()
            runCurrent()
            assertTrue(owner.state.value.closed)
            native.detach(attached)
            assertEquals(listOf("detach:native", "pause:native", "release:native"), calls)
        } finally { fixture.close() }
    }

    @Test fun `actual native seek primitive keeps 75 ms preview and exact final commit`() = runTest {
        val fixture = Fixture(this)
        try {
            var now = MonotonicInstant(100.seconds)
            val native = NikonPlaybackNativePort()
            val owner = nikonPlaybackModel(fixture.library, native, this, now = { now }).also { it.load(fixture.records[0], fixture.records) }
            runCurrent()
            val token = owner.state.value.token
            val seeks = mutableListOf<Pair<Long, Boolean>>()
            val attached = native.attach(player("seek", mutableListOf()), token, {}) { time, preview -> seeks += time to preview }
            runCurrent()
            native.publish(attached, MonitorPlaybackEvent.Metadata(MonitorPlaybackMetadata(duration = 10.0)))
            val edit = assertNotNull(owner.beginScrub())
            owner.updateScrub(1.0, edit)
            runCurrent()
            now = MonotonicInstant(100.seconds + 74.milliseconds)
            owner.updateScrub(2.0, edit)
            runCurrent()
            assertEquals(listOf(1_000L to true), seeks)
            now = MonotonicInstant(100.seconds + 75.milliseconds)
            owner.updateScrub(3.0, edit)
            runCurrent()
            owner.commitScrub(edit)
            runCurrent()
            assertEquals(listOf(1_000L to true, 3_000L to true, 3_000L to false), seeks)
            assertEquals(3.0, owner.state.value.position)
            assertFalse(owner.state.value.scrubbing)
            owner.close()
        } finally { fixture.close() }
    }

    @Test fun `current filtered record navigation preserves actual address and source payload`() = runTest {
        val fixture = Fixture(this)
        try {
            val native = NikonPlaybackNativePort()
            val owner = nikonPlaybackModel(fixture.library, native, this).also { it.load(fixture.records[0], fixture.records) }
            runCurrent()
            // The donor accepts the already-captured target even if the parent filter changes
            // while transfer close suspends. Navigation bounds use the latest parent values.
            owner.load(fixture.records[1], listOf(fixture.records[0]))
            runCurrent()
            assertEquals(fixture.records[1].asset.id, owner.state.value.active?.asset?.id)
            assertEquals(listOf(fixture.records[0]), owner.state.value.playlist)
            assertFalse(owner.canGoPrevious)
            assertFalse(owner.canGoNext)
            owner.load(fixture.records[1], listOf(fixture.records[1]))
            runCurrent()
            assertEquals(listOf(fixture.records[1]), owner.state.value.playlist)
            assertEquals(fixture.records[1].payload, owner.state.value.active?.payload)
            val address = fixture.records[1].address.representations.values.single()
            assertEquals(fixture.library.cache.directory.file(address).toURI(), owner.state.value.item?.url)
            assertFalse(owner.canGoPrevious)
            assertFalse(owner.canGoNext)
            owner.close()
        } finally { fixture.close() }
    }

    @Test fun `complete player refuses unsupported masters before native preparation`() = runTest {
        val f = Fixture(backgroundScope)
        try {
            val unsupported = f.records[0].copy(facts = f.records[0].facts.copy(playbackEligible = false))
            f.library.applyLocalRecords(MonitorMediaCatalogCapture(resetLibrary = false, upserts = emptyList(), amendments = listOf(unsupported)), f.library.actionToken)
            val opening = MonitorMediaGalleryOpen(unsupported, f.records, f.library.actionToken)
            val calls = mutableListOf<String>()
            val context = NikonOperatorPlaybackContext(f.library, opening, backgroundScope, { true },
                { MonitorPlaybackAdmission { true } }, { record, _ ->
                    MediaTransferCoordinator({ calls += record.payload.clip.filename; MediaTransferPreparation.Ready(f.entry(record)) }, {})
                }, cleanupScope = backgroundScope)
            assertFalse(context.media.open(opening.record, opening.playlist, opening.admission))
            runCurrent(); assertNull(context.native); assertTrue(calls.isEmpty())
            assertEquals(f.records[0].asset, f.library.record(unsupported.asset.id)?.asset)
        } finally { f.close() }
    }

    @Test fun `complete player canonical retirement before first IO acquires no native transfer`() = runTest {
        val f = Fixture(backgroundScope)
        try {
            val opening = MonitorMediaGalleryOpen(f.records[0], f.records, f.library.actionToken)
            var preparations = 0
            val context = NikonOperatorPlaybackContext(f.library, opening, backgroundScope, { true },
                { MonitorPlaybackAdmission { true } }, { record, _ ->
                    MediaTransferCoordinator({ preparations++; MediaTransferPreparation.Ready(f.entry(record)) }, {})
                }, cleanupScope = backgroundScope)
            assertTrue(context.media.open(opening.record, opening.playlist, opening.admission))
            f.library.cache.directory.retireWrites(); runCurrent()
            assertEquals(0, preparations)
            assertTrue(context.media.state.value.playback?.state?.value?.closed == true)
            context.media.closePlayback()
        } finally { f.close() }
    }

    @Test fun `adjacent source waits for exact entered native preparation and stop`() = runTest {
        val f = Fixture(backgroundScope)
        val releasePrepare = CompletableDeferred<Unit>(); val releaseStop = CompletableDeferred<Unit>()
        try {
            val events = mutableListOf<String>()
            val opening = MonitorMediaGalleryOpen(f.records[0], f.records, f.library.actionToken)
            val context = NikonOperatorPlaybackContext(f.library, opening, backgroundScope, { true },
                { MonitorPlaybackAdmission { true } }, { record, _ ->
                    MediaTransferCoordinator({
                        events += "prepare:" + record.payload.clip.filename
                        if (record.asset.id == f.records[0].asset.id) withContext(NonCancellable) { releasePrepare.await() }
                        MediaTransferPreparation.Ready(f.entry(record))
                    }, {
                        events += "stop:" + record.payload.clip.filename
                        if (record.asset.id == f.records[0].asset.id) withContext(NonCancellable) { releaseStop.await() }
                        events += "stopped:" + record.payload.clip.filename
                    })
                }, cleanupScope = backgroundScope)
            context.media.playerVisible(true)
            assertTrue(context.media.open(opening.record, opening.playlist, opening.admission)); runCurrent()
            val owner = assertNotNull(context.media.state.value.playback)
            assertEquals(listOf("prepare:A.MOV"), events)
            assertTrue(context.media.adjacent(1, owner.state.value.token)); runCurrent()
            assertEquals(listOf("prepare:A.MOV"), events)
            releasePrepare.complete(Unit); runCurrent()
            assertEquals(listOf("prepare:A.MOV", "stop:A.MOV"), events)
            releaseStop.complete(Unit); runCurrent()
            assertEquals(listOf("prepare:A.MOV", "stop:A.MOV", "stopped:A.MOV", "prepare:B.MOV"), events)
            assertEquals(f.records[1].asset.id, owner.state.value.active?.asset?.id)
            context.media.closePlayback(); runCurrent()
        } finally { releasePrepare.complete(Unit); releaseStop.complete(Unit); f.close() }
    }

    @Test fun `Back joins entered cleanup without starting a successor transfer`() = runTest {
        val f = Fixture(backgroundScope); val release = CompletableDeferred<Unit>()
        try {
            val events = mutableListOf<String>()
            val opening = MonitorMediaGalleryOpen(f.records[0], f.records, f.library.actionToken)
            val context = NikonOperatorPlaybackContext(f.library, opening, backgroundScope, { true },
                { MonitorPlaybackAdmission { true } }, { record, _ ->
                    MediaTransferCoordinator({ events += "entered"; withContext(NonCancellable) { release.await() }
                        MediaTransferPreparation.Ready(f.entry(record)) }, { events += "stopped" })
                }, cleanupScope = backgroundScope)
            assertTrue(context.media.open(opening.record, opening.playlist, opening.admission)); runCurrent()
            val native = assertNotNull(context.native)
            context.media.closePlayback()
            val joined = async { native.finishEnteredTransfer() }; runCurrent()
            assertFalse(joined.isCompleted); assertEquals(listOf("entered"), events)
            release.complete(Unit); runCurrent(); joined.await()
            assertEquals(listOf("entered", "stopped"), events)
            assertNull(context.media.state.value.playback)
        } finally { release.complete(Unit); f.close() }
    }

    @Test fun `each item boundary captures its outgoing delivery cleanup instead of borrowing a later run`() = runTest {
        val f = Fixture(backgroundScope); val release = CompletableDeferred<Unit>()
        try {
            val events = mutableListOf<String>()
            var cleanup: suspend () -> Unit = {}
            val opening = MonitorMediaGalleryOpen(f.records[0], f.records, f.library.actionToken)
            val context = NikonOperatorPlaybackContext(f.library, opening, backgroundScope, { true },
                { MonitorPlaybackAdmission { true } }, { record, _ ->
                    MediaTransferCoordinator({ events += "prepare:" + record.payload.clip.filename
                        MediaTransferPreparation.Ready(f.entry(record)) }, {})
                }, captureDeliveryCleanup = { cleanup }, cleanupScope = backgroundScope)
            assertTrue(context.media.open(opening.record, opening.playlist, opening.admission)); runCurrent()
            val native = assertNotNull(context.native); val owner = assertNotNull(context.media.state.value.playback)
            native.attach(player("A", mutableListOf()), owner.state.value.token, {}) { _, _ -> }; runCurrent()
            cleanup = { events += "cleanup:outgoing"; withContext(NonCancellable) { release.await() } }
            assertTrue(context.media.adjacent(1, owner.state.value.token))
            cleanup = { events += "cleanup:successor" }
            runCurrent()
            assertEquals(listOf("prepare:A.MOV", "cleanup:outgoing"), events)
            release.complete(Unit); runCurrent()
            assertEquals(listOf("prepare:A.MOV", "cleanup:outgoing", "prepare:B.MOV"), events)
            context.media.closePlayback(); runCurrent()
        } finally { release.complete(Unit); f.close() }
    }

    @Test fun `SDK release reentry cannot overwrite successor pending attachment`() = runTest {
        val f = Fixture(backgroundScope)
        try {
            val port = NikonPlaybackNativePort(); val id = java.util.UUID.randomUUID()
            port.retireItem(MonitorPlaybackItemToken(id, 0))
            val a = MonitorPlaybackItemToken(id, 1); val outgoing = MonitorPlaybackItemToken(id, 2); val b = MonitorPlaybackItemToken(id, 3)
            port.retireItem(a)
            val first = (port.candidates(f.records[0], f.library).single() as MonitorPlaybackCandidate.Cached).item
            val preparing = async { port.prepare(first, a, null) }; runCurrent()
            val calls = mutableListOf<String>(); var next: NikonPlaybackNativePort.Attachment? = null
            port.attach(player("A", calls), a, {
                port.retireItem(b); port.candidates(f.records[1], f.library)
                next = port.attach(player("B", calls), b, {}) { _, _ -> }
            }) { _, _ -> }; preparing.await()
            port.retireItem(outgoing)
            val second = assertNotNull(port.preparedSource.value)
            assertEquals(b, second.token)
            val item = (port.candidates(f.records[1], f.library).single() as MonitorPlaybackCandidate.Cached).item
            port.prepare(item, b, null)
            assertTrue(port.isCurrent(next)); port.play(1.0, b)
            assertEquals(listOf("pause:A", "release:A", "play:B"), calls)
            port.close(MonitorPlaybackItemToken(id, 4))
        } finally { f.close() }
    }

    @Test fun `source predicate replacement cannot send old native play to a successor`() = runTest {
        val f = Fixture(backgroundScope)
        try {
            val id = java.util.UUID.randomUUID(); val a = MonitorPlaybackItemToken(id, 1); val b = MonitorPlaybackItemToken(id, 2)
            var replace = false; lateinit var port: NikonPlaybackNativePort
            val calls = mutableListOf<String>(); var next: NikonPlaybackNativePort.Attachment? = null
            port = NikonPlaybackNativePort(sourceCurrent = {
                if (replace) {
                    replace = false; port.retireItem(b); port.candidates(f.records[1], f.library)
                    next = port.attach(player("B", calls), b, {}) { _, _ -> }
                }; true
            })
            port.retireItem(MonitorPlaybackItemToken(id, 0)); port.retireItem(a); port.candidates(f.records[0], f.library)
            port.attach(player("A", calls), a, {}) { _, _ -> }; calls.clear()
            replace = true; port.play(1.0, a)
            assertEquals(listOf("pause:A", "release:A"), calls)
            assertTrue(port.isCurrent(next)); assertEquals(b, port.preparedSource.value?.token)
            port.close(MonitorPlaybackItemToken(id, 3))
        } finally { f.close() }
    }

    @Test fun `complete Android player scene return follows the shared play request policy`() = runTest {
        // A4-12: the Nikon player keeps the shared scene-loss policy (Pocket, Insta and Z iOS):
        // a playing clip resumes when the app returns, an explicit pause stays paused.
        val f = Fixture(backgroundScope)
        try {
            val opening = MonitorMediaGalleryOpen(f.records[0], f.records, f.library.actionToken)
            val context = NikonOperatorPlaybackContext(f.library, opening, backgroundScope, { true },
                { MonitorPlaybackAdmission { true } }, { record, _ ->
                    MediaTransferCoordinator({ MediaTransferPreparation.Ready(f.entry(record)) }, {})
                }, cleanupScope = backgroundScope)
            context.media.playerVisible(true)
            assertTrue(context.media.open(opening.record, opening.playlist, opening.admission)); runCurrent()
            val native = assertNotNull(context.native); val owner = assertNotNull(context.media.state.value.playback)
            val calls = mutableListOf<String>()
            native.attach(player("scene", calls), owner.state.value.token, {}) { _, _ -> }; runCurrent()
            assertTrue(owner.state.value.ready)
            context.media.sceneActive(false)
            assertTrue(owner.state.value.playRequested, "Leaving the app keeps the operator's play request")
            calls.clear(); context.media.sceneActive(true); runCurrent()
            assertEquals(listOf("play:scene"), calls, "Returning resumes the clip that was playing")
            owner.setPlaying(false); context.media.sceneActive(false)
            calls.clear(); context.media.sceneActive(true); runCurrent()
            assertTrue(calls.isEmpty(), "An explicit pause stays paused across the scene")
            assertFalse(owner.state.value.playRequested)
            context.media.closePlayback(); runCurrent()
        } finally { f.close() }
    }

    private class Fixture(scope: CoroutineScope) {
        private val root = createTempDirectory("SIMULATED-nikon-playback")
        private val index = MediaLibraryIndex(Preferences())
        private val cache = MediaCacheStore(root)
        private val codec = NikonMediaLibraryCodec("SIMULATED", null, cache, { emptySet() }, { false })
        val records = listOf("A.MOV", "B.MOV").mapIndexed { at, name ->
            codec.record(NikonLibraryClip("SIMULATED", NikonMediaClipRecord(
                handle = (at + 4).toLong(), storageId = 65_537, sizeBytes = 100,
                captureDate = "20261004T120000", pixelWidth = 3840, pixelHeight = 2160,
                filename = name, contentKind = NikonMediaContentKind.PLAYABLE_PROXY, stillPhoto = null)))
        }
        val library = MonitorMediaLibraryModel(
            cache = MonitorMediaCache(MonitorMediaCacheDirectory(root.toFile()), codec,
                eligibility = MonitorMediaOriginalEligibility.ExactSize,
                catalogAddress = "SIMULATED/index.json", preservedMetadata = emptyList(),
                catalogStore = index.catalogByteStore("SIMULATED")),
            favoritesStore = NikonLibraryFavorites(index, listOf("SIMULATED")), scope = scope,
            cacheScanning = MonitorMediaCacheScanning.IMMEDIATE,
            initialCatalog = MediaCatalog(), initialRecords = records,
        )
        fun entry(record: MonitorMediaRecord<NikonLibraryClip>) = cache.openEntry(
            record.payload.bucket, MediaCacheObjectIdentity(record.payload.clip), record.payload.clip.sizeBytes)
        init { library.begin() }
        suspend fun close() { library.dispose(); root.toFile().deleteRecursively() }
    }

    private class Preferences : MediaLibraryPreferences {
        private val values = mutableMapOf<String, String>()
        override fun getString(key: String): String? = values[key]
        override fun putString(key: String, value: String?) {
            if (value == null) values.remove(key) else values[key] = value
        }
    }

    /** SDK command boundary only: no simulated CameraSession/PTP or manufactured observed fact. */
    private fun player(name: String, calls: MutableList<String>): Player = Proxy.newProxyInstance(
        Player::class.java.classLoader, arrayOf(Player::class.java),
    ) { _, method, _ ->
        if (method.name in setOf("pause", "release", "play")) calls += "${method.name}:$name"
        when (method.returnType) {
            java.lang.Boolean.TYPE -> false
            java.lang.Integer.TYPE -> 0
            java.lang.Long.TYPE -> 0L
            java.lang.Float.TYPE -> 0f
            java.lang.Double.TYPE -> 0.0
            else -> null
        }
    } as Player
}
