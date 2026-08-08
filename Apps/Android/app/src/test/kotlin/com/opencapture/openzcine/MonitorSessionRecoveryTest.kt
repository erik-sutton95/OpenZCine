package com.opencapture.openzcine

import com.opencapture.openzcine.core.CameraIdentity
import com.opencapture.openzcine.core.CameraPropertySnapshot
import com.opencapture.openzcine.core.CameraRecordingState
import com.opencapture.openzcine.core.CameraSession
import com.opencapture.openzcine.core.CameraSessionState
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
    /**
     * Stand-in for the Swift core's `SessionRecoveryPolicy`: doubling from
     * [base] and stopping once [budget] attempts have failed. Keeps the
     * sequencing under test without a JNI hop.
     */
    private class FakeSchedule(
        private val base: Long = 100L,
        private val budget: Int = 8,
        private val pauseAfterDrops: Int = Int.MAX_VALUE,
    ) : SessionRetryScheduleBridge {
        var dropsNoted = 0
            private set

        override fun retryDelayMillis(failures: Int, jitter: Double): Long? =
            if (failures >= budget) null else base shl failures

        override fun maxAutomaticAttempts(): Int = budget

        override fun noteSessionDrop(): Boolean {
            dropsNoted += 1
            return dropsNoted >= pauseAfterDrops
        }

        override fun dropsInStormWindow(): Int = dropsNoted

        override fun resetDropStormGuard() {
            dropsNoted = 0
        }
    }

    @Test
    fun `initial connection is immediate and failed attempts back off`() = runTest {
        val session = RecoverySession(false, false, true)
        val sleeps = mutableListOf<Long>()
        val coordinator =
            MonitorSessionRecoveryCoordinator(
                session = session,
                schedule = FakeSchedule(),
                jitterSample = { 1.0 },
                sleep = sleeps::add,
            )

        backgroundScope.launch { coordinator.run() }
        runCurrent()

        assertEquals(3, session.connectCount)
        assertEquals(listOf(100L, 200L), sleeps)
        assertEquals(300L, session.cameraProperties.value.iso)
        assertEquals(CameraRecordingState.RECORDING, session.recordingState.value)
        assertEquals(MonitorRecoveryState.Idle, coordinator.recoveryState.value)
    }

    @Test
    fun `connected state resets recovery attempts before a later channel loss`() = runTest {
        val session = RecoverySession(true, false, true, true)
        val sleeps = mutableListOf<Long>()
        val coordinator =
            MonitorSessionRecoveryCoordinator(
                session = session,
                schedule = FakeSchedule(),
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
                schedule = FakeSchedule(base = 1_000L),
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
                schedule = FakeSchedule(base = 1_000L),
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

    @Test
    fun `automatic retries are bounded and hand the decision to the operator`() = runTest {
        // Every attempt fails; a two-attempt budget must stop, not loop forever behind a static
        // "No camera" (the pre-fix Android behaviour).
        val session = RecoverySession(false, false, false, false, false)
        val coordinator =
            MonitorSessionRecoveryCoordinator(
                session = session,
                schedule = FakeSchedule(budget = 2),
                jitterSample = { 1.0 },
                sleep = {},
            )

        backgroundScope.launch { coordinator.run() }
        runCurrent()

        // One initial connect plus the two budgeted retries, then stop.
        assertEquals(3, session.connectCount)
        assertEquals(
            MonitorRecoveryState.WaitingForOperator(attemptsMade = 2),
            coordinator.recoveryState.value,
        )
    }

    @Test
    fun `clustered drops of a healthy-reconnecting session pause for the operator`() = runTest {
        // Every reconnect SUCCEEDS, so the per-run failure budget never fires — that is the
        // storm signature. Only the shared drop-storm ledger can stop the reconnect churn
        // that wedges the body into a battery pull.
        val session = RecoverySession(true, true, true)
        val coordinator =
            MonitorSessionRecoveryCoordinator(
                session = session,
                schedule = FakeSchedule(pauseAfterDrops = 3),
                jitterSample = { 1.0 },
                sleep = {},
            )
        backgroundScope.launch { coordinator.run() }
        runCurrent()
        assertEquals(1, session.connectCount)

        session.loseConnection()
        runCurrent()
        session.loseConnection()
        runCurrent()
        assertEquals(3, session.connectCount)

        session.loseConnection()
        runCurrent()

        // The third clustered drop pauses: no further connect, the operator holds the decision.
        assertEquals(3, session.connectCount)
        assertEquals(
            MonitorRecoveryState.PausedAfterRepeatedDrops(drops = 3),
            coordinator.recoveryState.value,
        )
    }

    @Test
    fun `the published state counts attempts truthfully while retrying`() = runTest {
        val session = RecoverySession(false, false)
        val statesDuringBackoff = mutableListOf<MonitorRecoveryState>()
        lateinit var coordinator: MonitorSessionRecoveryCoordinator
        coordinator =
            MonitorSessionRecoveryCoordinator(
                session = session,
                schedule = FakeSchedule(budget = 4),
                jitterSample = { 1.0 },
                sleep = { statesDuringBackoff.add(coordinator.recoveryState.value) },
            )
        val runner = backgroundScope.launch { coordinator.run() }
        runCurrent()
        runner.cancelAndJoin()

        assertEquals(
            listOf<MonitorRecoveryState>(
                MonitorRecoveryState.Retrying(attempt = 1, maxAttempts = 4),
                MonitorRecoveryState.Retrying(attempt = 2, maxAttempts = 4),
            ),
            statesDuringBackoff,
        )
        assertEquals(MonitorRecoveryState.Idle, coordinator.recoveryState.value)
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
