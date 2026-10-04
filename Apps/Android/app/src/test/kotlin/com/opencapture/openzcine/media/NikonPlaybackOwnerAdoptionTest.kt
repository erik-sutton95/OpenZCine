@file:androidx.media3.common.util.UnstableApi

package com.opencapture.openzcine.media

import androidx.media3.common.Player
import com.opencapture.opencine.appkit.*
import com.opencapture.opencine.core.MonotonicInstant
import com.opencapture.opencine.media.*
import java.lang.reflect.Proxy
import kotlin.io.path.createTempDirectory
import kotlin.test.*
import kotlin.time.Duration.Companion.milliseconds
import kotlin.time.Duration.Companion.seconds
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.async
import kotlinx.coroutines.test.runCurrent
import kotlinx.coroutines.test.runTest

@OptIn(ExperimentalCoroutinesApi::class)
class NikonPlaybackOwnerAdoptionTest {
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
            val session = NikonPlaybackSession(fixture.library, fixture.records[0], fixture.records, this)
            runCurrent()
            val token = session.owner.state.value.token
            val attached = session.native.attach(player("native", calls), token, { calls += "detach:native" }) { _, _ -> }
            runCurrent()
            assertTrue(session.owner.state.value.ready)
            calls.clear()
            fixture.library.close()
            runCurrent()
            assertTrue(session.owner.state.value.closed)
            session.native.detach(attached)
            assertEquals(listOf("detach:native", "pause:native", "release:native"), calls)
        } finally { fixture.close() }
    }

    @Test fun `actual native seek primitive keeps 75 ms preview and exact final commit`() = runTest {
        val fixture = Fixture(this)
        try {
            var now = MonotonicInstant(100.seconds)
            val session = NikonPlaybackSession(fixture.library, fixture.records[0], fixture.records, this, now = { now })
            runCurrent()
            val token = session.owner.state.value.token
            val seeks = mutableListOf<Pair<Long, Boolean>>()
            val attached = session.native.attach(player("seek", mutableListOf()), token, {}) { time, preview -> seeks += time to preview }
            runCurrent()
            session.native.publish(attached, MonitorPlaybackEvent.Metadata(MonitorPlaybackMetadata(duration = 10.0)))
            val edit = assertNotNull(session.owner.beginScrub())
            session.owner.updateScrub(1.0, edit)
            runCurrent()
            now = MonotonicInstant(100.seconds + 74.milliseconds)
            session.owner.updateScrub(2.0, edit)
            runCurrent()
            assertEquals(listOf(1_000L to true), seeks)
            now = MonotonicInstant(100.seconds + 75.milliseconds)
            session.owner.updateScrub(3.0, edit)
            runCurrent()
            session.owner.commitScrub(edit)
            runCurrent()
            assertEquals(listOf(1_000L to true, 3_000L to true, 3_000L to false), seeks)
            assertEquals(3.0, session.owner.state.value.position)
            assertFalse(session.owner.state.value.scrubbing)
            session.owner.close()
        } finally { fixture.close() }
    }

    @Test fun `actual captured delivery completion cannot resume next paused clip`() = runTest {
        val fixture = Fixture(this)
        try {
            val session = NikonPlaybackSession(fixture.library, fixture.records[0], fixture.records, this)
            runCurrent()
            val calls = mutableListOf<String>()
            session.native.attach(player("first", calls), session.owner.state.value.token, {}) { _, _ -> }
            runCurrent()
            val delivery = assertNotNull(session.pauseForDelivery(true))
            session.navigate(fixture.records[1], fixture.records)
            runCurrent()
            session.native.attach(player("next", calls), session.owner.state.value.token, {}) { _, _ -> }
            runCurrent()
            session.owner.setPlaying(false)
            val before = calls.toList()
            session.resumeAfterDelivery(delivery)
            assertEquals(before, calls)
            assertFalse(session.owner.state.value.playRequested)
            assertEquals(fixture.records[1].asset.id, session.owner.state.value.active?.asset?.id)
            session.owner.close()
        } finally { fixture.close() }
    }

    @Test fun `current filtered record navigation preserves actual address and source payload`() = runTest {
        val fixture = Fixture(this)
        try {
            val session = NikonPlaybackSession(fixture.library, fixture.records[0], fixture.records, this)
            runCurrent()
            // The donor accepts the already-captured target even if the parent filter changes
            // while transfer close suspends. Navigation bounds use the latest parent values.
            session.navigate(fixture.records[1], listOf(fixture.records[0]))
            runCurrent()
            assertEquals(fixture.records[1].asset.id, session.owner.state.value.active?.asset?.id)
            assertEquals(listOf(fixture.records[0]), session.owner.state.value.playlist)
            assertFalse(session.owner.canGoPrevious)
            assertFalse(session.owner.canGoNext)
            session.navigate(fixture.records[1], listOf(fixture.records[1]))
            runCurrent()
            assertEquals(listOf(fixture.records[1]), session.owner.state.value.playlist)
            assertEquals(fixture.records[1].payload, session.owner.state.value.active?.payload)
            val address = fixture.records[1].address.representations.values.single()
            assertEquals(fixture.library.cache.directory.file(address).toURI(), session.owner.state.value.item?.url)
            assertFalse(session.owner.canGoPrevious)
            assertFalse(session.owner.canGoNext)
            session.owner.close()
        } finally { fixture.close() }
    }

    @Test fun `actual Android lifecycle return preserves donor pause without auto resume`() = runTest {
        val fixture = Fixture(this)
        try {
            val session = NikonPlaybackSession(fixture.library, fixture.records[0], fixture.records, this)
            runCurrent()
            val calls = mutableListOf<String>()
            val item = session.owner.state.value.token
            session.native.attach(player("scene", calls), item, {}) { _, _ -> }
            runCurrent()
            assertTrue(session.owner.state.value.playRequested)
            session.scenePaused(item)
            val paused = calls.toList()
            assertFalse(session.owner.state.value.playRequested)
            session.sceneResumed(item)
            assertEquals(paused, calls)
            assertFalse(session.owner.state.value.playRequested)
            session.owner.close()
        } finally { fixture.close() }
    }

    private class Fixture(scope: CoroutineScope) {
        private val root = createTempDirectory("SIMULATED-nikon-playback")
        private val index = MediaLibraryIndex(Preferences())
        private val cache = MediaCacheStore(root)
        private val codec = NikonMediaLibraryCodec("SIMULATED", null, cache, { emptySet() }, { false })
        val records = listOf("A.MOV", "B.MOV").mapIndexed { at, name ->
            codec.record(NikonLibraryClip("SIMULATED", MediaClipRecord(
                handle = (at + 4).toLong(), storageId = 65_537, sizeBytes = 100,
                captureDate = "20261004T120000", pixelWidth = 3840, pixelHeight = 2160,
                filename = name, contentKind = MediaContentKind.PLAYABLE_PROXY, stillPhoto = null)))
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
