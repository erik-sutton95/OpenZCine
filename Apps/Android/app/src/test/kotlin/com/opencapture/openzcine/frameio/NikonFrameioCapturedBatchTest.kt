package com.opencapture.openzcine.frameio

import com.opencapture.opencine.appkit.*
import com.opencapture.openzcine.media.StagedMediaShare
import java.nio.file.Files
import java.nio.file.Path
import kotlin.io.path.createTempDirectory
import kotlin.test.*
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.CoroutineDispatcher
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.async
import kotlinx.coroutines.withContext
import kotlinx.coroutines.test.runTest

/** SIMULATED actual SDK-port assertions over the consumed shared ordered batch and project ports. */
class NikonFrameioCapturedBatchTest {
    @Test fun currentBatchKeepsNativeThresholdsAndDuplicateOrder() = runTest {
        withReadyRoot { root ->
            val artifacts = (1..2).map { n -> val file = root.resolve("source$n.MOV")
                Files.write(file, byteArrayOf(n.toByte(), 2, 3, 4))
                FrameioDeliveryArtifact(StagedMediaShare(file, "SAME.MOV", "video/quicktime"), 4) }
            val core = FakeCore(); val http = FakeHttp(); val controller = connectedController(root, core, http)
            val reports = mutableListOf<FrameioDeliveryState>()
            controller.deliver(artifacts, onDeliveryState = { reports += it })
            assertEquals(listOf(1, 2), reports.filterIsInstance<FrameioDeliveryState.Uploading>().map { it.itemIndex }.distinct())
            assertTrue(reports.filterIsInstance<FrameioDeliveryState.Uploading>().any { it.progress == 0.85 })
            assertEquals(2, assertIs<FrameioDeliveryState.Completed>(reports.last()).uploadedCount)
            assertEquals(listOf("SAME.MOV", "SAME.MOV"), core.createdNames)
            assertEquals(2, http.uploadCalls)
        }
    }
    @Test fun retiredExportRefusesFirstCloudDispatchAndReleasesEnteredArtifact() = runTest {
        withReadyRoot { root ->
            val artifact = artifact(root, "A.MOV"); var current = true; var releases = 0
            val preparer = object : FrameioArtifactPreparer {
                override suspend fun prepare(artifact: FrameioDeliveryArtifact, options: MediaDeliveryConfiguration,
                    onProgress: suspend (Double) -> Unit): FrameioPreparedArtifact {
                    current = false
                    return FrameioPreparedArtifact(artifact.share, artifact.byteCount, null, null)
                }
                override suspend fun release(prepared: FrameioPreparedArtifact) { releases += 1 }
            }
            val core = FakeCore(); val http = FakeHttp()
            val controller = connectedController(root, core, http, artifactPreparer = preparer)
            assertFailsWith<CancellationException> { captured(controller, artifact) { current } }
            assertEquals(0, core.createdNames.size); assertEquals(0, http.uploadCalls)
            assertEquals(1, releases); assertIs<FrameioDeliveryState.Idle>(controller.deliveryState)
        }
    }
    @Test fun enteredOldUploadDoesNotPublishOrDispatchForSuccessor() = runTest {
        withReadyRoot { root ->
            val entered = CompletableDeferred<Unit>(); val finish = CompletableDeferred<Unit>()
            var current = true
            lateinit var http: FakeHttp
            http = FakeHttp(onUpload = { if (http.uploadCalls == 1) { entered.complete(Unit); finish.await() } })
            val core = FakeCore(); val controller = connectedController(root, core, http)
            val old = async { captured(controller, artifact(root, "A.MOV")) { current } }
            entered.await(); current = false
            controller.deliver(listOf(artifact(root, "B.MOV")))
            val successor = controller.deliveryState
            assertEquals(1, assertIs<FrameioDeliveryState.Completed>(successor).uploadedCount)
            finish.complete(Unit)
            assertFailsWith<CancellationException> { old.await() }
            assertEquals(successor, controller.deliveryState)
            assertEquals(listOf("A.MOV", "B.MOV"), core.createdNames)
            assertEquals(1, core.apiOperations.count { it == FrameioCoreOperation.UPLOAD_STATUS })
        }
    }
    @Test fun lateProjectResultAfterDisconnectDoesNotPublishOrQueryAnotherAccount() = runTest {
        withReadyRoot { root ->
            lateinit var controller: FrameioDeliveryController
            val http = FakeHttp(onExecute = { controller.disconnect() })
            controller = connectedController(root, http = http)
            assertFailsWith<CancellationException> { controller.loadProjectsCaptured { true } }
            assertEquals(1, http.executeCalls); assertNull(controller.projectListing)
            assertNull(controller.selectedDestination); assertEquals(FrameioConnectionState.SIGNED_OUT, controller.connectionState)
        }
    }
    @Test fun capturedProjectFactsWorkAndRefuseReentrantAccountReplacement() = runTest {
        withReadyRoot { root ->
            val controller = connectedController(root)
            val listing = controller.loadProjectsCaptured { true }
            val created = controller.createProjectCaptured("SIMULATED project", listing) { true }
            assertTrue(controller.selectProjectCaptured(created, listing) { true })
            assertEquals("created", controller.selectedDestination?.projectID)
            assertFalse(controller.selectProjectCaptured(listing.listing.projects.first(), listing) {
                controller.disconnect(); true
            })
            assertNull(controller.selectedDestination)
            assertFailsWith<CancellationException> { controller.createProjectCaptured("old", listing) { true } }
        }
    }
    private fun artifact(root: Path, name: String): FrameioDeliveryArtifact {
        val file = root.resolve(name); Files.write(file, byteArrayOf(1, 2, 3, 4))
        return FrameioDeliveryArtifact(StagedMediaShare(file, name, "video/quicktime"), 4)
    }
    private suspend fun captured(controller: FrameioDeliveryController, artifact: FrameioDeliveryArtifact,
        current: () -> Boolean): FrameioDeliveryState = controller.deliverCaptured(listOf(artifact),
        MediaDeliveryConfiguration(), MonitorDeliveryAdmission(current), null,
        MonitorDeliveryOriginalService({ true }, {}, { null }), { it.share.displayName }, { it })

