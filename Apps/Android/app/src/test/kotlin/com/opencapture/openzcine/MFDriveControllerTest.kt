package com.opencapture.openzcine

import com.opencapture.openzcine.core.CameraRecordingState
import com.opencapture.openzcine.core.CameraSession
import com.opencapture.openzcine.core.CameraSessionState
import com.opencapture.openzcine.core.MFDriveOutcome
import kotlin.test.Test
import kotlin.test.assertEquals
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
    fun `a non-drivable lens surfaces once and clears pending`() = runTest {
        val session = FakeSession()
        val controller = MFDriveController(session)
        val messages = mutableListOf<String>()
        controller.onNonDrivableLens = { messages += it }
        session.outcomes.add(MFDriveOutcome.Refused(rawResponseCode = 0x201F))
        session.outcomes.add(MFDriveOutcome.Refused(rawResponseCode = 0x201F))

        controller.drive(this, 200)
        advanceUntilIdle()
        controller.drive(this, 200)
        advanceUntilIdle()

        // Both refusals ended their runs; only the FIRST surfaced.
        assertEquals(2, session.drives.size)
        assertEquals(1, messages.size)
        assertTrue(messages.single().contains("0x201F"))
    }

    @Test
    fun `a busy channel stays quiet and the next gesture retries`() = runTest {
        val session = FakeSession()
        val controller = MFDriveController(session)
        val messages = mutableListOf<String>()
        controller.onNonDrivableLens = { messages += it }
        session.outcomes.add(MFDriveOutcome.Refused(rawResponseCode = 0x2019))

        controller.drive(this, 120)
        advanceUntilIdle()
        controller.drive(this, 120)
        advanceUntilIdle()

        assertEquals(2, session.drives.size)
        assertTrue(messages.isEmpty())
    }
}
