package com.opencapture.openzcine.core

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import kotlinx.coroutines.test.runTest

class FakeCameraSessionTest {
    private val zr = CameraIdentity(name = "Nikon ZR", model = "ZR", serialNumber = "0001")

    @Test
    fun `starts disconnected`() {
        assertEquals(CameraSessionState.Disconnected, FakeCameraSession().state.value)
    }

    @Test
    fun `connect reaches connected when a camera is discoverable`() = runTest {
        val session = FakeCameraSession(discoverable = zr)

        session.connect()

        assertEquals(CameraSessionState.Connected(zr), session.state.value)
    }

    @Test
    fun `connect falls back to disconnected when no camera is found`() = runTest {
        val session = FakeCameraSession(discoverable = null)

        session.connect()

        assertEquals(CameraSessionState.Disconnected, session.state.value)
    }

    @Test
    fun `disconnect returns a connected session to disconnected`() = runTest {
        val session = FakeCameraSession(discoverable = zr)
        session.connect()
        assertEquals(CameraSessionState.Connected(zr), session.state.value)

        session.disconnect()

        assertEquals(CameraSessionState.Disconnected, session.state.value)
        assertEquals(CameraRecordingState.STANDBY, session.recordingState.value)
    }

    @Test
    fun `recording commands follow the connected session state`() = runTest {
        val session = FakeCameraSession(discoverable = zr)

        assertFailsWith<CameraRecordingException.NotConnected> {
            session.setRecording(true)
        }

        session.connect()
        session.setRecording(true)
        assertEquals(CameraRecordingState.RECORDING, session.recordingState.value)

        session.setRecording(false)
        assertEquals(CameraRecordingState.STANDBY, session.recordingState.value)
    }
}