    private fun controller(
        configuration: () -> FrameioPublicConfiguration? = { CONFIGURATION },
        core: FakeCore = FakeCore(),
        http: FakeHttp = FakeHttp(),
        secrets: MemorySecretStore = MemorySecretStore(),
        destinations: MemoryDestinationStore = MemoryDestinationStore(),
        reachability: FrameioReachability = FixedReachability(FrameioNetworkState.ONLINE),
        shareReadyRoot: Path = Path.of(System.getProperty("java.io.tmpdir"), "frameio-ready"),
        uiDispatcher: CoroutineDispatcher = Dispatchers.Unconfined,
        approvedUploadRoots: List<Path> = listOf(shareReadyRoot),
        artifactPreparer: FrameioArtifactPreparer = PassthroughFrameioArtifactPreparer,
        metadataSidecarWriter: FrameioMetadataSidecarWriter = NoFrameioMetadataSidecarWriter,
        uploadHistory: FrameioUploadHistoryStore = NoFrameioUploadHistoryStore,
        internetWaitPoll: suspend () -> Unit = {},
        internetWaitAttempts: Int = 3,
    ): FrameioDeliveryController =
        FrameioDeliveryController(
            configuration = configuration,
            core = core,
            http = http,
            secretStore = secrets,
            destinationStore = destinations,
            reachability = reachability,
            shareReadyRoot = shareReadyRoot,
            approvedUploadRoots = approvedUploadRoots,
            artifactPreparer = artifactPreparer,
            metadataSidecarWriter = metadataSidecarWriter,
            uploadHistory = uploadHistory,
            clock = { 100_000L },
            uiDispatcher = uiDispatcher,
            internetWaitPoll = internetWaitPoll,
            internetWaitAttempts = internetWaitAttempts,
        )

