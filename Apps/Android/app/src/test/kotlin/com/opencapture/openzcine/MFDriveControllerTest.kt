package com.opencapture.openzcine

import com.opencapture.openzcine.core.CameraRecordingState
import com.opencapture.openzcine.core.CameraSession
import com.opencapture.openzcine.core.CameraSessionState
import com.opencapture.openzcine.core.MFDriveOutcome
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNull
import kotlin.test.assertTrue
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.test.advanceUntilIdle
import kotlinx.coroutines.test.runTest

/** JVM coverage for the focus-by-wire coalescing queue. */
class MFDriveControllerTest {
    private class FakeSession : CameraSession {
        override val state: StateFlow<CameraSessionState> =
            MutableStateFlow(CameraSessionState.Disconnected)
        override val recordingState: StateFlow<CameraRecordingState> =
            MutableStateFlow(CameraRecordingState.STANDBY)

        /** (towardNear, pulses) per drive, in order. */
        val drives = mutableListOf<Pair<Boolean, Int>>()
        var outcomes: ArrayDeque<MFDriveOutcome> = ArrayDeque()

        /** When set, the next drive suspends until completed (in-flight window). */
        var gate: CompletableDeferred<Unit>? = null

        override suspend fun connect() = Unit

        override suspend fun setRecording(recording: Boolean) = Unit

        override suspend fun disconnect() = Unit

        override suspend fun mfDrive(towardNear: Boolean, pulses: Int): MFDriveOutcome {
            drives += towardNear to pulses
            gate?.let {
                gate = null
                it.await()
            }
            return outcomes.removeFirstOrNull() ?: MFDriveOutcome.Complete
        }
    }

    @Test
    fun `strip seats left of the right system rail, vertically centred`() {
        val viewport = com.opencapture.openzcine.bridge.ZoneFrame(0f, 0f, 914f, 384f)

        val frame = mfDriveStripFrame(viewport, rightRailLeading = 830f)

        assertEquals(830f - MF_DRIVE_STRIP_WIDTH_DP - 12f, frame.x)
        assertEquals(MF_DRIVE_STRIP_WIDTH_DP, frame.width)
        // Vertically centred, capped to the 0.6-viewport height bound.
        assertEquals(384f * 0.6f, frame.height, 0.01f)
        assertEquals((384f - frame.height) / 2f, frame.y, 0.01f)
    }

    @Test
    fun `gesture pulses accumulate while one drive is in flight`() = runTest {
        val session = FakeSession()
        val controller = MFDriveController(session)
        val gate = CompletableDeferred<Unit>()
        session.gate = gate

        controller.drive(this, 100)
        // Let the drain start and suspend on the wire (the gated drive).
        testScheduler.runCurrent()
        // Scrub keeps moving while the first drive is on the wire.
        controller.drive(this, 80)
        controller.drive(this, 60)
        gate.complete(Unit)
        advanceUntilIdle()

        // One in-flight drive, then ONE coalesced drive with the summed
        // pending pulses — never a call per gesture sample.
        assertEquals(listOf(false to 100, false to 140), session.drives)
    }

    @Test
    fun `signed pulses pick the direction and clamp to the wire bound`() = runTest {
        val session = FakeSession()
        val controller = MFDriveController(session)

        controller.drive(this, -50_000)
        advanceUntilIdle()

        assertEquals(listOf(true to 32767), session.drives)
    }

    @Test
    fun `travel end clears pending pulses and lights the reached side`() = runTest {
        val session = FakeSession()
        val controller = MFDriveController(session)
        val gate = CompletableDeferred<Unit>()
        session.gate = gate
        session.outcomes.add(MFDriveOutcome.EndOfTravel)

        controller.drive(this, 500)
        controller.drive(this, 500)
        gate.complete(Unit)
        advanceUntilIdle()

        // The queued pulses toward the limit were dropped — one drive only.
        assertEquals(1, session.drives.size)
        assertEquals(1, controller.atEnd.value)

        // The next gesture drives again and clears the end flash.
        session.outcomes.add(MFDriveOutcome.Complete)
        controller.drive(this, -60)
        advanceUntilIdle()
        assertEquals(2, session.drives.size)
        assertNull(controller.atEnd.value)
    }

    @Test
    fun `an access-denied refusal requeues and drives once the state clears`() = runTest {
        // Erik's exact scenario: right after switching to MF, the stepping-motor lens is
        // still initializing / autofocus is settling, so the first drive is refused with a
        // non-busy code (access-denied 0x2013). It must NOT be treated as an undrivable lens —
        // the pulses requeue and the drive lands once the state clears.
        val session = FakeSession()
        val controller =
            MFDriveController(
                session,
                retryDelayMillis = 1,
                elapsedMillis = { testScheduler.currentTime },
            )
        val messages = mutableListOf<String>()
        controller.onRefusalExhausted = { messages += it }
        session.outcomes.add(MFDriveOutcome.Refused(rawResponseCode = 0x2013))
        session.outcomes.add(MFDriveOutcome.Refused(rawResponseCode = 0x2013))
        session.outcomes.add(MFDriveOutcome.Complete)

        controller.drive(this, 200)
        advanceUntilIdle()

        // Same batch retried until it landed — no verdict, no message, strip stays up.
        assertEquals(
            listOf(false to 200, false to 200, false to 200),
            session.drives,
        )
        assertTrue(messages.isEmpty())
    }

