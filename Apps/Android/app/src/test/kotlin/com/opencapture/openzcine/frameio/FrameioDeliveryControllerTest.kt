package com.opencapture.openzcine.frameio

import com.opencapture.openzcine.media.StagedMediaShare
import java.nio.file.Files
import java.nio.file.Path
import java.util.concurrent.Executors
import kotlin.io.path.createTempDirectory
import kotlin.coroutines.CoroutineContext
import kotlin.test.Test
import kotlin.test.assertContains
import kotlin.test.assertEquals
import kotlin.test.assertIs
import kotlin.test.assertNotNull
import kotlin.test.assertNull
import kotlin.test.assertTrue
import kotlinx.coroutines.CoroutineDispatcher
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import kotlinx.coroutines.test.runTest

/** Host-side coverage for Android's fail-closed Frame.io delivery state holder. */
class FrameioDeliveryControllerTest {
    @Test
    fun `unconfigured build never starts authorization`() {
        val core = FakeCore()
        val controller = controller(configuration = { null }, core = core)

        assertEquals(FrameioConnectionState.UNCONFIGURED, controller.connectionState)
        assertNull(controller.beginSignIn())
        assertEquals(0, core.authorizationStarts)
        assertContains(controller.errorMessage.orEmpty(), "isn't configured")
    }

    @Test
    fun `camera access point binding blocks authorization without releasing it`() {
        val core = FakeCore()
        val controller =
            controller(
                core = core,
                reachability = FixedReachability(FrameioNetworkState.CAMERA_ACCESS_POINT),
            )

        assertNull(controller.beginSignIn())
        assertEquals(0, core.authorizationStarts)
        assertContains(controller.errorMessage.orEmpty(), "will not interrupt")
    }

    @Test
    fun `verified redirect exchanges only persisted PKCE state`() = runTest {
        val secrets = MemorySecretStore()
        val core = FakeCore()
        val http = FakeHttp()
        val controller = controller(core = core, http = http, secrets = secrets)

        val authorizationURL = controller.beginSignIn()

        assertEquals("https://auth.example.invalid/authorize", authorizationURL)
        assertEquals(FrameioConnectionState.AUTHORIZING, controller.connectionState)
        assertNotNull(secrets.state.pendingAuthorization)

        controller.completeRedirect("openzcine-unit://oauth/callback?code=unit-code&state=unit-state")

        assertEquals(FrameioConnectionState.CONNECTED, controller.connectionState)
        assertEquals("unit-access", secrets.state.token?.accessToken)
        assertNull(secrets.state.pendingAuthorization)
        assertEquals(1, core.redirectParses)
        assertEquals(1, core.tokenRequests)
        assertEquals(1, http.executeCalls)
    }

    @Test
    fun `unverified redirect clears pending state without sending a token request`() = runTest {
        val secrets = MemorySecretStore()
        val core = FakeCore()
        val http = FakeHttp()
        val controller = controller(core = core, http = http, secrets = secrets)

        controller.beginSignIn()
        controller.completeRedirect("openzcine-unit://other/callback?code=unit-code&state=unit-state")

        assertEquals(FrameioConnectionState.ERROR, controller.connectionState)
        assertNull(secrets.state.pendingAuthorization)
        assertEquals(1, core.redirectParses)
        assertEquals(0, core.tokenRequests)
        assertEquals(0, http.executeCalls)
    }

    @Test
    fun `delivery accepts only a staged complete cache copy and polls Frameio status`() = runTest {
        withReadyRoot { root ->
            val source = root.resolve("C0001.MOV")
            Files.write(source, byteArrayOf(1, 2, 3, 4))
            val core = FakeCore()
            val http = FakeHttp()
            val secrets =
                MemorySecretStore(
                    FrameioSecretState(
                        FrameioStoredToken("unit-access", "unit-refresh", 9_999_999L, "Bearer"),
                        null,
                    ),
                )
            val destinations = MemoryDestinationStore()
            val controller =
                controller(
                    core = core,
                    http = http,
                    secrets = secrets,
                    destinations = destinations,
                    shareReadyRoot = root,
                )

            controller.loadProjects()
            val selected = controller.selectedDestination
            assertNotNull(selected)
            assertEquals("project", selected.projectID)

            controller.deliver(
                listOf(
                    FrameioDeliveryArtifact(
                        StagedMediaShare(source, "C0001.MOV", "video/*"),
                        4,
                    ),
                ),
            )

            val completed = assertIs<FrameioDeliveryState.Completed>(controller.deliveryState)
            assertEquals(1, completed.uploadedCount)
            assertEquals(0, completed.failedCount)
            assertEquals(1, http.uploadCalls)
            assertContains(core.apiOperations, FrameioCoreOperation.CREATE_FILE)
            assertContains(core.apiOperations, FrameioCoreOperation.UPLOAD_STATUS)
        }
    }

    @Test
    fun `delivery rejects a path outside share ready before any Frameio request`() = runTest {
        withReadyRoot { readyRoot ->
            val outside = readyRoot.parent.resolve("outside.mov")
            Files.write(outside, byteArrayOf(1, 2, 3, 4))
            val http = FakeHttp()
            val controller =
                controller(
                    http = http,
                    shareReadyRoot = readyRoot,
                    destinations =
                        MemoryDestinationStore(
                            FrameioDestination("account", "workspace", "project", "Dailies", "folder"),
                        ),
                    secrets =
                        MemorySecretStore(
                            FrameioSecretState(
                                FrameioStoredToken("unit-access", "unit-refresh", 9_999_999L, "Bearer"),
                                null,
                            ),
                        ),
                )

            controller.deliver(
                listOf(
                    FrameioDeliveryArtifact(
                        StagedMediaShare(outside, "C0002.MOV", "video/*"),
                        4,
                    ),
                ),
            )

            val failed = assertIs<FrameioDeliveryState.Failed>(controller.deliveryState)
            assertContains(failed.message, "Only complete approved")
            assertEquals(0, http.executeCalls)
            assertEquals(0, http.uploadCalls)
        }
    }

