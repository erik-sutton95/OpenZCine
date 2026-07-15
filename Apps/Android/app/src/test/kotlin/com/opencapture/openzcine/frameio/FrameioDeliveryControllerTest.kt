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
import kotlin.test.assertFailsWith
import kotlin.test.assertFalse
import kotlin.test.assertIs
import kotlin.test.assertNotNull
import kotlin.test.assertNull
import kotlin.test.assertTrue
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.CoroutineDispatcher
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.async
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

            val completed = assertIs<FrameioDeliveryState.Completed>(controller.deliveryState)
            assertEquals(0, completed.uploadedCount)
            assertEquals(1, completed.failedCount)
            assertContains(completed.firstFailureMessage.orEmpty(), "Only complete approved")
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

            val completed = assertIs<FrameioDeliveryState.Completed>(controller.deliveryState)
            assertEquals(0, completed.uploadedCount)
            assertEquals(1, completed.failedCount)
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

    @Test
    fun `delivery never leaves a camera access point without explicit hop consent`() = runTest {
        withReadyRoot { readyRoot ->
            val source = readyRoot.resolve("C0005.MOV")
            Files.write(source, byteArrayOf(1, 2, 3, 4))
            val http = FakeHttp()
            val hop = FakeCameraHop()
            val controller =
                connectedController(
                    readyRoot = readyRoot,
                    http = http,
                    reachability = FixedReachability(FrameioNetworkState.CAMERA_ACCESS_POINT),
                )
            controller.attachCameraHop(hop)

            controller.deliver(listOf(FrameioDeliveryArtifact(StagedMediaShare(source, "C0005.MOV", "video/*"), 4)))

            assertIs<FrameioDeliveryState.Failed>(controller.deliveryState)
            assertEquals(0, hop.leaveCalls)
            assertEquals(0, http.uploadCalls)
            assertContains(controller.errorMessage.orEmpty(), "without your approval")
        }
    }

    @Test
    fun `consented hop uploads then reports rejoin only with connected evidence`() = runTest {
        withReadyRoot { readyRoot ->
            val source = readyRoot.resolve("C0006.MOV")
            Files.write(source, byteArrayOf(1, 2, 3, 4))
            val reachability = MutableReachability(FrameioNetworkState.CAMERA_ACCESS_POINT)
            val evidence = FrameioCameraRejoinEvidence("Nikon ZR", "ZR", 123_000L)
            val hop =
                FakeCameraHop(
                    onLeave = { reachability.value = FrameioNetworkState.ONLINE },
                    onRejoin = {
                        reachability.value = FrameioNetworkState.CAMERA_ACCESS_POINT
                        evidence
                    },
                )
            val controller = connectedController(readyRoot, reachability = reachability)
            controller.attachCameraHop(hop)

            assertTrue(controller.beginInternetHop())
            assertIs<FrameioInternetHopState.Online>(controller.internetHopState)

            controller.deliver(listOf(FrameioDeliveryArtifact(StagedMediaShare(source, "C0006.MOV", "video/*"), 4)))

            assertIs<FrameioDeliveryState.Completed>(controller.deliveryState)
            val rejoined = assertIs<FrameioInternetHopState.Rejoined>(controller.internetHopState)
            assertEquals(evidence, rejoined.evidence)
            assertEquals(1, hop.leaveCalls)
            assertEquals(1, hop.rejoinCalls)
            assertFalse(controller.isInternetHopActive)
        }
    }

    @Test
    fun `concurrent rejoin callers share one camera attempt and result`() = runTest {
        withReadyRoot { readyRoot ->
            val reachability = MutableReachability(FrameioNetworkState.CAMERA_ACCESS_POINT)
            val rejoinStarted = CompletableDeferred<Unit>()
            val allowRejoin = CompletableDeferred<Unit>()
            val evidence = FrameioCameraRejoinEvidence("Nikon ZR", "ZR", 123_500L)
            val hop =
                FakeCameraHop(
                    onLeave = { reachability.value = FrameioNetworkState.ONLINE },
                    onRejoin = {
                        rejoinStarted.complete(Unit)
                        allowRejoin.await()
                        reachability.value = FrameioNetworkState.CAMERA_ACCESS_POINT
                        evidence
                    },
                )
            val controller = connectedController(readyRoot, reachability = reachability)
            controller.attachCameraHop(hop)

            assertTrue(controller.beginInternetHop())
            val first = async { controller.endInternetHop() }
            rejoinStarted.await()
            val second = async { controller.endInternetHop() }
            assertTrue(controller.isInternetHopActive)
            allowRejoin.complete(Unit)

            assertTrue(first.await())
            assertTrue(second.await())
            assertEquals(1, hop.rejoinCalls)
            assertEquals(
                evidence,
                assertIs<FrameioInternetHopState.Rejoined>(controller.internetHopState).evidence,
            )
            assertFalse(controller.isInternetHopActive)
        }
    }

    @Test
    fun `concurrent failed rejoin callers share one attempt and failed result`() = runTest {
        withReadyRoot { readyRoot ->
            val reachability = MutableReachability(FrameioNetworkState.CAMERA_ACCESS_POINT)
            val rejoinStarted = CompletableDeferred<Unit>()
            val allowRejoin = CompletableDeferred<Unit>()
            val hop =
                FakeCameraHop(
                    onLeave = { reachability.value = FrameioNetworkState.ONLINE },
                    onRejoin = {
                        rejoinStarted.complete(Unit)
                        allowRejoin.await()
                        null
                    },
                )
            val controller = connectedController(readyRoot, reachability = reachability)
            controller.attachCameraHop(hop)

            assertTrue(controller.beginInternetHop())
            val first = async { controller.endInternetHop() }
            rejoinStarted.await()
            val second = async { controller.endInternetHop() }
            allowRejoin.complete(Unit)

            assertFalse(first.await())
            assertFalse(second.await())
            assertEquals(1, hop.rejoinCalls)
            assertIs<FrameioInternetHopState.Failed>(controller.internetHopState)
            assertFalse(controller.isInternetHopActive)
        }
    }

    @Test
    fun `internet timeout rejoins the camera and keeps the timeout truthful`() = runTest {
        val reachability = MutableReachability(FrameioNetworkState.CAMERA_ACCESS_POINT)
        val evidence = FrameioCameraRejoinEvidence("Nikon ZR", "ZR", 124_000L)
        val hop =
            FakeCameraHop(
                onLeave = { reachability.value = FrameioNetworkState.OFFLINE },
                onRejoin = {
                    reachability.value = FrameioNetworkState.CAMERA_ACCESS_POINT
                    evidence
                },
            )
        val controller =
            controller(
                reachability = reachability,
                internetWaitPoll = {},
                internetWaitAttempts = 2,
            )
        controller.attachCameraHop(hop)

        assertFalse(controller.beginInternetHop())

        assertEquals(1, hop.leaveCalls)
        assertEquals(1, hop.rejoinCalls)
        assertFalse(controller.isInternetHopActive)
        assertEquals(evidence, assertIs<FrameioInternetHopState.Rejoined>(controller.internetHopState).evidence)
        assertContains(controller.errorMessage.orEmpty(), "validated internet route")
    }

    @Test
    fun `cancelled internet wait still rejoins the camera`() = runTest {
        val reachability = MutableReachability(FrameioNetworkState.CAMERA_ACCESS_POINT)
        val hop =
            FakeCameraHop(
                onLeave = { reachability.value = FrameioNetworkState.OFFLINE },
                onRejoin = {
                    reachability.value = FrameioNetworkState.CAMERA_ACCESS_POINT
                    FrameioCameraRejoinEvidence("Nikon ZR", "ZR", 125_000L)
                },
            )
        val controller =
            controller(
                reachability = reachability,
                internetWaitPoll = { throw kotlinx.coroutines.CancellationException("unit cancel") },
            )
        controller.attachCameraHop(hop)

        assertFailsWith<kotlinx.coroutines.CancellationException> { controller.beginInternetHop() }

        assertEquals(1, hop.leaveCalls)
        assertEquals(1, hop.rejoinCalls)
        assertFalse(controller.isInternetHopActive)
        assertIs<FrameioInternetHopState.Rejoined>(controller.internetHopState)
    }

    @Test
    fun `upload success does not claim a camera rejoin when evidence is absent`() = runTest {
        withReadyRoot { readyRoot ->
            val source = readyRoot.resolve("C0007.MOV")
            Files.write(source, byteArrayOf(1, 2, 3, 4))
            val reachability = MutableReachability(FrameioNetworkState.CAMERA_ACCESS_POINT)
            val hop =
                FakeCameraHop(
                    onLeave = { reachability.value = FrameioNetworkState.ONLINE },
                    onRejoin = { null },
                )
            val controller = connectedController(readyRoot, reachability = reachability)
            controller.attachCameraHop(hop)

            assertTrue(controller.beginInternetHop())
            controller.deliver(listOf(FrameioDeliveryArtifact(StagedMediaShare(source, "C0007.MOV", "video/*"), 4)))

            assertIs<FrameioDeliveryState.Completed>(controller.deliveryState)
            assertIs<FrameioInternetHopState.Failed>(controller.internetHopState)
            assertContains(controller.errorMessage.orEmpty(), "could not verify")
        }
    }

    @Test
    fun `fixture hop is unavailable and never releases a network`() = runTest {
        val controller =
            controller(
                reachability = FixedReachability(FrameioNetworkState.CAMERA_ACCESS_POINT),
            )
        val hop = FakeCameraHop(availability = FrameioHopAvailability.FIXTURE_UNAVAILABLE)
        controller.attachCameraHop(hop)

        assertFalse(controller.beginInternetHop())
        assertEquals(0, hop.leaveCalls)
        assertContains(controller.errorMessage.orEmpty(), "demo fixtures")
    }

    @Test
    fun `baked output is uploaded from its approved root and metadata failure stays nonfatal`() = runTest {
        withReadyRoot { readyRoot ->
            val source = readyRoot.resolve("C0008.MOV")
            Files.write(source, byteArrayOf(1, 2, 3, 4))
            val exportRoot = Files.createDirectories(readyRoot.resolve("exports"))
            val core = FakeCore(uploadPlanSize = 6)
            val http = FakeHttp()
            val preparer = FakeArtifactPreparer(exportRoot)
            val metadata = FailingMetadataWriter()
            val controller =
                connectedController(
                    readyRoot = readyRoot,
                    core = core,
                    http = http,
                    approvedUploadRoots = listOf(readyRoot, exportRoot),
                    artifactPreparer = preparer,
                    metadataSidecarWriter = metadata,
                )

            controller.deliver(
                listOf(FrameioDeliveryArtifact(StagedMediaShare(source, "C0008.MOV", "video/*"), 4)),
                FrameioDeliveryOptions(
                    bakeLut = true,
                    includeMetadata = true,
                    selectedLut =
                        com.opencapture.openzcine.FeedLutSelection.BuiltIn(
                            com.opencapture.openzcine.FeedLut.MONO,
                        ),
                ),
            )

            val completed = assertIs<FrameioDeliveryState.Completed>(controller.deliveryState)
            assertEquals(1, completed.uploadedCount)
            assertEquals(1, completed.metadataFailureCount)
            assertEquals(listOf("C0008.mp4"), core.createdNames)
            assertEquals(listOf(6L), core.createdSizes)
            assertEquals(1, metadata.calls)
            assertTrue(preparer.released)
            assertFalse(Files.exists(exportRoot.resolve("prepared.mp4")))
        }
    }

    @Test
    fun `confirmed upload remains successful when temporary export cleanup fails`() = runTest {
        withReadyRoot { readyRoot ->
            val source = readyRoot.resolve("C0009.MOV")
            Files.write(source, byteArrayOf(1, 2, 3, 4))
            val exportRoot = Files.createDirectories(readyRoot.resolve("exports"))
            val preparer = FakeArtifactPreparer(exportRoot, releaseFailure = true)
            val controller =
                connectedController(
                    readyRoot = readyRoot,
                    core = FakeCore(uploadPlanSize = 6),
                    approvedUploadRoots = listOf(readyRoot, exportRoot),
                    artifactPreparer = preparer,
                )

            controller.deliver(
                listOf(FrameioDeliveryArtifact(StagedMediaShare(source, "C0009.MOV", "video/*"), 4)),
            )

            val completed = assertIs<FrameioDeliveryState.Completed>(controller.deliveryState)
            assertEquals(1, completed.uploadedCount)
            assertEquals(0, completed.failedCount)
            assertEquals(1, completed.cleanupFailureCount)
            assertTrue(preparer.released)
        }
    }

    @Test
    fun `temporary cleanup failure cannot override upload cancellation`() = runTest {
        withReadyRoot { readyRoot ->
            val source = readyRoot.resolve("C0010.MOV")
            Files.write(source, byteArrayOf(1, 2, 3, 4))
            val exportRoot = Files.createDirectories(readyRoot.resolve("exports"))
            val preparer = FakeArtifactPreparer(exportRoot, releaseFailure = true)
            val controller =
                connectedController(
                    readyRoot = readyRoot,
                    core = FakeCore(uploadPlanSize = 6),
                    http =
                        FakeHttp(
                            uploadFailure = kotlinx.coroutines.CancellationException("unit cancel"),
                        ),
                    approvedUploadRoots = listOf(readyRoot, exportRoot),
                    artifactPreparer = preparer,
                )

            assertFailsWith<kotlinx.coroutines.CancellationException> {
                controller.deliver(
                    listOf(
                        FrameioDeliveryArtifact(
                            StagedMediaShare(source, "C0010.MOV", "video/*"),
                            4,
                        ),
                    ),
                )
            }

            assertIs<FrameioDeliveryState.Idle>(controller.deliveryState)
            assertTrue(preparer.released)
        }
    }

    @Test
    fun `confirmed upload persists and is skipped unless reupload is explicit`() = runTest {
        withReadyRoot { readyRoot ->
            val source = readyRoot.resolve("C0011.MOV")
            Files.write(source, byteArrayOf(1, 2, 3, 4))
            val history = MemoryUploadHistory()
            val http = FakeHttp()
            val controller =
                connectedController(
                    readyRoot = readyRoot,
                    http = http,
                    uploadHistory = history,
                )
            val artifact =
                FrameioDeliveryArtifact(
                    StagedMediaShare(source, "C0011.MOV", "video/quicktime"),
                    4,
                    FrameioArtifactContext("camera", "20260715T120000", true, "clip-11"),
                )

            controller.deliver(listOf(artifact))
            assertEquals(1, assertIs<FrameioDeliveryState.Completed>(controller.deliveryState).uploadedCount)
            assertTrue(history.wasUploaded("clip-11"))
            assertEquals(1, http.uploadCalls)

            controller.deliver(listOf(artifact))
            val skipped = assertIs<FrameioDeliveryState.Completed>(controller.deliveryState)
            assertEquals(0, skipped.uploadedCount)
            assertEquals(1, skipped.skippedCount)
            assertEquals(0, skipped.failedCount)
            assertEquals(1, http.uploadCalls)

            controller.deliver(
                listOf(artifact),
                MediaDeliveryConfiguration(forceFrameioReupload = true),
            )
            val repeated = assertIs<FrameioDeliveryState.Completed>(controller.deliveryState)
            assertEquals(1, repeated.uploadedCount)
            assertEquals(0, repeated.skippedCount)
            assertEquals(2, http.uploadCalls)
        }
    }

    @Test
    fun `mixed batch reports uploaded skipped and failed clips exactly`() = runTest {
        withReadyRoot { readyRoot ->
            val sources =
                (1..3).map { index ->
                    readyRoot.resolve("BATCH$index.MOV").also { path ->
                        Files.write(path, byteArrayOf(1, 2, 3, 4))
                    }
                }
            val history = MemoryUploadHistory(setOf("already-uploaded"))
            val http = FakeHttp(failUploadCalls = setOf(2))
            val controller =
                connectedController(
                    readyRoot = readyRoot,
                    http = http,
                    uploadHistory = history,
                )
            val identities = listOf("already-uploaded", "new-success", "new-failure")
            val artifacts =
                sources.mapIndexed { index, path ->
                    FrameioDeliveryArtifact(
                        StagedMediaShare(path, path.fileName.toString(), "video/quicktime"),
                        4,
                        FrameioArtifactContext("camera", "", true, identities[index]),
                    )
                }

            controller.deliver(artifacts)

            val completed = assertIs<FrameioDeliveryState.Completed>(controller.deliveryState)
            assertEquals(1, completed.uploadedCount)
            assertEquals(1, completed.skippedCount)
            assertEquals(1, completed.failedCount)
            assertTrue(history.wasUploaded("already-uploaded"))
            assertTrue(history.wasUploaded("new-success"))
            assertFalse(history.wasUploaded("new-failure"))
        }
    }

    @Test
    fun `private history failures never duplicate or reclassify a confirmed upload`() = runTest {
        withReadyRoot { readyRoot ->
            val source = readyRoot.resolve("HISTORY.MOV")
            Files.write(source, byteArrayOf(1, 2, 3, 4))
            val artifact =
                FrameioDeliveryArtifact(
                    StagedMediaShare(source, "HISTORY.MOV", "video/quicktime"),
                    4,
                    FrameioArtifactContext("camera", "", true, "history-clip"),
                )

            val readHttp = FakeHttp()
            val readFailure =
                connectedController(
                    readyRoot = readyRoot,
                    http = readHttp,
                    uploadHistory = ThrowingUploadHistory(failRead = true),
                )
            readFailure.deliver(listOf(artifact))
            val unreadable = assertIs<FrameioDeliveryState.Completed>(readFailure.deliveryState)
            assertEquals(0, unreadable.uploadedCount)
            assertEquals(1, unreadable.failedCount)
            assertEquals(1, unreadable.historyFailureCount)
            assertEquals(0, readHttp.uploadCalls)

            val writeHttp = FakeHttp()
            val writeFailure =
                connectedController(
                    readyRoot = readyRoot,
                    http = writeHttp,
                    uploadHistory = ThrowingUploadHistory(failWrite = true),
                )
            writeFailure.deliver(listOf(artifact))
            val unrecorded = assertIs<FrameioDeliveryState.Completed>(writeFailure.deliveryState)
            assertEquals(1, unrecorded.uploadedCount)
            assertEquals(0, unrecorded.failedCount)
            assertEquals(1, unrecorded.historyFailureCount)
            assertEquals(1, writeHttp.uploadCalls)
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

    private class SequencedReachability(values: List<FrameioNetworkState>) : FrameioReachability {
        private val values = values.iterator()
        private var last = FrameioNetworkState.OFFLINE

        override fun state(): FrameioNetworkState {
            if (values.hasNext()) last = values.next()
            return last
        }
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

    private class MemoryUploadHistory(initial: Set<String> = emptySet()) :
        FrameioUploadHistoryStore {
        private val identities = initial.toMutableSet()

        override fun wasUploaded(stableClipIdentity: String): Boolean =
            stableClipIdentity in identities

        override fun recordUploaded(stableClipIdentity: String): Boolean {
            identities += stableClipIdentity
            return true
        }
    }

    private class ThrowingUploadHistory(
        private val failRead: Boolean = false,
        private val failWrite: Boolean = false,
    ) : FrameioUploadHistoryStore {
        override fun wasUploaded(stableClipIdentity: String): Boolean {
            if (failRead) throw java.io.IOException("unit history read failure")
            return false
        }

        override fun recordUploaded(stableClipIdentity: String): Boolean {
            if (failWrite) throw java.io.IOException("unit history write failure")
            return true
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

    private class MutableReachability(var value: FrameioNetworkState) : FrameioReachability {
        override fun state(): FrameioNetworkState = value
    }

    private class FakeCameraHop(
        override val availability: FrameioHopAvailability = FrameioHopAvailability.READY,
        private val onLeave: suspend () -> Unit = {},
        private val onRejoin: suspend () -> FrameioCameraRejoinEvidence? = {
            FrameioCameraRejoinEvidence("Nikon ZR", "ZR", 123_000L)
        },
    ) : FrameioCameraHop {
        var leaveCalls = 0
        var rejoinCalls = 0

        override suspend fun leaveCameraNetwork(): Boolean {
            leaveCalls += 1
            onLeave()
            return true
        }

        override suspend fun rejoinCameraNetwork(): FrameioCameraRejoinEvidence? {
            rejoinCalls += 1
            return onRejoin()
        }
    }

    private class FakeArtifactPreparer(
        private val exportRoot: Path,
        private val releaseFailure: Boolean = false,
    ) : FrameioArtifactPreparer {
        var released = false

        override suspend fun prepare(
            artifact: FrameioDeliveryArtifact,
            options: FrameioDeliveryOptions,
            onProgress: suspend (Double) -> Unit,
        ): FrameioPreparedArtifact {
            val target = exportRoot.resolve("prepared.mp4")
            Files.write(target, byteArrayOf(1, 2, 3, 4, 5, 6))
            onProgress(1.0)
            return FrameioPreparedArtifact(
                StagedMediaShare(target, "C0008.mp4", "video/mp4"),
                6,
                "MONO",
                target,
            )
        }

        override suspend fun release(prepared: FrameioPreparedArtifact) {
            released = true
            if (releaseFailure) throw java.io.IOException("unit cleanup failure")
            prepared.transientExport?.let(Files::deleteIfExists)
        }
    }

    private class FailingMetadataWriter : FrameioMetadataSidecarWriter {
        var calls = 0

        override suspend fun recordSuccessfulDelivery(
            artifact: FrameioDeliveryArtifact,
            prepared: FrameioPreparedArtifact,
            destination: FrameioDestination,
            options: FrameioDeliveryOptions,
        ) {
            calls += 1
            throw java.io.IOException("unit metadata failure")
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
