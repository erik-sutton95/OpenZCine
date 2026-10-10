package com.opencapture.openzcine.media

import android.content.ContextWrapper
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import com.opencapture.opencine.appkit.MonitorDeliveryAdmission
import com.opencapture.opencine.nikon.NikonMediaClipRecord
import com.opencapture.opencine.nikon.NikonMediaContentKind
import com.opencapture.openzcine.frameio.*
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

/** SIMULATED cache bytes, native route and Gallery ports; actual app Coordinator/shared run.
 * No camera, HTTP, OAuth, Photos permissions or video-decoder qualification is implied. */
@RunWith(AndroidJUnit4::class)
class NikonNativeDeliveryLeaseTest {
    @Test fun nativeShareJoinsItsExistingSetupHopBeforeChooserPublication() = runBlocking {
        withContext(Dispatchers.Main.immediate) { fixture { f ->
            val lease = f.lease()
            var shares = 0
            val handle = f.coordinator.beginNativeShareCaptured(listOf(f.selection), f.config, null,
                MonitorDeliveryAdmission { f.controller.ownsInternetHop(lease) }, route = lease,
                completion = MonitorDeliveryAdmission { f.controller.endedInternetHop(lease) }) { ready, _ ->
                assertEquals(1, ready.size); assertTrue(Files.isRegularFile(ready.single().file)); shares++
            }!!
            withTimeout(10_000) { f.hop.returnEntered.await() }
            assertEquals(0, shares)
            assertTrue(f.coordinator.nativeState.value.running)
            f.hop.returnRelease.complete(Unit)
            withTimeout(10_000) { handle.awaitEnteredCleanup() }
            assertEquals(1, shares)
            assertEquals(1, f.hop.leaves); assertEquals(1, f.hop.joins)
            assertFalse(f.coordinator.nativeState.value.running)
            assertEquals(0, f.httpCalls)
        } }
    }
    @Test fun nativePhotosJoinsItsExistingSetupHopWithoutUploadOrNewLeave() = runBlocking {
        withContext(Dispatchers.Main.immediate) { fixture { f ->
            val lease = f.lease()
            val handle = f.coordinator.beginSaveToPhotosCaptured(listOf(f.selection), f.config, null,
                MonitorDeliveryAdmission { f.controller.ownsInternetHop(lease) }, route = lease,
                completion = MonitorDeliveryAdmission { f.controller.endedInternetHop(lease) })!!
            withTimeout(10_000) { f.hop.returnEntered.await() }
            assertEquals(1, f.gallery.published)
            assertNull(f.coordinator.completionToast)
            assertTrue(f.coordinator.nativeState.value.running)
            f.hop.returnRelease.complete(Unit)
            withTimeout(10_000) { handle.awaitEnteredCleanup() }
            assertNotNull(f.coordinator.completionToast)
            assertEquals(1, f.hop.leaves); assertEquals(1, f.hop.joins)
            assertEquals(0, f.httpCalls)
        } }
    }
    @Test fun cancelledNativeRunJoinsCapturedReturnWithoutPublishing() = runBlocking {
        withContext(Dispatchers.Main.immediate) { fixture { f ->
            val lease = f.lease()
            var shares = 0
            val handle = f.coordinator.beginNativeShareCaptured(listOf(f.selection), f.config, null,
                MonitorDeliveryAdmission { f.controller.ownsInternetHop(lease) }, route = lease,
                completion = MonitorDeliveryAdmission { f.controller.endedInternetHop(lease) }) { _, _ -> shares++ }!!
            withTimeout(10_000) { f.hop.returnEntered.await() }
            handle.cancel()
            assertEquals(0, shares)
            f.hop.returnRelease.complete(Unit)
            withTimeout(10_000) { handle.awaitEnteredCleanup() }
            assertEquals(0, shares)
            assertEquals(1, f.hop.joins)
            assertNull(f.coordinator.completionToast)
        } }
    }
    @Test fun lateOldNativeReturnCannotRestoreOrPublishToSuccessor() = runBlocking {
        withContext(Dispatchers.Main.immediate) { fixture { f ->
            val lease = f.lease()
            var shares = 0
            val handle = f.coordinator.beginNativeShareCaptured(listOf(f.selection), f.config, null,
                MonitorDeliveryAdmission { f.controller.ownsInternetHop(lease) }, route = lease,
                completion = MonitorDeliveryAdmission { f.controller.endedInternetHop(lease) }) { _, _ -> shares++ }!!
            withTimeout(10_000) { f.hop.returnEntered.await() }
            val successor = Hop(f.network, "SIMULATED-B")
            f.controller.attachCameraHop(successor)
            val next = f.controller.claimInternetHop { true }!!
            f.hop.returnRelease.complete(Unit)
            withTimeout(10_000) { handle.awaitEnteredCleanup() }
            assertEquals(0, shares)
            assertTrue(f.controller.ownsInternetHop(next))
            assertEquals(0, successor.leaves); assertEquals(0, successor.joins)
            assertEquals(1, f.hop.joins)
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
    private class Fixture(val root: Path) {
        val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)
        val network = Network()
        val hop = Hop(network, "SIMULATED-A")
        val gallery = Gallery()
        var httpCalls = 0
        val config = MediaDeliveryConfiguration(bakeLut = false, includeMetadata = false)
        val selection = MediaDeliverySelection("SIMULATED", NikonMediaClipRecord(1, 1, 4,
            "20261007T120000", 1920, 1080, "A.MOV", NikonMediaContentKind.PLAYABLE_PROXY, null))
        val cache = MediaCacheStore(root.resolve("media"))
        private val context = object : ContextWrapper(InstrumentationRegistry.getInstrumentation().targetContext) {
            override fun getCacheDir(): File = root.resolve("cache").toFile().apply { mkdirs() }
        }
        val controller = FrameioDeliveryController({ null }, SwiftFrameioCoreBridge,
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
            }, network, root.resolve("share"), internetWaitPoll = {}, internetWaitAttempts = 2)
        val coordinator = MediaDeliveryCoordinator(context, controller, cache, gallery, scope)
        init {
            cache.openEntry(selection.cameraID, MediaCacheObjectIdentity(selection.clip), 4).apply {
                append(0, byteArrayOf(1, 2, 3, 4)); complete()
            }
            controller.attachCameraHop(hop)
        }
        suspend fun lease(): FrameioInternetLease {
            val popup = controller.claimInternetHop { true }!!
            assertTrue(controller.waitInternetHop(popup))
            return controller.transferInternetHop(popup)!!
        }
        fun close() { hop.returnRelease.complete(Unit); coordinator.close(); scope.cancel() }
    }
    private suspend fun fixture(body: suspend (Fixture) -> Unit) {
        val root = Files.createTempDirectory("SIMULATED-native-delivery-lease")
        val f = Fixture(root)
        try { body(f) } finally { f.close(); root.toFile().deleteRecursively() }
    }
}