    @Test
    fun `delivery rechecks reachability before a signed upload part`() = runTest {
        withReadyRoot { readyRoot ->
            val source = readyRoot.resolve("C0003.MOV")
            Files.write(source, byteArrayOf(1, 2, 3, 4))
            val http = FakeHttp()
            val controller =
                controller(
                    http = http,
                    shareReadyRoot = readyRoot,
                    reachability =
                        SequencedReachability(
                            listOf(
                                FrameioNetworkState.ONLINE,
                                FrameioNetworkState.ONLINE,
                                FrameioNetworkState.ONLINE,
                                FrameioNetworkState.CAMERA_ACCESS_POINT,
                            ),
                        ),
                    destinations =
                        MemoryDestinationStore(
                            FrameioDestination("account", "workspace", "project", "Dailies", "folder"),
                        ),
                    secrets =
                        MemorySecretStore(
                            FrameioSecretState(
                                FrameioStoredToken("unit-access", "unit-refresh", 9_999_999L, "Bearer"),
                                null,
                            ),
                        ),
                )

            controller.deliver(
                listOf(
                    FrameioDeliveryArtifact(
                        StagedMediaShare(source, "C0003.MOV", "video/*"),
                        4,
                    ),
                ),
            )

            assertIs<FrameioDeliveryState.Failed>(controller.deliveryState)
            assertEquals(1, http.executeCalls)
            assertEquals(0, http.uploadCalls)
            assertContains(controller.errorMessage.orEmpty(), "will not interrupt")
        }
    }

    @Test
    fun `delivery progress returns from HTTP IO to the UI dispatcher`() = runTest {
        withReadyRoot { readyRoot ->
            val source = readyRoot.resolve("C0004.MOV")
            Files.write(source, byteArrayOf(1, 2, 3, 4))
            val http = FakeHttp(progressFromIO = true)
            val uiDispatcher = RecordingUIDispatcher()
            try {
                val controller =
                    controller(
                        http = http,
                        shareReadyRoot = readyRoot,
                        uiDispatcher = uiDispatcher,
                        destinations =
                            MemoryDestinationStore(
                                FrameioDestination("account", "workspace", "project", "Dailies", "folder"),
                            ),
                        secrets =
                            MemorySecretStore(
                                FrameioSecretState(
                                    FrameioStoredToken("unit-access", "unit-refresh", 9_999_999L, "Bearer"),
                                    null,
                                ),
                            ),
                    )

                controller.deliver(
                    listOf(
                        FrameioDeliveryArtifact(
                            StagedMediaShare(source, "C0004.MOV", "video/*"),
                            4,
                        ),
                    ),
                )

                val ioThread = assertNotNull(http.progressCallbackThreadName)
                val uiThread = assertNotNull(uiDispatcher.lastDispatchThreadName)
                assertTrue(ioThread != uiThread)
                assertEquals("frameio-delivery-ui", uiThread)
                assertIs<FrameioDeliveryState.Completed>(controller.deliveryState)
            } finally {
                uiDispatcher.close()
            }
        }
    }

    private fun controller(
        configuration: () -> FrameioPublicConfiguration? = { CONFIGURATION },
        core: FakeCore = FakeCore(),
        http: FakeHttp = FakeHttp(),
        secrets: MemorySecretStore = MemorySecretStore(),
        destinations: MemoryDestinationStore = MemoryDestinationStore(),
        reachability: FrameioReachability = FixedReachability(FrameioNetworkState.ONLINE),
        shareReadyRoot: Path = Path.of(System.getProperty("java.io.tmpdir"), "frameio-ready"),
        uiDispatcher: CoroutineDispatcher = Dispatchers.Unconfined,
    ): FrameioDeliveryController =
        FrameioDeliveryController(
            configuration = configuration,
            core = core,
            http = http,
            secretStore = secrets,
            destinationStore = destinations,
            reachability = reachability,
            shareReadyRoot = shareReadyRoot,
            clock = { 100_000L },
            uiDispatcher = uiDispatcher,
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

    private class SequencedReachability(values: List<FrameioNetworkState>) : FrameioReachability {
        private val values = values.iterator()
        private var last = FrameioNetworkState.OFFLINE

        override fun state(): FrameioNetworkState {
            if (values.hasNext()) last = values.next()
            return last
        }
    }

    private class FakeCore : FrameioCoreBridge {
        var authorizationStarts = 0
        var redirectParses = 0
        var tokenRequests = 0
        val apiOperations = mutableListOf<String>()

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
                parts = listOf(FrameioUploadPart(4, "https://uploads.example.invalid/part")),
            )

        override fun decodeUploadComplete(response: String): Boolean? = true

        override fun mediaTypeFor(filename: String): String? = "application/octet-stream"
    }

    private class FakeHttp(
        private val progressFromIO: Boolean = false,
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
            assertTrue(Files.isRegularFile(source))
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

    private class RecordingUIDispatcher : CoroutineDispatcher(), AutoCloseable {
        private val executor =
            Executors.newSingleThreadExecutor { runnable ->
                Thread(runnable, "frameio-delivery-ui")
            }
        @Volatile var lastDispatchThreadName: String? = null

        override fun dispatch(context: CoroutineContext, block: Runnable) {
            executor.execute {
                lastDispatchThreadName = Thread.currentThread().name
                block.run()
            }
        }

        override fun close() {
            executor.shutdownNow()
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
