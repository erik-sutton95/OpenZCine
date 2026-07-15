package com.opencapture.openzcine

import com.opencapture.openzcine.core.CameraIdentity
import com.opencapture.openzcine.core.CameraPropertySnapshot
import com.opencapture.openzcine.core.CameraRecordingState
import com.opencapture.openzcine.core.CameraSession
import com.opencapture.openzcine.core.CameraSessionState
import com.opencapture.openzcine.transport.ReconnectBackoff
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.cancelAndJoin
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.launch
import kotlinx.coroutines.test.advanceTimeBy
import kotlinx.coroutines.test.runCurrent
import kotlinx.coroutines.test.runTest

@OptIn(ExperimentalCoroutinesApi::class)
class MonitorSessionRecoveryTest {
    @Test
    fun `monitor retry policy starts at half a second and caps at eight seconds`() {
        val policy = defaultMonitorSessionRetryPolicy()

        assertEquals(500L, policy.delayMillis(attempt = 0, jitter = 0.5))
        assertEquals(8_000L, policy.delayMillis(attempt = 99, jitter = 0.5))
    }

    @Test
    fun `initial connection is immediate and failed attempts back off`() = runTest {
        val session = RecoverySession(false, false, true)
        val sleeps = mutableListOf<Long>()
        val coordinator =
            MonitorSessionRecoveryCoordinator(
                session = session,
                retryPolicy = ReconnectBackoff(100L, 800L, jitterFraction = 0.0),
                jitterSample = { 1.0 },
                sleep = sleeps::add,
            )

        backgroundScope.launch { coordinator.run() }
        runCurrent()

        assertEquals(3, session.connectCount)
        assertEquals(listOf(100L, 200L), sleeps)
        assertEquals(300L, session.cameraProperties.value.iso)
        assertEquals(CameraRecordingState.RECORDING, session.recordingState.value)
    }

    @Test
    fun `connected state resets recovery attempts before a later channel loss`() = runTest {
        val session = RecoverySession(true, false, true, true)
        val sleeps = mutableListOf<Long>()
        val coordinator =
            MonitorSessionRecoveryCoordinator(
                session = session,
                retryPolicy = ReconnectBackoff(100L, 800L, jitterFraction = 0.0),
                jitterSample = { 1.0 },
                sleep = sleeps::add,
            )
        backgroundScope.launch { coordinator.run() }
        runCurrent()

        session.loseConnection()
        runCurrent()
        session.loseConnection()
        runCurrent()

        assertEquals(4, session.connectCount)
        assertEquals(listOf(100L, 200L, 100L), sleeps)
    }

    @Test
    fun `cancelling the monitor owner cancels a pending retry`() = runTest {
        val session = RecoverySession(false, true)
        val coordinator =
            MonitorSessionRecoveryCoordinator(
                session = session,
                retryPolicy = ReconnectBackoff(1_000L, 1_000L, jitterFraction = 0.0),
                jitterSample = { 1.0 },
            )
        val recovery = backgroundScope.launch { coordinator.run() }
        runCurrent()
        assertEquals(1, session.connectCount)

        recovery.cancelAndJoin()
        advanceTimeBy(2_000L)
        runCurrent()

        assertEquals(1, session.connectCount)
    }

    @Test
    fun `an external connection during backoff prevents a duplicate connect`() = runTest {
        val session = RecoverySession(false, true)
        val coordinator =
            MonitorSessionRecoveryCoordinator(
                session = session,
                retryPolicy = ReconnectBackoff(1_000L, 1_000L, jitterFraction = 0.0),
                jitterSample = { 1.0 },
            )
        backgroundScope.launch { coordinator.run() }
        runCurrent()
        assertEquals(1, session.connectCount)

        session.restoreConnection()
        advanceTimeBy(1_000L)
        runCurrent()

        assertEquals(1, session.connectCount)
    }

    private class RecoverySession(vararg outcomes: Boolean) : CameraSession {
        private val remainingOutcomes = ArrayDeque(outcomes.toList())
        private val mutableState =
            MutableStateFlow<CameraSessionState>(CameraSessionState.Disconnected)
        private val mutableRecordingState = MutableStateFlow(CameraRecordingState.STANDBY)
        private val mutableCameraProperties = MutableStateFlow(CameraPropertySnapshot())

        override val state: StateFlow<CameraSessionState> = mutableState
        override val recordingState: StateFlow<CameraRecordingState> = mutableRecordingState
        override val cameraProperties: StateFlow<CameraPropertySnapshot> = mutableCameraProperties

        var connectCount: Int = 0
            private set

        override suspend fun connect() {
            connectCount += 1
            mutableState.value = CameraSessionState.Connecting
            if (remainingOutcomes.removeFirstOrNull() == false) {
                clearReadback()
                mutableState.value = CameraSessionState.Disconnected
                return
            }
            mutableCameraProperties.value = CameraPropertySnapshot(iso = connectCount * 100L)
            mutableRecordingState.value =
                if (connectCount >= 3) {
                    CameraRecordingState.RECORDING
                } else {
                    CameraRecordingState.STANDBY
                }
            mutableState.value = connectedState()
        }

        override suspend fun setRecording(recording: Boolean) = Unit

        override suspend fun disconnect() {
            loseConnection()
        }

        fun loseConnection() {
            clearReadback()
            mutableState.value = CameraSessionState.Disconnected
        }

        fun restoreConnection() {
            mutableState.value = connectedState()
        }

        private fun clearReadback() {
            mutableCameraProperties.value = CameraPropertySnapshot()
            mutableRecordingState.value = CameraRecordingState.STANDBY
        }

        private fun connectedState(): CameraSessionState.Connected =
            CameraSessionState.Connected(
                CameraIdentity("Recovery camera", "NIKON ZR", "RECOVERY-TEST"),
            )
    }
}
