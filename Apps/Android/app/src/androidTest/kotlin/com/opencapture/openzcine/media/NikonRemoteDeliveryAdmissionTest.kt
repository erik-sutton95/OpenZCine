package com.opencapture.openzcine.media

import android.content.ContextWrapper
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import com.opencapture.opencine.appkit.*
import com.opencapture.opencine.media.MediaCatalog
import com.opencapture.opencine.nikon.NikonMediaClipRecord
import com.opencapture.opencine.nikon.NikonMediaContentKind
import com.opencapture.openzcine.frameio.*
import java.io.File
import java.io.OutputStream
import java.nio.file.Files
import java.nio.file.Path
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.CoroutineStart
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.async
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withContext
import kotlinx.coroutines.withTimeout
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith

/** SIMULATED cache, account, HTTP and route ports through the actual Host and Coordinator.
 * Manual gates exercise acceptance before native entry; no camera/cloud/hardware credit. */
@RunWith(AndroidJUnit4::class)
class NikonRemoteDeliveryAdmissionTest {
    @Test fun currentAcceptedProjectUploadsAfterPredecessorCleanup() = runBlocking {
        withContext(Dispatchers.Main.immediate) { fixture { f ->
            f.accept()
            assertEquals(0, f.http.uploads)
            f.releaseEntry()
            f.join()
            assertEquals(listOf("SIMULATED-folder-A"), f.http.createdFolders)
            assertEquals(listOf("SIMULATED-token-A"), f.http.createdBearers)
            assertEquals(1, f.http.uploads)
        } }
    }
    @Test fun acceptedProjectDoesNotBorrowASelectionChangedDuringPredecessorCleanup() = runBlocking {
        withContext(Dispatchers.Main.immediate) { fixture { f ->
            f.accept()
            f.selectB()
            f.releaseEntry()
            f.join()
            assertEquals(listOf("SIMULATED-folder-A"), f.http.createdFolders)
            assertEquals("SIMULATED-project-B", f.controller.selectedDestination?.projectID)
            assertEquals(1, f.http.uploads)
        } }
    }
    @Test fun acceptedAccountRefusesReauthenticationDuringPredecessorCleanup() = runBlocking {
        withContext(Dispatchers.Main.immediate) { fixture { f ->
            f.accept()
            f.reauthenticate("SIMULATED-token-B")
            f.controller.loadProjects()
            f.selectB()
            f.releaseEntry()
            f.join()
            f.assertNoDeliveryIO()
            assertEquals("SIMULATED-project-B", f.controller.selectedDestination?.projectID)
        } }
    }
    @Test fun acceptedAccountRefusesSameAccountReauthenticationABA() = runBlocking {
        withContext(Dispatchers.Main.immediate) { fixture { f ->
            f.accept()
            f.reauthenticate("SIMULATED-token-B")
            f.reauthenticate("SIMULATED-token-A")
            f.controller.loadProjects()
            f.releaseEntry()
            f.join()
            f.assertNoDeliveryIO()
            assertEquals("SIMULATED-project-A", f.controller.selectedDestination?.projectID)
        } }
    }
    @Test fun oldVisibleListingCannotAcceptAReauthenticatedAccount() = runBlocking {
        withContext(Dispatchers.Main.immediate) { fixture { f ->
            val popup = f.prepare()
            f.reauthenticate("SIMULATED-token-B")
            f.controller.loadProjects()
            val request = popup.model.takeRequest()!!
            f.host.dismissPopup(popup)
            f.host.begin(popup, request)
            assertNull(f.host.capturedRun)
            assertFalse(f.entryEntered.isCompleted)
            f.assertNoDeliveryIO()
        } }
    }
    @Test fun savedDestinationBeforeListingKeepsItsAcceptedFolderDuringWait() = runBlocking {
        withContext(Dispatchers.Main.immediate) { fixture { f ->
            val projects = CompletableDeferred<Unit>()
            f.http.projectsRelease = projects
            val popup = f.prepare(waitForListing = false)
            withTimeout(10_000) { f.http.projectsEntered.await() }
            assertNull(popup.model.state.value.listing)
            assertTrue(popup.model.canContinue)
            f.accept(popup)
            projects.complete(Unit)
            f.http.projectsRelease = null
            f.controller.loadProjects()
            f.selectB()
            f.releaseEntry()
            f.join()
            assertEquals(listOf("SIMULATED-folder-A"), f.http.createdFolders)
            assertEquals("SIMULATED-project-B", f.controller.selectedDestination?.projectID)
            assertEquals(1, f.http.uploads)
        } }
    }
    @Test fun canceledBeforeNativeEntryJoinsOnlyTheAcceptedPreparationRoute() = runBlocking {
        withContext(Dispatchers.Main.immediate) { fixture { f ->
            val accepted = f.accept(withRoute = true)
            accepted.cancel()
            withTimeout(10_000) { f.hop.returnEntered.await() }
            val joined = f.scope.async(start = CoroutineStart.UNDISPATCHED) { accepted.awaitEnteredCleanup() }
            assertFalse(joined.isCompleted)
            assertFalse(f.controller.ownsInternetHop(f.acceptedLease!!))
            f.assertNoDeliveryIO()
            f.hop.returnRelease.complete(Unit)
            withTimeout(10_000) { joined.await() }
            f.join()
            assertEquals(1, f.hop.leaves)
            assertEquals(1, f.hop.joins)
            assertFalse(f.coordinator.nativeState.value.running)
        } }
    }
    @Test fun accountRefusedBeforeNativeEntryJoinsTheAcceptedPreparationRoute() = runBlocking {
        withContext(Dispatchers.Main.immediate) { fixture { f ->
            f.accept(withRoute = true)
            f.reauthenticate("SIMULATED-token-B")
            f.releaseEntry()
            withTimeout(10_000) { f.hop.returnEntered.await() }
            f.assertNoDeliveryIO()
            assertTrue(f.coordinator.nativeState.value.running)
            f.hop.returnRelease.complete(Unit)
            f.join()
            assertEquals(1, f.hop.leaves)
            assertEquals(1, f.hop.joins)
            assertNull(f.coordinator.completionToast)
        } }
    }
    @Test fun oldBeforeEntryCancellationCannotRestoreASuccessorRoute() = runBlocking {
        withContext(Dispatchers.Main.immediate) { fixture { f ->
            val accepted = f.accept(withRoute = true)
            f.hop.returnRelease.complete(Unit)
            assertTrue(f.controller.endInternetHop(f.acceptedLease!!))
            val successor = Hop(f.network)
            f.network.value = FrameioNetworkState.CAMERA_ACCESS_POINT
            f.controller.attachCameraHop(successor)
            val next = f.controller.claimInternetHop { true }!!
            accepted.cancel()
            f.join()
            f.assertNoDeliveryIO()
            assertTrue(f.controller.ownsInternetHop(next))
            assertEquals(0, successor.leaves)
            assertEquals(0, successor.joins)
            assertEquals(1, f.hop.joins)
            f.controller.endInternetHop(next)
        } }
    }