    private fun connectedController(
        readyRoot: Path,
        core: FakeCore = FakeCore(),
        http: FakeHttp = FakeHttp(),
        reachability: FrameioReachability = FixedReachability(FrameioNetworkState.ONLINE),
        approvedUploadRoots: List<Path> = listOf(readyRoot),
        artifactPreparer: FrameioArtifactPreparer = PassthroughFrameioArtifactPreparer,
        metadataSidecarWriter: FrameioMetadataSidecarWriter = NoFrameioMetadataSidecarWriter,
        uploadHistory: FrameioUploadHistoryStore = NoFrameioUploadHistoryStore,
    ): FrameioDeliveryController =
        controller(
            core = core,
            http = http,
            secrets =
                MemorySecretStore(
                    FrameioSecretState(
                        FrameioStoredToken("unit-access", "unit-refresh", 9_999_999L, "Bearer"),
                        null,
                    ),
                ),
            destinations =
                MemoryDestinationStore(
                    FrameioDestination("account", "workspace", "project", "Dailies", "folder"),
                ),
            reachability = reachability,
            shareReadyRoot = readyRoot,
            approvedUploadRoots = approvedUploadRoots,
            artifactPreparer = artifactPreparer,
            metadataSidecarWriter = metadataSidecarWriter,
            uploadHistory = uploadHistory,
        )

    private suspend fun withReadyRoot(block: suspend (Path) -> Unit) {
        val root = createTempDirectory("frameio-ready")
        try {
            block(root)
        } finally {
            root.toFile().deleteRecursively()
        }
    }

    private class MemorySecretStore(initial: FrameioSecretState = FrameioSecretState(null, null)) :
        FrameioSecretStore {
        var state: FrameioSecretState = initial

        override fun load(): FrameioSecretState = state

        override fun saveToken(token: FrameioStoredToken) {
            state = FrameioSecretState(token, state.pendingAuthorization)
        }

        override fun clearToken() {
            state = FrameioSecretState(null, state.pendingAuthorization)
        }

        override fun savePendingAuthorization(pending: FrameioPendingAuthorization) {
            state = FrameioSecretState(state.token, pending)
        }

        override fun clearPendingAuthorization() {
            state = FrameioSecretState(state.token, null)
        }

        override fun clearAll() {
            state = FrameioSecretState(null, null)
        }
    }

    private class MemoryDestinationStore(initial: FrameioDestination? = null) : FrameioDestinationStore {
        private var destination: FrameioDestination? = initial

        override fun load(): FrameioDestination? = destination

        override fun save(destination: FrameioDestination) {
            this.destination = destination
        }

        override fun clear() {
            destination = null
        }
    }

    private class FixedReachability(private val value: FrameioNetworkState) : FrameioReachability {
        override fun state(): FrameioNetworkState = value
    }

    private class FakeCore(private val uploadPlanSize: Long = 4) : FrameioCoreBridge {
        var authorizationStarts = 0
        var redirectParses = 0
        var tokenRequests = 0
        val apiOperations = mutableListOf<String>()
        val createdNames = mutableListOf<String>()
        val createdSizes = mutableListOf<Long>()

        override fun beginAuthorization(
            config: FrameioPublicConfiguration,
            nowEpochMillis: Long,
        ): FrameioAuthorizationTransaction? {
            authorizationStarts += 1
            return FrameioAuthorizationTransaction(
                authorizationURL = "https://auth.example.invalid/authorize",
                state = "unit-state",
                verifier = "v".repeat(43),
                createdAtEpochMillis = nowEpochMillis,
            )
        }

