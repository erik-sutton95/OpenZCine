package com.opencapture.openzcine

import com.opencapture.opencine.nikon.CameraIdentity
import com.opencapture.opencine.nikon.CameraRecordingState
import com.opencapture.opencine.nikon.CameraSession
import com.opencapture.opencine.nikon.CameraSessionState
import com.opencapture.opencine.nikon.StillReleasePoll
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertTrue
import kotlinx.coroutines.Job
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.plus
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.test.advanceUntilIdle
import kotlinx.coroutines.test.runTest
import com.opencapture.opencine.nikon.CameraControlException

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
        var lastPreserveFocus: Boolean? = null
        var terminates = 0
        var bracketCalls = mutableListOf<Boolean>()
        var refreshes = 0
        var polls: ArrayDeque<StillReleasePoll> = ArrayDeque()
        var failInitiate = false
        var failFromInitiate = Int.MAX_VALUE
        var failBracket = false
        var refreshDelayMillis = 0L

        override suspend fun connect() = Unit

        override suspend fun setRecording(recording: Boolean) = Unit

        override suspend fun disconnect() = Unit

        override suspend fun initiateStillCapture(preserveFocus: Boolean) {
            if (failInitiate || initiates >= failFromInitiate) {
                throw CameraControlException.CommandRejected
            }
            initiates += 1
            lastPreserveFocus = preserveFocus
        }

        override suspend fun pollStillRelease(): StillReleasePoll =
            polls.removeFirstOrNull() ?: StillReleasePoll.COMPLETE

        override suspend fun terminateStillCapture() {
            terminates += 1
        }

        override suspend fun setStillBurstBracket(active: Boolean) {
            if (failBracket) {
                throw CameraControlException.CommandRejected
            }
            bracketCalls += active
        }

        override suspend fun refreshProperties() {
            if (refreshDelayMillis > 0) kotlinx.coroutines.delay(refreshDelayMillis)
            refreshes += 1
        }
    }

    @Test
    fun `preserve focus reaches every release of a chained burst`() = runTest {
        val session = FakeSession()
        val controller = StillCaptureController(session, pollDelayMillis = 1)
        session.polls.addAll(listOf(StillReleasePoll.COMPLETE, StillReleasePoll.COMPLETE))

        controller.pressed(this, continuousDrive = true, preserveFocus = true)
        advanceUntilIdle()

        // Every release in the run must skip AF, not just the first.
        assertTrue(session.initiates > 1)
        assertEquals(true, session.lastPreserveFocus)
    }

    @Test
    fun `a release defaults to AF-then-release`() = runTest {
        val session = FakeSession()
        val controller = StillCaptureController(session, pollDelayMillis = 1)
        session.polls.add(StillReleasePoll.COMPLETE)

        controller.pressed(this, continuousDrive = false)
        advanceUntilIdle()

        assertEquals(false, session.lastPreserveFocus)
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
    fun `finger-up during a chained burst run terminates it and closes the bracket`() = runTest {
        val session = FakeSession()
        val controller = StillCaptureController(session, pollDelayMillis = 50)
        // The first frame completes while held, so a burst run chains; the finger lifts mid-run.
        session.polls.addAll(
            listOf(
                StillReleasePoll.COMPLETE,
                StillReleasePoll.IN_PROGRESS,
                StillReleasePoll.IN_PROGRESS,
                StillReleasePoll.COMPLETE,
            ),
        )

        controller.pressed(this, continuousDrive = true)
        testScheduler.advanceTimeBy(60)
        controller.released(this)
        advanceUntilIdle()

        // Terminate was sent for the in-flight burst run; no third initiate chained.
        assertEquals(2, session.initiates)
        assertEquals(1, session.terminates)
        assertEquals(listOf(true, false), session.bracketCalls)
        assertFalse(controller.isCapturing.value)
    }

    @Test
    fun `a quick tap in continuous drive takes its one frame`() = runTest {
        // The ZR in CH took no photo for a tap or a 0.3 to 0.5 s press: the finger-up terminated
        // the release before the body exposed anything. A tap takes one frame, as on the body.
        val session = FakeSession()
        val controller = StillCaptureController(session, pollDelayMillis = 50)
        session.polls.addAll(
            listOf(StillReleasePoll.IN_PROGRESS, StillReleasePoll.IN_PROGRESS, StillReleasePoll.COMPLETE),
        )

        controller.pressed(this, continuousDrive = true)
        testScheduler.advanceTimeBy(60)
        controller.released(this)
        advanceUntilIdle()

        assertEquals(1, session.initiates)
        assertEquals(0, session.terminates)
        assertTrue(session.bracketCalls.isEmpty())
        assertFalse(controller.isCapturing.value)
    }

    @Test
    fun `a finger-up before the release is sent still takes the frame`() = runTest {
        val session = FakeSession()
        val controller = StillCaptureController(session, pollDelayMillis = 1)
        session.polls.add(StillReleasePoll.COMPLETE)

        controller.pressed(this, continuousDrive = true)
        controller.released(this)
        advanceUntilIdle()

        assertEquals(1, session.initiates)
        assertEquals(0, session.terminates)
        assertTrue(session.bracketCalls.isEmpty())
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
        // The first frame fires; the chained burst run is refused inside the open bracket.
        session.failFromInitiate = 1
        session.polls.add(StillReleasePoll.COMPLETE)
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
        val controller = StillCaptureController(session, pollDelayMillis = 50)
        val failures = mutableListOf<String>()
        controller.onFailure = { failures += it }
        session.polls.addAll(
            listOf(StillReleasePoll.COMPLETE, StillReleasePoll.IN_PROGRESS, StillReleasePoll.COMPLETE),
        )

        controller.pressed(this, continuousDrive = true)
        testScheduler.advanceTimeBy(60)
        controller.released(this)
        advanceUntilIdle()

        // The best-effort bracket is quiet; the burst run still fired after the first frame.
        assertEquals(2, session.initiates)
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

    @Test
    fun `a cancelled release is not reported as a camera failure`() = runTest {
        // A3-30: leaving the screen cancels the run; that is not a refused release.
        val session = FakeSession()
        val controller = StillCaptureController(session, pollDelayMillis = 10)
        val failures = mutableListOf<String>()
        controller.onFailure = { failures += it }
        session.polls.addAll(List(10) { StillReleasePoll.IN_PROGRESS })
        val owner = Job(coroutineContext[Job])

        controller.pressed(this + owner, continuousDrive = false)
        testScheduler.advanceTimeBy(25)
        owner.cancel()
        advanceUntilIdle()

        assertEquals(1, session.initiates)
        assertTrue(failures.isEmpty(), "cancellation surfaced as $failures")
        assertFalse(controller.isCapturing.value)
    }
}