    private class Preferences : MediaLibraryPreferences {
        private val values = mutableMapOf<String, String>()
        override fun getString(key: String): String? = values[key]
        override fun putString(key: String, value: String?) {
            if (value == null) values.remove(key) else values[key] = value
        }
    }
    private class Secrets : FrameioSecretStore {
        var token: FrameioStoredToken? = FrameioStoredToken("SIMULATED-token-A", null, Long.MAX_VALUE, "Bearer")
        var pending: FrameioPendingAuthorization? = null
        override fun load() = FrameioSecretState(token, pending)
        override fun saveToken(token: FrameioStoredToken) { this.token = token }
        override fun clearToken() { token = null }
        override fun savePendingAuthorization(pending: FrameioPendingAuthorization) { this.pending = pending }
        override fun clearPendingAuthorization() { pending = null }
        override fun clearAll() { token = null; pending = null }
    }
    private class Destinations : FrameioDestinationStore {
        var value: FrameioDestination? = FrameioDestination("SIMULATED-account", "SIMULATED-workspace",
            "SIMULATED-project-A", "SIMULATED A", "SIMULATED-folder-A")
        override fun load() = value
        override fun save(destination: FrameioDestination) { value = destination }
        override fun clear() { value = null }
    }
    private class Network : FrameioReachability {
        var value = FrameioNetworkState.ONLINE
        override fun state() = value
    }
    private class Hop(private val network: Network) : FrameioCameraHop {
        override val availability = FrameioHopAvailability.READY
        val returnEntered = CompletableDeferred<Unit>()
        val returnRelease = CompletableDeferred<Unit>()
        var leaves = 0
        var joins = 0
        override suspend fun leaveCameraNetwork(): Boolean {
            leaves++; network.value = FrameioNetworkState.ONLINE; return true
        }
        override suspend fun rejoinCameraNetwork(): FrameioCameraRejoinEvidence {
            joins++; returnEntered.complete(Unit); returnRelease.await()
            network.value = FrameioNetworkState.CAMERA_ACCESS_POINT
            return FrameioCameraRejoinEvidence("SIMULATED", "SIMULATED", 7)
        }
    }
    private class Core : FrameioCoreBridge {
        var accessToken = "SIMULATED-token-A"
        override fun beginAuthorization(config: FrameioPublicConfiguration, nowEpochMillis: Long) =
            FrameioAuthorizationTransaction("https://auth.example.invalid/authorize", "SIMULATED-state", "v".repeat(43), nowEpochMillis)
        override fun parseRedirect(config: FrameioPublicConfiguration, callbackURI: String, expectedState: String) = "SIMULATED-code"
        override fun tokenRequest(kind: String, config: FrameioPublicConfiguration, code: String?, verifier: String?, refreshToken: String?) =
            FrameioHttpRequest("https://auth.example.invalid/token", "POST", null)
        override fun apiRequest(operation: String, accountID: String?, workspaceID: String?, folderID: String?,
            fileID: String?, name: String?, fileSize: Long) = FrameioHttpRequest("https://api.example.invalid/$operation", "GET", folderID)
        override fun decodeToken(response: String) = FrameioAccessToken(accessToken, null, 3_600, "Bearer")
        override fun decodeProjects(response: String) = listOf(FrameioProject("SIMULATED-project-A", "SIMULATED A", "SIMULATED-folder-A"),
            FrameioProject("SIMULATED-project-B", "SIMULATED B", "SIMULATED-folder-B"))
        override fun decodeProject(response: String) = decodeProjects(response).first()
        override fun decodeAccounts(response: String) = listOf(FrameioAccount("SIMULATED-account", null))
        override fun decodeWorkspaces(response: String) = listOf(FrameioWorkspace("SIMULATED-workspace", "SIMULATED Workspace"))
        override fun decodeUploadPlan(response: String) = FrameioUploadPlan("SIMULATED-file", "video/quicktime",
            listOf(FrameioUploadPart(4, "https://uploads.example.invalid/part")))
        override fun decodeUploadComplete(response: String) = true
        override fun mediaTypeFor(filename: String) = "video/quicktime"
    }
    private class Http : FrameioHttpClient {
        val createdFolders = mutableListOf<String?>()
        val createdBearers = mutableListOf<String?>()
        var uploads = 0
        val projectsEntered = CompletableDeferred<Unit>()
        var projectsRelease: CompletableDeferred<Unit>? = null
        override suspend fun execute(request: FrameioHttpRequest, bearerToken: String?, contentType: String?): FrameioHttpResponse {
            if (request.url.endsWith("/${FrameioCoreOperation.PROJECTS}")) {
                projectsEntered.complete(Unit); projectsRelease?.await()
            }
            if (request.url.endsWith("/${FrameioCoreOperation.CREATE_FILE}")) {
                createdFolders += request.body; createdBearers += bearerToken
            }
            return FrameioHttpResponse(200, "{}")
        }
        override suspend fun putUploadPart(uploadURL: String, source: Path, offset: Long, byteCount: Long,
            contentType: String, onBytesSent: suspend (Long) -> Unit): FrameioHttpResponse {
            uploads++
            assertEquals(4L, byteCount)
            assertArrayEquals(byteArrayOf(1, 2, 3, 4), Files.readAllBytes(source))
            onBytesSent(byteCount)
            return FrameioHttpResponse(200, "")
        }
    }
    private class Fixture(val root: Path) {
        val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)
        val network = Network()
        val hop = Hop(network)
        val core = Core()
        val http = Http()
        private val secrets = Secrets()
        private val destinations = Destinations()
        val entryEntered = CompletableDeferred<Unit>()
        private val entryRelease = CompletableDeferred<Unit>()
        val cache = MediaCacheStore(root.resolve("media"))
        private val context = object : ContextWrapper(InstrumentationRegistry.getInstrumentation().targetContext) {
            override fun getCacheDir(): File = root.resolve("cache").toFile().apply { mkdirs() }
        }
        val controller = FrameioDeliveryController({ FrameioPublicConfiguration("SIMULATED", "simulated://callback") }, core, http,
            secrets, destinations, network, root.resolve("cache/share/ready"), clock = { 1_000L },
            internetWaitPoll = {}, internetWaitAttempts = 2)
        val coordinator = MediaDeliveryCoordinator(context, controller, cache, object : MediaGalleryGateway {
            override fun createPending(artifact: MediaGalleryArtifact): PendingMediaGalleryItem = error("No Gallery IO")
            override fun openPending(item: PendingMediaGalleryItem): OutputStream = error("No Gallery IO")
            override fun publish(item: PendingMediaGalleryItem) = error("No Gallery IO")
            override fun deletePending(item: PendingMediaGalleryItem) = error("No Gallery IO")
        }, scope)
        private val index = MediaLibraryIndex(Preferences())
        private val codec = NikonMediaLibraryCodec("SIMULATED", null, cache, { emptySet() }, { false })
        val record = codec.record(NikonLibraryClip("SIMULATED", NikonMediaClipRecord(1, 1, 4, "20261007T120000",
            1920, 1080, "A.MOV", NikonMediaContentKind.PLAYABLE_PROXY, null)))
        private val library = MonitorMediaLibraryModel(MonitorMediaCache(MonitorMediaCacheDirectory(cache.rootDirectory.toFile()), codec,
            eligibility = MonitorMediaOriginalEligibility.ExactSize, catalogAddress = "SIMULATED/index.json", preservedMetadata = emptyList(),
            catalogStore = index.catalogByteStore("SIMULATED")), NikonLibraryFavorites(index, listOf("SIMULATED")),
            scope = scope, cacheScanning = MonitorMediaCacheScanning.IMMEDIATE, initialCatalog = MediaCatalog(), initialRecords = listOf(record))
        val host: NikonMediaDeliveryHost
        var acceptedLease: FrameioInternetLease? = null
        init {
            cache.openEntry("SIMULATED", MediaCacheObjectIdentity(record.payload.clip), 4).apply {
                append(0, byteArrayOf(1, 2, 3, 4)); complete()
            }
            library.begin()
            host = NikonMediaDeliveryHost(scope, coordinator, controller, cache, library,
                MonitorMediaGalleryOpen(record, listOf(record), library.actionToken), null, { true }, { MonitorPlaybackAdmission { true } },
                { MediaDeliveryConfiguration(bakeLut = false, includeMetadata = false) }, beforeFirstIO = {
                    entryEntered.complete(Unit); entryRelease.await()
                })
        }
        suspend fun prepare(waitForListing: Boolean = true): NikonMediaDeliveryHost.Popup {
            host.share(record)
            val popup = host.popup.value!!
            popup.model.selectDestination(MonitorDeliveryDestination.REMOTE_UPLOAD)
            if (waitForListing) withTimeout(10_000) { popup.model.state.first { it.listing != null && !it.projectsLoading } }
            return popup
        }
        suspend fun accept(withRoute: Boolean = false): MonitorDeliveryRunHandle = accept(prepare(), withRoute)
        suspend fun accept(popup: NikonMediaDeliveryHost.Popup, withRoute: Boolean = false): MonitorDeliveryRunHandle {
            if (withRoute) {
                network.value = FrameioNetworkState.CAMERA_ACCESS_POINT
                controller.attachCameraHop(hop)
                val lease = controller.claimInternetHop { true }!!
                assertTrue(controller.waitInternetHop(lease))
                assertTrue(popup.model.adoptInternetLease(lease))
            }
            val request = popup.model.takeRequest()!!
            acceptedLease = request.internetLease
            host.dismissPopup(popup)
            host.begin(popup, request)
            val run = host.capturedRun!!
            withTimeout(10_000) { entryEntered.await() }
            return run
        }
        suspend fun selectB() {
            val listing = controller.loadProjectsCaptured { true }
            assertTrue(controller.selectProjectCaptured(core.decodeProjects("{}").last(), listing) { true })
        }
        suspend fun reauthenticate(access: String) {
            controller.disconnect(); core.accessToken = access
            assertNotNull(controller.beginSignIn())
            controller.completeRedirect("simulated://callback?code=SIMULATED-code&state=SIMULATED-state")
            assertTrue(controller.isConnected)
        }
        fun releaseEntry() { entryRelease.complete(Unit) }
        suspend fun join() { withTimeout(10_000) { host.capturedRun!!.awaitEnteredCleanup() } }
        fun assertNoDeliveryIO() {
            assertEquals(0, http.uploads)
            assertTrue(http.createdFolders.isEmpty())
            assertFalse(Files.exists(root.resolve("cache/share/ready")))
        }
        suspend fun close() {
            entryRelease.complete(Unit); hop.returnRelease.complete(Unit); http.projectsRelease?.complete(Unit)
            host.cancelAndJoin(); coordinator.close(); library.dispose(); scope.cancel()
        }
    }
    private suspend fun fixture(body: suspend (Fixture) -> Unit) {
        val root = Files.createTempDirectory("SIMULATED-accepted-remote-delivery")
        val f = Fixture(root)
        try { body(f) } finally { f.close(); root.toFile().deleteRecursively() }
    }
}
