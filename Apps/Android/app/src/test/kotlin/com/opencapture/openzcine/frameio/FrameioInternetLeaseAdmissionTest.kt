package com.opencapture.openzcine.frameio

import java.nio.file.Path
import kotlin.io.path.createTempDirectory
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNotNull
import kotlin.test.assertNull
import kotlin.test.assertTrue
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.async
import kotlinx.coroutines.test.runCurrent
import kotlinx.coroutines.test.runTest

/** SIMULATED native route ports exercise the actual controller owner and rejoin mutex. */
@OptIn(ExperimentalCoroutinesApi::class)
class FrameioInternetLeaseAdmissionTest {
    @Test fun currentCapturedRouteLeavesAndRestoresItsOriginalProfileOnce() = runTest {
        withController { controller, network ->
            val hop = Hop(network, "A"); controller.attachCameraHop(hop)
            val lease = assertNotNull(controller.claimInternetHop { true })
            assertTrue(controller.waitInternetHop(lease))
            assertTrue(controller.endInternetHop(lease))
            assertFalse(controller.endInternetHop(lease))
            assertEquals(1, hop.leaves); assertEquals(1, hop.joins)
            assertFalse(controller.isInternetHopActive)
        }
    }
    @Test fun lateOldWaitCannotLeaveOrReleaseTheSuccessorRoute() = runTest {
        withController { controller, network ->
            val a = Hop(network, "A"); controller.attachCameraHop(a)
            val old = assertNotNull(controller.claimInternetHop { true })
            assertFalse(controller.endInternetHop(old))
            val b = Hop(network, "B"); controller.attachCameraHop(b)
            val next = assertNotNull(controller.claimInternetHop { true })
            assertFalse(controller.waitInternetHop(old)); assertFalse(controller.endInternetHop(old))
            assertTrue(controller.waitInternetHop(next)); assertTrue(controller.ownsInternetHop(next))
            assertEquals(0, a.leaves); assertEquals(0, a.joins)
            assertTrue(controller.endInternetHop(next)); assertEquals(1, b.joins)
        }
    }
    @Test fun sourceRevokedBeforeDispatchRefusesUnsentNativeLeave() = runTest {
        withController { controller, network ->
            var current = true; val hop = Hop(network, "A"); controller.attachCameraHop(hop)
            val lease = assertNotNull(controller.claimInternetHop { current })
            current = false
            assertFalse(controller.waitInternetHop(lease))
            assertFalse(controller.ownsInternetHop(lease))
            assertEquals(0, hop.leaves); assertEquals(0, hop.joins)
        }
    }
    @Test fun popupTransferKeepsOnlyTheOriginalNativeReturnFacts() = runTest {
        withController { controller, network ->
            val a = Hop(network, "A"); controller.attachCameraHop(a)
            val popup = assertNotNull(controller.claimInternetHop { true })
            assertTrue(controller.waitInternetHop(popup))
            val delivery = assertNotNull(controller.transferInternetHop(popup))
            val b = Hop(network, "B"); controller.attachCameraHop(b)
            assertFalse(controller.ownsInternetHop(popup)); assertTrue(controller.ownsInternetHop(delivery))
            assertFalse(controller.endInternetHop(popup)); assertTrue(controller.endInternetHop(delivery))
            assertEquals(1, a.joins); assertEquals(0, b.leaves); assertEquals(0, b.joins)
        }
    }
    @Test fun nativeOwnerReplacementDuringAdmissionRefusesBeforeLeave() = runTest {
        withController { controller, network ->
            val a = Hop(network, "A"); val b = Hop(network, "B")
            controller.attachCameraHop(a)
            assertNull(controller.claimInternetHop { controller.attachCameraHop(b); true })
            assertEquals(0, a.leaves); assertEquals(0, b.leaves)
            val current = assertNotNull(controller.claimInternetHop { true })
            assertTrue(controller.waitInternetHop(current)); assertTrue(controller.endInternetHop(current))
            assertEquals(1, b.leaves); assertEquals(1, b.joins)
        }
    }
    @Test fun enteredLeaveCleanupJoinsOnlyItsOriginalNativeTransaction() = runTest {
        withController { controller, network ->
            val entered = CompletableDeferred<Unit>(); val release = CompletableDeferred<Unit>()
            val hop = Hop(network, "A", beforeLeave = { entered.complete(Unit); release.await() })
            controller.attachCameraHop(hop)
            val lease = assertNotNull(controller.claimInternetHop { true })
            val leaving = async { controller.waitInternetHop(lease) }; entered.await()
            val restore = async { controller.endInternetHop(lease) }; runCurrent()
            assertFalse(restore.isCompleted); assertEquals(0, hop.joins)
            release.complete(Unit)
            assertFalse(leaving.await()); assertTrue(restore.await())
            assertEquals(1, hop.leaves); assertEquals(1, hop.joins)
            assertFalse(controller.endInternetHop(lease))
        }
    }
    private class Network : FrameioReachability {
        var value = FrameioNetworkState.CAMERA_ACCESS_POINT
        override fun state() = value
    }
    private class Hop(private val network: Network, val name: String,
        val beforeLeave: suspend () -> Unit = {}) : FrameioCameraHop {
        override val availability = FrameioHopAvailability.READY
        var leaves = 0; var joins = 0
        override suspend fun leaveCameraNetwork(): Boolean {
            leaves++; beforeLeave(); network.value = FrameioNetworkState.ONLINE; return true
        }
        override suspend fun rejoinCameraNetwork(): FrameioCameraRejoinEvidence {
            joins++; network.value = FrameioNetworkState.CAMERA_ACCESS_POINT
            return FrameioCameraRejoinEvidence(name, "SIMULATED", 7)
        }
    }
    private suspend fun withController(operation: suspend (FrameioDeliveryController, Network) -> Unit) {
        val root = createTempDirectory("SIMULATED-native-route")
        val network = Network()
        val secrets = object : FrameioSecretStore {
            override fun load() = FrameioSecretState(null, null)
            override fun saveToken(token: FrameioStoredToken) = error("No account I/O")
            override fun clearToken() = Unit
            override fun savePendingAuthorization(pending: FrameioPendingAuthorization) = error("No account I/O")
            override fun clearPendingAuthorization() = Unit
            override fun clearAll() = Unit
        }
        val destinations = object : FrameioDestinationStore {
            override fun load(): FrameioDestination? = null
            override fun save(destination: FrameioDestination) = error("No account I/O")
            override fun clear() = Unit
        }
        val http = object : FrameioHttpClient {
            override suspend fun execute(request: FrameioHttpRequest, bearerToken: String?, contentType: String?): FrameioHttpResponse = error("No network I/O")
            override suspend fun putUploadPart(uploadURL: String, source: Path, offset: Long, byteCount: Long,
                contentType: String, onBytesSent: suspend (Long) -> Unit): FrameioHttpResponse = error("No network I/O")
        }
        try { operation(FrameioDeliveryController({ null }, SwiftFrameioCoreBridge, http, secrets,
            destinations, network, root, uiDispatcher = Dispatchers.Unconfined,
            internetWaitPoll = {}, internetWaitAttempts = 2), network) }
        finally { root.toFile().deleteRecursively() }
    }
}
