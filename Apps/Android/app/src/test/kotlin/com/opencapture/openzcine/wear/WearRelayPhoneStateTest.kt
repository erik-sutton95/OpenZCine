package com.opencapture.openzcine.wear

import com.opencapture.openzcine.core.CameraIdentity
import com.opencapture.openzcine.core.CameraPropertySnapshot
import com.opencapture.openzcine.core.CameraRecordingException
import com.opencapture.openzcine.core.CameraSessionState
import com.opencapture.openzcine.core.CameraStorageStatus
import com.opencapture.openzcine.wearrelay.WatchConnectionState
import com.opencapture.openzcine.wearrelay.WatchTimecode
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNull
import kotlin.test.assertTrue
import kotlinx.coroutines.test.runTest

class WearRelayPhoneStateTest {
    @Test
    fun `watch record bypass still rejects every unsafe monitor state`() {
        val safe =
            WearRecordCommandSafety(
                monitorFront = true,
                applicationResumed = true,
                cameraConnected = true,
                recordCommandPending = false,
                recordConfirmationPending = false,
                cameraControlPending = false,
            )
        assertNull(wearRecordCommandRejection(safe))
        assertEquals(
            "Open the live monitor on the phone.",
            wearRecordCommandRejection(safe.copy(applicationResumed = false)),
        )
        assertEquals(
            "Connect a camera on the phone.",
            wearRecordCommandRejection(safe.copy(cameraConnected = false)),
        )
        assertEquals(
            "A recording command is already pending.",
            wearRecordCommandRejection(safe.copy(recordCommandPending = true)),
        )
        assertEquals(
            "Finish the pending record confirmation on the phone.",
            wearRecordCommandRejection(safe.copy(recordConfirmationPending = true)),
        )
        assertEquals(
            "Wait for the active camera control.",
            wearRecordCommandRejection(safe.copy(cameraControlPending = true)),
        )
    }

    @Test
    fun `watch record works while preview is paused and reports typed camera failure`() = runTest {
        val safe =
            WearRecordCommandSafety(
                monitorFront = true,
                applicationResumed = true,
                cameraConnected = true,
                recordCommandPending = false,
                recordConfirmationPending = false,
                cameraControlPending = false,
            )
        var requested: Boolean? = null

        val accepted =
            executeWearRecordCommand(safe, isRecording = false) { target -> requested = target }
        assertTrue(accepted.accepted)
        assertTrue(accepted.isRecording)
        assertEquals(true, requested)

        val rejected =
            executeWearRecordCommand(safe, isRecording = true) {
                throw CameraRecordingException.MediaBusy
            }
        assertFalse(rejected.accepted)
        assertTrue(rejected.isRecording)
        assertEquals(CameraRecordingException.MediaBusy.message, rejected.error)
    }

    @Test
    fun `phone state uses only actual camera properties and honest unavailable fields`() {
        val identity = CameraIdentity(name = "Nikon ZR", model = "ZR", serialNumber = "public-fixture")
        val snapshot =
            CameraPropertySnapshot(
                batteryPercent = 83,
                storage =
                    CameraStorageStatus(
                        totalCapacityBytes = 8L * 1_073_741_824L,
                        freeSpaceBytes = 4L * 1_073_741_824L,
                    ),
            )
        val state =
            androidWatchRelayState(
                sessionState = CameraSessionState.Connected(identity),
                cameraProperties = snapshot,
                isRecording = true,
                monitorFront = true,
                applicationResumed = true,
                liveFeedActive = true,
            )
        assertEquals(WatchConnectionState.CONNECTED, state.connection)
        assertEquals("Nikon ZR", state.cameraName)
        assertEquals(83, state.cameraBatteryPercent)
        assertEquals("4 GB · 50%", state.media)
        assertFalse(state.timecode.on)
        assertEquals("—", state.liveFPS)
        assertTrue(state.feedLive)

        val background =
            androidWatchRelayState(
                sessionState = CameraSessionState.Connected(identity),
                cameraProperties = snapshot,
                isRecording = true,
                monitorFront = true,
                applicationResumed = false,
                liveFeedActive = true,
            )
        assertEquals(WatchConnectionState.DISCONNECTED, background.connection)
        assertFalse(background.feedLive)
        assertEquals("", background.cameraName)

        val frameMetadata =
            state.copy(
                timecode = WatchTimecode(true, 1, 2, 3, 4),
                liveFPS = "25",
            )
        val commandMode = retainWatchFrameMetadata(state.copy(feedLive = false), frameMetadata)
        assertEquals("01:02:03:04", commandMode.timecode.label())
        assertEquals("25", commandMode.liveFPS)
    }

    @Test
    fun `frame pump invalidation releases the next foreground send and ignores stale completion`() {
        val dispatched = mutableListOf<LatestFrameBackpressure.Dispatch<String>>()
        val discarded = mutableListOf<String>()
        val pump =
            LatestFrameBackpressure(
                dispatch = { dispatched += it },
                onDiscard = { discarded += it },
            )

        pump.offer("first")
        val first = dispatched.single()
        pump.offer("stale")
        pump.invalidate()
        assertEquals(listOf("stale"), discarded)

        pump.offer("fresh")
        assertEquals(2, dispatched.size)
        val fresh = dispatched.last()
        assertTrue(fresh.token > first.token)
        assertFalse(pump.isActive(first.token))
        assertTrue(pump.isActive(fresh.token))
        pump.complete(first.token)
        assertEquals(2, dispatched.size, "A stale completion must not release a newer generation.")
        assertTrue(pump.isBusy())
        pump.complete(fresh.token)
        assertFalse(pump.isBusy())
    }

    @Test
    fun `frame pump matches the three-slot watch pipeline and keeps one freshest replacement`() {
        val dispatched = mutableListOf<LatestFrameBackpressure.Dispatch<String>>()
        val discarded = mutableListOf<String>()
        val pump =
            LatestFrameBackpressure(
                maximumInFlight = 3,
                dispatch = { dispatched += it },
                onDiscard = { discarded += it },
            )

        pump.offer("one")
        pump.offer("two")
        pump.offer("three")
        assertEquals(listOf("one", "two", "three"), dispatched.map { it.value })

        pump.offer("stale replacement")
        pump.offer("fresh replacement")
        assertEquals(listOf("stale replacement"), discarded)
        pump.complete(dispatched[1].token)

        assertEquals("fresh replacement", dispatched.last().value)
        assertEquals(3, dispatched.count { pump.isActive(it.token) })
    }
}
