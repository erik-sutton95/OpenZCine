package com.opencapture.openzcine

import com.opencapture.openzcine.core.CameraIdentity
import com.opencapture.openzcine.core.CameraRecordingState
import com.opencapture.openzcine.core.CameraSession
import com.opencapture.openzcine.core.CameraSessionState
import com.opencapture.openzcine.core.StillReleasePoll
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertTrue
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.test.advanceUntilIdle
import kotlinx.coroutines.test.runTest

/** JVM coverage for the press-tracked still-release sequencing. */
class StillCaptureControllerTest {
    private class FakeSession : CameraSession {
        override val state: StateFlow<CameraSessionState> =
            MutableStateFlow(
                CameraSessionState.Connected(
                    CameraIdentity(name = "ZR", model = "ZR", serialNumber = "1"),
                ),
            )
        override val recordingState: StateFlow<CameraRecordingState> =
            MutableStateFlow(CameraRecordingState.STANDBY)

        var initiates = 0
        var terminates = 0
        var bracketCalls = mutableListOf<Boolean>()
        var refreshes = 0
        var polls: ArrayDeque<StillReleasePoll> = ArrayDeque()
        var failInitiate = false
        var failBracket = false
        var refreshDelayMillis = 0L

        override suspend fun connect() = Unit

        override suspend fun setRecording(recording: Boolean) = Unit

        override suspend fun disconnect() = Unit

        override suspend fun initiateStillCapture() {
            if (failInitiate) {
                throw com.opencapture.openzcine.core.CameraControlException.CommandRejected
            }
            initiates += 1
        }

        override suspend fun pollStillRelease(): StillReleasePoll =
            polls.removeFirstOrNull() ?: StillReleasePoll.COMPLETE

        override suspend fun terminateStillCapture() {
            terminates += 1
        }

        override suspend fun setStillBurstBracket(active: Boolean) {
            if (failBracket) {
                throw com.opencapture.openzcine.core.CameraControlException.CommandRejected
            }
            bracketCalls += active
        }

        override suspend fun refreshProperties() {
            if (refreshDelayMillis > 0) kotlinx.coroutines.delay(refreshDelayMillis)
            refreshes += 1
        }
    }

    @Test
    fun `single release fires once and never terminates on finger-up`() = runTest {
        val session = FakeSession()
        val controller = StillCaptureController(session, pollDelayMillis = 1)
        session.polls.addAll(listOf(StillReleasePoll.IN_PROGRESS, StillReleasePoll.COMPLETE))

        controller.pressed(this, continuousDrive = false)
        controller.released(this)
        advanceUntilIdle()

        assertEquals(1, session.initiates)
        assertEquals(0, session.terminates)
        assertTrue(session.bracketCalls.isEmpty())
        assertEquals(1, session.refreshes)
        assertFalse(controller.isCapturing.value)
    }

    @Test
    fun `held continuous drive chains releases inside the remote-mode bracket`() = runTest {
        val session = FakeSession()
        val controller = StillCaptureController(session, pollDelayMillis = 1)
        // Two chained completions while held, then the finger lifts.
        session.polls.addAll(
            listOf(StillReleasePoll.COMPLETE, StillReleasePoll.COMPLETE),
        )

        controller.pressed(this, continuousDrive = true)
        advanceUntilIdle()

        // Chained twice (initial + 2 completions while held), bracket opened
        // then closed, and a quiet terminate never fired (the run ended by cap
        // or queue drain).
        assertTrue(session.initiates >= 2)
        assertEquals(listOf(true, false), session.bracketCalls)
        assertFalse(controller.isCapturing.value)
    }

    @Test
    fun `release before completion stops the chain and terminates the run`() = runTest {
        val session = FakeSession()
        val controller = StillCaptureController(session, pollDelayMillis = 50)
        session.polls.addAll(
            listOf(
                StillReleasePoll.IN_PROGRESS,
                StillReleasePoll.IN_PROGRESS,
                StillReleasePoll.COMPLETE,
            ),
        )

        controller.pressed(this, continuousDrive = true)
        testScheduler.advanceTimeBy(60)
        controller.released(this)
        advanceUntilIdle()

        // Terminate was sent for the in-flight run; no second initiate chained.
        assertEquals(1, session.initiates)
        assertEquals(1, session.terminates)
        assertEquals(listOf(true, false), session.bracketCalls)
    }

    @Test
    fun `timer chain fires the next shot while the previous run's refresh drags`() = runTest {
        val session = FakeSession()
        // The post-run property refresh takes seconds on a real body — it must
        // never swallow the timer chain's next press (the on-device once-and-
        // stop bug).
        session.refreshDelayMillis = 5_000
        val controller = StillCaptureController(session, pollDelayMillis = 1)
        session.polls.addAll(listOf(StillReleasePoll.COMPLETE, StillReleasePoll.COMPLETE))

        controller.pressed(this, continuousDrive = false)
        // The fireTimerShots wait loop: poll capturing every 150 ms.
        while (controller.isCapturing.value) testScheduler.advanceTimeBy(150)
        controller.pressed(this, continuousDrive = false)
        advanceUntilIdle()

        assertEquals(2, session.initiates)
        assertFalse(controller.isCapturing.value)
    }

    @Test
    fun `failed initiate closes the bracket and clears capturing`() = runTest {
        val session = FakeSession()
        session.failInitiate = true
        val controller = StillCaptureController(session, pollDelayMillis = 1)

        controller.pressed(this, continuousDrive = true)
        advanceUntilIdle()

        assertEquals(listOf(true, false), session.bracketCalls)
        assertFalse(controller.isCapturing.value)
    }

    @Test
    fun `a refused release surfaces a reason and never latches the press gate`() = runTest {
        val session = FakeSession()
        session.failInitiate = true
        val controller = StillCaptureController(session, pollDelayMillis = 1)
        val failures = mutableListOf<String>()
        controller.onFailure = { failures += it }

        controller.pressed(this, continuousDrive = false)
        advanceUntilIdle()

        // The refusal explained itself and reset every gate.
        assertEquals(1, failures.size)
        assertFalse(controller.isCapturing.value)

        // The NEXT press must fire — a failed release can never leave the
        // shutter dead (the on-device silent-no-op regression).
        session.failInitiate = false
        session.polls.add(StillReleasePoll.COMPLETE)
        controller.pressed(this, continuousDrive = false)
        advanceUntilIdle()
        assertEquals(1, session.initiates)
        assertFalse(controller.isCapturing.value)
    }

    @Test
    fun `a refused bracket still fires the release without a failure toast`() = runTest {
        val session = FakeSession()
        session.failBracket = true
        val controller = StillCaptureController(session, pollDelayMillis = 1)
        val failures = mutableListOf<String>()
        controller.onFailure = { failures += it }
        session.polls.add(StillReleasePoll.COMPLETE)

        controller.pressed(this, continuousDrive = true)
        controller.released(this)
        advanceUntilIdle()

        // The best-effort bracket is quiet; the plain release still fired.
        assertEquals(1, session.initiates)
        assertTrue(failures.isEmpty())
        assertFalse(controller.isCapturing.value)
    }

    @Test
    fun `a failed release poll surfaces a reason for a plain press`() = runTest {
        val session = FakeSession()
        val controller = StillCaptureController(session, pollDelayMillis = 1)
        val failures = mutableListOf<String>()
        controller.onFailure = { failures += it }
        session.polls.add(StillReleasePoll.FAILED)

        controller.pressed(this, continuousDrive = false)
        advanceUntilIdle()

        assertEquals(1, failures.size)
        assertFalse(controller.isCapturing.value)
    }
}