    @Test
    fun `busy activation requeues the batch and drives once busy clears`() = runTest {
        val session = FakeSession()
        val controller =
            MFDriveController(
                session,
                retryDelayMillis = 1,
                elapsedMillis = { testScheduler.currentTime },
            )
        val messages = mutableListOf<String>()
        controller.onRefusalExhausted = { messages += it }
        // The body refuses the first two activations mid-acquisition, then takes it.
        session.outcomes.add(MFDriveOutcome.Refused(rawResponseCode = 0x2019))
        session.outcomes.add(MFDriveOutcome.Refused(rawResponseCode = 0x2019))
        session.outcomes.add(MFDriveOutcome.Complete)

        controller.drive(this, 120)
        advanceUntilIdle()

        // Same batch retried until it landed — never silently dropped.
        assertEquals(
            listOf(false to 120, false to 120, false to 120),
            session.drives,
        )
        assertTrue(messages.isEmpty())
    }

    @Test
    fun `refusal requeue keeps pulses queued by gestures during the retry window`() = runTest {
        val session = FakeSession()
        val controller =
            MFDriveController(
                session,
                retryDelayMillis = 50,
                elapsedMillis = { testScheduler.currentTime },
            )
        session.outcomes.add(MFDriveOutcome.Refused(rawResponseCode = 0x2019))
        session.outcomes.add(MFDriveOutcome.Complete)

        controller.drive(this, 100)
        testScheduler.runCurrent()
        // More scrub movement lands during the 50 ms retry backoff.
        controller.drive(this, 40)
        advanceUntilIdle()

        // The retry carries the requeued batch PLUS the new gesture pulses.
        assertEquals(listOf(false to 100, false to 140), session.drives)
    }

    @Test
    fun `a refusal run gives the command channel back inside the wall-clock budget`() =
        runTest {
            // #272: budgeting refusals by ITERATION COUNT let a drag own cameraCommandMutex for
            // tens of seconds — and changeAfArea needs that same mutex, so tap-to-focus went dead
            // until a shutter release. The budget is wall clock, and the run must end at it.
            val session = FakeSession()
            val controller =
                MFDriveController(
                    session,
                    retryDelayMillis = 400,
                    elapsedMillis = { testScheduler.currentTime },
                )
            val messages = mutableListOf<String>()
            controller.onRefusalExhausted = { messages += it }
            repeat(50) {
                session.outcomes.add(MFDriveOutcome.Refused(rawResponseCode = 0x2013))
            }

            controller.drive(this, 200)
            advanceUntilIdle()

            // t=0, 400, 800 retry; at t=1200 the budget is spent and the run stops.
            assertEquals(4, session.drives.size)
            assertTrue(testScheduler.currentTime <= MFDriveController.REFUSAL_RETRY_BUDGET_MILLIS)
            assertEquals(1, messages.size)
            assertTrue(messages.single().contains("0x2013"))

            // The budget reset: a later gesture retries from scratch and lands.
            session.outcomes.clear()
            session.outcomes.add(MFDriveOutcome.Refused(rawResponseCode = 0x2019))
            session.outcomes.add(MFDriveOutcome.Complete)
            controller.drive(this, 60)
            advanceUntilIdle()
            assertEquals(6, session.drives.size)
            assertEquals(1, messages.size)
        }

    @Test
    fun `cancel drops the queue so a focus tap is never stuck behind a drive`() = runTest {
        // #272: an AF tap cancels the drive before calling changeAfArea. Nothing queued may
        // survive it, and no second drain may start alongside the cancelled one.
        val session = FakeSession()
        val controller =
            MFDriveController(
                session,
                retryDelayMillis = 400,
                elapsedMillis = { testScheduler.currentTime },
            )
        val gate = CompletableDeferred<Unit>()
        session.gate = gate
        session.outcomes.add(MFDriveOutcome.Refused(rawResponseCode = 0x2019))
        repeat(20) { session.outcomes.add(MFDriveOutcome.Refused(rawResponseCode = 0x2019)) }

        controller.drive(this, 100)
        testScheduler.runCurrent()
        // Operator keeps scrubbing, then taps the feed mid-drive.
        controller.drive(this, 80)
        controller.cancel()
        gate.complete(Unit)
        advanceUntilIdle()

        // Only the drive already on the wire ran; the queued pulses were dropped, and the
        // refusal never retried — the channel is free for changeAfArea.
        assertEquals(listOf(false to 100), session.drives)

        // …and the dial still works right after: no latched "undrivable" state.
        session.outcomes.clear()
        session.outcomes.add(MFDriveOutcome.Complete)
        controller.drive(this, 40)
        advanceUntilIdle()
        assertEquals(listOf(false to 100, false to 40), session.drives)
    }

    @Test
    fun `an Invalid_Status refusal points the operator to an AF focus mode`() = runTest {
        // Doc-confirmed root cause: the body refuses a remote focus drive in MF with
        // Invalid_Status (0xA004). The exhaustion message must send the operator to an AF mode
        // (not the old "make sure focus mode is MF" copy) and it carries no raw code.
        val session = FakeSession()
        val controller =
            MFDriveController(
                session,
                retryDelayMillis = 400,
                elapsedMillis = { testScheduler.currentTime },
            )
        val messages = mutableListOf<String>()
        controller.onRefusalExhausted = { messages += it }
        repeat(20) { session.outcomes.add(MFDriveOutcome.Refused(rawResponseCode = 0xA004)) }

        controller.drive(this, 200)
        advanceUntilIdle()

        assertEquals(1, messages.size)
        assertTrue(messages.single().contains("AF focus mode"))
        assertFalse(messages.single().contains("0x"))
    }
}
