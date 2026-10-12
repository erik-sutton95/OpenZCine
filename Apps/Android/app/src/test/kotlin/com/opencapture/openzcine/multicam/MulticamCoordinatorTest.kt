package com.opencapture.openzcine.multicam

import com.opencapture.opencine.multicam.ExclusionReason
import com.opencapture.opencine.multicam.RecordDirection
import com.opencapture.opencine.nikon.CameraIdentity
import com.opencapture.opencine.nikon.CameraRecordingException
import com.opencapture.opencine.nikon.CameraSession
import com.opencapture.opencine.nikon.FakeCameraSession
import com.opencapture.opencine.nikon.LiveFrame
import kotlin.coroutines.EmptyCoroutineContext
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNotNull
import kotlin.test.assertNull
import kotlin.test.assertSame
import kotlin.test.assertTrue
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.flow
import kotlinx.coroutines.test.TestScope
import kotlinx.coroutines.test.advanceTimeBy
import kotlinx.coroutines.test.runCurrent
import kotlinx.coroutines.test.runTest
import com.opencapture.opencine.nikon.NikonOpenCineSession
import com.opencapture.opencine.nikon.SavedCameraRecord
import com.opencapture.opencine.nikon.SavedCameraTransport

/**
 * NIKON-01 (Android twin of iOS `MulticamCoordinatorTests`): the app's multicam on the shared Kotlin
 * engine, with scripted Z bodies behind the real coordinator, `NikonOpenCineSession` adapters,
 * group plans and leases.
 */
@OptIn(ExperimentalCoroutinesApi::class)
class MulticamCoordinatorTest {
    /** A scripted body: reports its record state, refuses record when asked, logs commands. */
    private class Body(
        serial: String,
        private val inner: FakeCameraSession = FakeCameraSession(CameraIdentity("ZR_$serial", "ZR", serial)),
    ) : CameraSession by inner {
        val reported = MutableStateFlow<Boolean?>(false)
        override val reportedRecording get() = reported
        var refusesRecord = false
        val log = mutableListOf<String>()
        var frames = 0

        override suspend fun setRecording(recording: Boolean) {
            log += if (recording) "start" else "stop"
            if (refusesRecord) throw CameraRecordingException.CommandRejected
            reported.value = recording
        }

        override suspend fun disconnect() {
            log += "disconnect"
            inner.disconnect()
        }

        val link =
            MulticamLink(
                this,
                flow {
                    while (true) {
                        frames += 1
                        emit(LiveFrame(frames.toLong(), ByteArray(0), isRecording = reported.value == true))
                        delay(10)
                    }
                },
            )
    }

    private val bodies = mutableMapOf<String, Body>()
    /** What a body reports as its serial after connect, keyed by host. */
    private val serials = mutableMapOf<String, String>()

    private fun TestScope.stage(): MulticamCoordinator =
        MulticamCoordinator(
            scope = backgroundScope,
            connect = { record -> Body(serials[record.host] ?: record.host).also { bodies[record.host] = it }.link },
            decodeContext = EmptyCoroutineContext,
        ).also { it.begin() }

    private fun record(host: String, transport: SavedCameraTransport = SavedCameraTransport.USB_C) =
        SavedCameraRecord(host = host, cameraName = "ZR $host", transport = transport, lastSeenAtEpochMillis = null, wifiSsid = null)

    private fun TestScope.settle() {
        advanceTimeBy(100)
        runCurrent()
    }

    @Test
    fun fourBodiesJoinAndAFifthIsRefused() = runTest {
        val stage = stage()
        for (index in 0 until 4) assertNotNull(stage.add(record("h$index"), reachable = true))
        settle()
        assertEquals(4, stage.members.count { it.isLive })
        assertEquals(4, stage.group.entries.size)
        assertNull(stage.add(record("h4"), reachable = true))
        assertEquals(MulticamCopy.SESSION_FULL, stage.toast)
    }

    @Test
    fun refusedSetups() = runTest {
        val stage = stage()
        stage.add(record("h0"), reachable = true)
        assertEquals(MulticamCopy.ALREADY_MEMBER, stage.refusal(record("h0"), reachable = true))
        assertEquals(
            MulticamCopy.CAMERA_WIFI,
            stage.refusal(record("192.168.1.1", SavedCameraTransport.CAMERA_ACCESS_POINT), reachable = true),
        )
        assertEquals(MulticamCopy.NOT_REACHABLE, stage.refusal(record("usb:x"), reachable = false))
        assertNull(stage.refusal(record("10.0.0.5", SavedCameraTransport.INFRASTRUCTURE), reachable = true))
    }

