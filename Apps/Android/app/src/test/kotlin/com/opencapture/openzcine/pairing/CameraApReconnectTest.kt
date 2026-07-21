package com.opencapture.openzcine.pairing

import kotlin.test.Test
import kotlin.test.assertFalse
import kotlin.test.assertTrue
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.async
import kotlinx.coroutines.delay
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withTimeout

@OptIn(ExperimentalCoroutinesApi::class)
class CameraApReconnectTest {
    @Test
    fun `probe fails closed for an unroutable host`() {
        assertFalse(probePtpIpReachable(host = "127.0.0.1", port = 1, timeoutMillis = 50))
    }

    @Test
    fun `awaitCameraApReady returns true when reassociation succeeds`() =
        runBlocking {
            val ok =
                withTimeout(5_000) {
                    awaitCameraApReadyAfterConfirm(
                        awaitReassociation = {
                            delay(50)
                            true
                        },
                        isProcessBound = { false },
                        host = "127.0.0.1",
                        timeoutMillis = 3_000,
                    )
                }
            assertTrue(ok)
        }

    @Test
    fun `awaitCameraApReady returns false when both paths fail`() =
        runBlocking {
            val ok =
                awaitCameraApReadyAfterConfirm(
                    awaitReassociation = {
                        delay(30)
                        false
                    },
                    isProcessBound = { false },
                    host = "127.0.0.1",
                    timeoutMillis = 200,
                )
            assertFalse(ok)
        }

    @Test
    fun `reconnect times out cleanly when PTP port never opens`() =
        runBlocking {
            val ok =
                reconnectCameraApAfterConfirm(
                    rejoinSsid = "NIKON_ZR_TEST",
                    rejoinKey = "key",
                    isProcessBound = { false },
                    ensureJoined = { _, _, _ -> true },
                    forceJoin = { _, _, _ -> true },
                    connectSavedProfile = { true },
                    onPhaseReconnecting = {},
                    alwaysForceJoinFirst = true,
                    timeoutMillis = 400,
                )
            assertFalse(ok)
        }

    @Test
    fun `reconnect force-joins first when alwaysForceJoinFirst is set`() =
        runBlocking {
            var forceJoins = 0
            reconnectCameraApAfterConfirm(
                rejoinSsid = "NIKON_ZR_TEST",
                rejoinKey = "key",
                isProcessBound = { forceJoins > 0 },
                ensureJoined = { _, _, _ -> false },
                forceJoin = { _, _, _ ->
                    forceJoins += 1
                    true
                },
                connectSavedProfile = { false },
                onPhaseReconnecting = {},
                alwaysForceJoinFirst = true,
                timeoutMillis = 800,
            )
            assertTrue(forceJoins >= 1)
        }
}
