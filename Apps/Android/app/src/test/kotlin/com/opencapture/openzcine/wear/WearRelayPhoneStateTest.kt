package com.opencapture.openzcine.wear

import com.opencapture.openzcine.core.CameraIdentity
import com.opencapture.openzcine.core.CameraPropertySnapshot
import com.opencapture.openzcine.core.CameraSessionState
import com.opencapture.openzcine.core.CameraStorageStatus
import com.opencapture.openzcine.wearrelay.WatchConnectionState
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNull
import kotlin.test.assertTrue

class WearRelayPhoneStateTest {
    @Test
    fun `watch record bypass still rejects every unsafe monitor state`() {
        val safe =
            WearRecordCommandSafety(
                monitorFront = true,
                applicationResumed = true,
                cameraConnected = true,
                liveFeedActive = true,
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
            "Start live view before recording.",
            wearRecordCommandRejection(safe.copy(liveFeedActive = false)),
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
        pump.complete(first.token)
        assertEquals(2, dispatched.size, "A stale completion must not release a newer generation.")
        assertTrue(pump.isBusy())
        pump.complete(fresh.token)
        assertFalse(pump.isBusy())
    }
}