    @Test
    fun oneBodyJoinsOnceByItsSerial() = runTest {
        val stage = stage()
        serials["usb:zr"] = "3000120"
        serials["10.0.0.9"] = "3000120"
        stage.add(record("usb:zr"), reachable = true)
        settle()
        // Another setup of the same body: Android records carry no serial, so the session's does.
        stage.add(record("10.0.0.9", SavedCameraTransport.INFRASTRUCTURE), reachable = true)
        settle()
        assertEquals(1, stage.members.size)
        assertEquals(MulticamCopy.ALREADY_MEMBER, stage.toast)
        assertEquals(listOf("disconnect"), bodies.getValue("10.0.0.9").log)
        assertFalse("disconnect" in bodies.getValue("usb:zr").log)
    }

    @Test
    fun mixedGroupStartStaysMixed() = runTest {
        val stage = stage()
        for (index in 0 until 3) stage.add(record("h$index"), reachable = true)
        settle()
        bodies.getValue("h1").refusesRecord = true
        val plan = stage.groupPlan()
        assertEquals(RecordDirection.START, plan.direction)
        assertEquals(3, plan.targets.size)
        stage.run(plan, together = true)
        assertEquals(true, bodies.getValue("h0").reported.value)
        assertEquals(true, bodies.getValue("h2").reported.value)
        assertEquals(false, bodies.getValue("h1").reported.value)
        assertEquals("Recording command rejected · check camera", stage.memberAt(1)?.note)
        assertEquals("Recording", stage.memberAt(0)?.note)
        assertEquals("2 of 3 confirmed · check camera tiles", stage.toast)
        // Partial success is not a transaction: nothing stops the cameras that started.
        assertFalse("stop" in bodies.getValue("h0").log)
    }

    @Test
    fun liveViewBorrowKeepsTheSessionAndPausesThatFeed() = runTest {
        val stage = stage()
        for (index in 0 until 3) stage.add(record("h$index"), reachable = true)
        settle()
        val borrowed = assertNotNull(stage.memberAt(1))
        val session = stage.group[borrowed.id]?.cameraSession
        val before = stage.groupPlan()

        val lent = assertNotNull(stage.lend(borrowed.id))
        assertSame(bodies.getValue("h1"), lent)
        assertNull(stage.lend(assertNotNull(stage.memberAt(0)).id), "one Live View at a time")
        assertTrue(stage.owns(lent))
        val frames = bodies.getValue("h1").frames
        settle()
        assertEquals(frames, bodies.getValue("h1").frames, "the lent member's stage feed stands down")
        val during = stage.groupPlan()
        assertEquals(listOf<ExclusionReason>(ExclusionReason.Busy), during.exclusions.map { it.reason })

        stage.reclaim()
        settle()
        assertTrue(bodies.getValue("h1").frames > frames, "the feed resumed")
        assertEquals(session, stage.group[borrowed.id]?.cameraSession, "same session, no reconnect")
        assertTrue(before.isCurrent(stage.group, stage.engineState()))
        assertFalse("disconnect" in bodies.getValue("h1").log, "no CloseSession")
    }

    /** A4-19: Record all is strict in every app, so a camera lent to Live View holds the whole press. */
    @Test
    fun recordAllWithOneCameraInLiveViewCommandsNone() = runTest {
        val stage = stage()
        for (index in 0 until 3) stage.add(record("h$index"), reachable = true)
        settle()
        assertNotNull(stage.lend(assertNotNull(stage.memberAt(1)).id))
        val plan = stage.groupPlan()
        assertTrue(plan.isRefused)
        assertFalse(plan.isExecutable)
        stage.run(plan, together = true)
        for (body in bodies.values) assertFalse("start" in body.log)
        assertEquals("Cameras changed · try again", stage.toast)
        // A tile's own press still records that camera alone.
        val own = stage.plan(assertNotNull(stage.memberAt(0)).id)
        assertTrue(own.isExecutable)
        stage.run(own, together = false)
        assertEquals(listOf("start"), bodies.getValue("h0").log.filter { it == "start" })
        assertFalse("start" in bodies.getValue("h2").log)
    }

    @Test
    fun removeAndEndCloseLinksWithoutStoppingRecording() = runTest {
        val stage = stage()
        for (index in 0 until 2) stage.add(record("h$index"), reachable = true)
        settle()
        stage.run(stage.groupPlan(), together = true)
        assertEquals(true, bodies.getValue("h0").reported.value)
        stage.remove(assertNotNull(stage.memberAt(0)).id)
        stage.end()
        settle()
        for (body in bodies.values) {
            assertEquals("disconnect", body.log.last())
            assertFalse("stop" in body.log)
        }
        assertFalse(stage.presented)
    }
}