        override fun parseRedirect(
            config: FrameioPublicConfiguration,
            callbackURI: String,
            expectedState: String,
        ): String? {
            redirectParses += 1
            return "unit-code".takeIf {
                expectedState == "unit-state" &&
                    callbackURI == "${config.redirectURI}?code=unit-code&state=unit-state"
            }
        }

        override fun tokenRequest(
            kind: String,
            config: FrameioPublicConfiguration,
            code: String?,
            verifier: String?,
            refreshToken: String?,
        ): FrameioHttpRequest? {
            tokenRequests += 1
            return FrameioHttpRequest("https://auth.example.invalid/token", "POST", "redacted")
        }

        override fun apiRequest(
            operation: String,
            accountID: String?,
            workspaceID: String?,
            folderID: String?,
            fileID: String?,
            name: String?,
            fileSize: Long,
        ): FrameioHttpRequest? {
            apiOperations += operation
            if (operation == FrameioCoreOperation.CREATE_FILE) {
                createdNames += name.orEmpty()
                createdSizes += fileSize
            }
            return FrameioHttpRequest("https://api.example.invalid/$operation", "GET", null)
        }

        override fun decodeToken(response: String): FrameioAccessToken? =
            FrameioAccessToken("unit-access", "unit-refresh", 3_600, "Bearer")

        override fun decodeProjects(response: String): List<FrameioProject>? =
            listOf(FrameioProject("project", "Dailies", "folder"))

        override fun decodeProject(response: String): FrameioProject? =
            FrameioProject("created", "Created", "created-folder")

        override fun decodeAccounts(response: String): List<FrameioAccount>? =
            listOf(FrameioAccount("account", null))

        override fun decodeWorkspaces(response: String): List<FrameioWorkspace>? =
            listOf(FrameioWorkspace("workspace", "Workspace"))

        override fun decodeUploadPlan(response: String): FrameioUploadPlan? =
            FrameioUploadPlan(
                fileID = "file",
                mediaType = "video/quicktime",
                parts = listOf(FrameioUploadPart(uploadPlanSize, "https://uploads.example.invalid/part")),
            )

        override fun decodeUploadComplete(response: String): Boolean? = true

        override fun mediaTypeFor(filename: String): String? = "application/octet-stream"
    }

    private class FakeHttp(
        private val progressFromIO: Boolean = false,
        private val uploadFailure: Throwable? = null,
        private val failUploadCalls: Set<Int> = emptySet(),
        private val onExecute: suspend (FrameioHttpRequest) -> Unit = {},
        private val onUpload: suspend () -> Unit = {},
    ) : FrameioHttpClient {
        var executeCalls = 0
        var uploadCalls = 0
        var progressCallbackThreadName: String? = null

        override suspend fun execute(
            request: FrameioHttpRequest,
            bearerToken: String?,
            contentType: String?,
        ): FrameioHttpResponse {
            executeCalls += 1
            onExecute(request)
            return FrameioHttpResponse(200, "{}")
        }

        override suspend fun putUploadPart(
            uploadURL: String,
            source: Path,
            offset: Long,
            byteCount: Long,
            contentType: String,
            onBytesSent: suspend (Long) -> Unit,
        ): FrameioHttpResponse {
            uploadCalls += 1
            onUpload()
            assertTrue(Files.isRegularFile(source))
            if (uploadCalls in failUploadCalls) throw java.io.IOException("unit upload failure")
            uploadFailure?.let { throw it }
            if (progressFromIO) {
                withContext(Dispatchers.IO) {
                    progressCallbackThreadName = Thread.currentThread().name
                    onBytesSent(byteCount)
                }
            } else {
                onBytesSent(byteCount)
            }
            return FrameioHttpResponse(200, "")
        }
    }

    private companion object {
        val CONFIGURATION =
            FrameioPublicConfiguration(
                clientID = "unit-client",
                redirectURI = "openzcine-unit://oauth/callback",
            )
    }
}
