package com.opencapture.openzcine.media

import android.content.ContextWrapper
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import com.opencapture.opencine.appkit.*
import com.opencapture.opencine.cameracontrols.begin
import com.opencapture.opencine.frameio.*
import com.opencapture.opencine.media.MediaCatalog
import com.opencapture.opencine.nikon.NikonMediaClipRecord
import com.opencapture.opencine.nikon.NikonMediaContentKind
import com.opencapture.opencine.runtime.MonitorMovieExportContainer
import com.opencapture.openzcine.frameio.MediaDeliveryConfiguration
import com.opencapture.openzcine.frameio.PassthroughFrameioArtifactPreparer
import java.io.ByteArrayOutputStream
import java.io.File
import java.io.OutputStream
import java.nio.file.Files
import java.nio.file.Path
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withContext
import kotlinx.coroutines.withTimeout
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith

/** SIMULATED cache bytes, native route and Gallery ports; the actual Nikon selection and the
 * shared app-scoped run. No camera, HTTP, OAuth, Photos permissions or video-decoder
 * qualification is implied. */
@RunWith(AndroidJUnit4::class)
class NikonNativeDeliveryLeaseTest {
    @Test fun nativeShareJoinsItsExistingSetupHopBeforeChooserPublication() = runBlocking {
        withContext(Dispatchers.Main.immediate) { fixture { f ->
            val handle = f.begin(MonitorDeliveryPostExportAction.SYSTEM_SHARE, f.lease())!!
            withTimeout(10_000) { f.hop.returnEntered.await() }
            assertNull(f.state.share)
            assertTrue(f.state.running)
            f.hop.returnRelease.complete(Unit)
            withTimeout(10_000) { handle.awaitEnteredCleanup() }
            val ready = f.state.share!!.payload.urls
            assertEquals(1, ready.size); assertTrue(ready.single().isFile)
            assertEquals(1, f.hop.leaves); assertEquals(1, f.hop.joins)
            assertFalse(f.state.running)
            assertEquals(0, f.httpCalls)
        } }
    }
    @Test fun nativePhotosJoinsItsExistingSetupHopWithoutUploadOrNewLeave() = runBlocking {
        withContext(Dispatchers.Main.immediate) { fixture { f ->
            val handle = f.begin(MonitorDeliveryPostExportAction.SAVE_TO_PHOTOS, f.lease())!!
            withTimeout(10_000) { f.hop.returnEntered.await() }
            assertEquals(1, f.gallery.published)
            assertNull(f.state.toast)
            assertTrue(f.state.running)
            f.hop.returnRelease.complete(Unit)
            withTimeout(10_000) { handle.awaitEnteredCleanup() }
            assertNotNull(f.state.toast)
            assertEquals(1, f.hop.leaves); assertEquals(1, f.hop.joins)
            assertEquals(0, f.httpCalls)
        } }
    }
    @Test fun cancelledNativeRunJoinsCapturedReturnWithoutPublishing() = runBlocking {
        withContext(Dispatchers.Main.immediate) { fixture { f ->
            val handle = f.begin(MonitorDeliveryPostExportAction.SYSTEM_SHARE, f.lease())!!
            withTimeout(10_000) { f.hop.returnEntered.await() }
            handle.cancel()
            assertNull(f.state.share)
            f.hop.returnRelease.complete(Unit)
            withTimeout(10_000) { handle.awaitEnteredCleanup() }
            assertNull(f.state.share)
            assertEquals(1, f.hop.joins)
            assertNull(f.state.toast)
        } }
    }
    @Test fun lateOldNativeReturnCannotRestoreOrPublishToSuccessor() = runBlocking {
        withContext(Dispatchers.Main.immediate) { fixture { f ->
            val handle = f.begin(MonitorDeliveryPostExportAction.SYSTEM_SHARE, f.lease())!!
            withTimeout(10_000) { f.hop.returnEntered.await() }
            val successor = Hop(f.network, "SIMULATED-B")
            f.controller.attachCameraHop(successor)
            // No successor route exists while the old one is still returning, so the late return
            // can never restore or publish to one.
            assertNull(f.controller.claimInternetHop { true })
            f.hop.returnRelease.complete(Unit)
            withTimeout(10_000) { handle.awaitEnteredCleanup() }
            assertEquals(0, successor.leaves); assertEquals(0, successor.joins)
            assertEquals(1, f.hop.joins)
            assertEquals(1, f.state.share!!.payload.urls.size)
            // Once the old return has ended, a successor claims its own route.
            val next = f.controller.claimInternetHop { true }!!
            assertTrue(f.controller.ownsInternetHop(next))
            f.controller.endInternetHop(next)
        } }
    }

    private class Network : FrameioReachability {
        var value = FrameioNetworkState.CAMERA_ACCESS_POINT
        override fun state() = value
    }
    private class Hop(val network: Network, val name: String) : FrameioCameraHop {
        override val availability = FrameioHopAvailability.READY
        val returnEntered = CompletableDeferred<Unit>()
        val returnRelease = CompletableDeferred<Unit>()
        var leaves = 0; var joins = 0
        override suspend fun leaveCameraNetwork(): Boolean {
            leaves++; network.value = FrameioNetworkState.ONLINE; return true
        }
        override suspend fun rejoinCameraNetwork(): FrameioCameraRejoinEvidence {
            joins++; returnEntered.complete(Unit); returnRelease.await()
            network.value = FrameioNetworkState.CAMERA_ACCESS_POINT
            return FrameioCameraRejoinEvidence(name, "SIMULATED", 7)
        }
    }
    private class Gallery : MediaGalleryGateway {
        var published = 0
        override fun createPending(artifact: MediaGalleryArtifact) = PendingMediaGalleryItem("SIMULATED")
        override fun openPending(item: PendingMediaGalleryItem): OutputStream = ByteArrayOutputStream()
        override fun publish(item: PendingMediaGalleryItem) { published++ }
        override fun deletePending(item: PendingMediaGalleryItem) = Unit
    }
    private class Preferences : MediaLibraryPreferences {
        private val values = mutableMapOf<String, String>()
        override fun getString(key: String): String? = values[key]
        override fun putString(key: String, value: String?) {
            if (value == null) values.remove(key) else values[key] = value
        }
    }
    private class Fixture(val root: Path) {
        val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)
        val network = Network()
        val hop = Hop(network, "SIMULATED-A")
        val gallery = Gallery()
        var httpCalls = 0
        val cache = MediaCacheStore(root.resolve("media"))
        private val context = object : ContextWrapper(InstrumentationRegistry.getInstrumentation().targetContext) {
            override fun getCacheDir(): File = root.resolve("cache").toFile().apply { mkdirs() }
        }
        val controller = FrameioDeliveryController({ null }, NativeFrameioCoreBridge,
            object : FrameioHttpClient {
                override suspend fun execute(request: FrameioHttpRequest, bearerToken: String?, contentType: String?): FrameioHttpResponse {
                    httpCalls++; error("No HTTP for native delivery")
                }
                override suspend fun putUploadPart(uploadURL: String, source: Path, offset: Long, byteCount: Long,
                    contentType: String, onBytesSent: suspend (Long) -> Unit): FrameioHttpResponse {
                    httpCalls++; error("No upload for native delivery")
                }
            }, object : FrameioSecretStore {
                override fun load() = FrameioSecretState(null, null)
                override fun saveToken(token: FrameioStoredToken) = error("No account IO")
                override fun clearToken() = Unit
                override fun savePendingAuthorization(pending: FrameioPendingAuthorization) = error("No account IO")
                override fun clearPendingAuthorization() = Unit
                override fun clearAll() = Unit
            }, object : FrameioDestinationStore {
                override fun load(): FrameioDestination? = null
                override fun save(destination: FrameioDestination) = error("No account IO")
                override fun clear() = Unit
            }, network, listOf(root.resolve("cache/share/ready")), "OpenZCine", internetWaitPoll = {}, internetWaitAttempts = 2)
        val coordinator = MonitorDeliveryCoordinator(scope)
        private val delivery = NikonMediaDelivery(context, coordinator, controller, cache, gallery, PassthroughFrameioArtifactPreparer)
        private val index = MediaLibraryIndex(Preferences())
        private val codec = NikonMediaLibraryCodec("SIMULATED", null, cache, { emptySet() }, { false })
        private val record = codec.record(NikonLibraryClip("SIMULATED", NikonMediaClipRecord(1, 1, 4, "20261007T120000",
            1920, 1080, "A.MOV", NikonMediaContentKind.PLAYABLE_PROXY, null)))
        private val library = MonitorMediaLibraryModel(MonitorMediaCache(MonitorMediaCacheDirectory(cache.rootDirectory.toFile()), codec,
            eligibility = MonitorMediaOriginalEligibility.ExactSize, catalogAddress = "SIMULATED/index.json", preservedMetadata = emptyList(),
            catalogStore = index.catalogByteStore("SIMULATED")), NikonLibraryFavorites(index, listOf("SIMULATED")),
            scope = scope, cacheScanning = MonitorMediaCacheScanning.IMMEDIATE, initialCatalog = MediaCatalog(), initialRecords = listOf(record))
        val state get() = coordinator.lifetime.state.value
        init {
            cache.openEntry("SIMULATED", MediaCacheObjectIdentity(record.payload.clip), 4).apply {
                append(0, byteArrayOf(1, 2, 3, 4)); complete()
            }
            library.begin()
            controller.attachCameraHop(hop)
        }
        /** The setup hop the popup took, transferred to the accepted native request. */
        suspend fun lease(): FrameioInternetLease {
            val popup = controller.claimInternetHop { true }!!
            assertTrue(controller.waitInternetHop(popup))
            return controller.transferInternetHop(popup)!!
        }
        fun begin(action: MonitorDeliveryPostExportAction, lease: FrameioInternetLease): MonitorDeliveryRunHandle? {
            val selection = delivery.selection(listOf(record), library, MonitorMediaGalleryOpen(record, listOf(record), library.actionToken),
                null, { true }, { MonitorPlaybackAdmission { true } }, null, null,
                MediaDeliveryConfiguration(bakeLut = false, includeMetadata = false))!!
            return selection.begin(coordinator, MonitorDeliveryPreparedRequest<Unit, MonitorMovieExportContainer, FrameioProject,
                FrameioCapturedProjectListing, FrameioInternetLease>(MonitorDeliveryDestination.NATIVE_SHARE,
                selection.configuration, action, lease))
        }
        suspend fun close() { hop.returnRelease.complete(Unit); coordinator.close(); library.dispose(); scope.cancel() }
    }
    private suspend fun fixture(body: suspend (Fixture) -> Unit) {
        val root = Files.createTempDirectory("SIMULATED-native-delivery-lease")
        val f = Fixture(root)
        try { body(f) } finally { f.close(); root.toFile().deleteRecursively() }
    }
}
