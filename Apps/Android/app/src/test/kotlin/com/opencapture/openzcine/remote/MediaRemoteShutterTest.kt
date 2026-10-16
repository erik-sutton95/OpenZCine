package com.opencapture.openzcine.remote

import com.opencapture.opencine.appkit.MonitorRemoteShutterCommand
import com.opencapture.opencine.nikon.CameraIdentity
import com.opencapture.opencine.nikon.CameraRecordingState
import com.opencapture.opencine.nikon.FakeCameraSession
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertTrue
import kotlinx.coroutines.test.runTest

/** The key gate and arming moved to OpenCine appkit (MonitorRemoteShutterTest); the Nikon record route stays here. */
class MediaRemoteShutterTest {
    @Test
    fun `remote commands route through the existing camera session without confirmation`() = runTest {
        val session =
            FakeCameraSession(
                CameraIdentity(name = "Test ZR", model = "NIKON ZR", serialNumber = "TEST-001"),
            )
        session.connect()

        assertTrue(
            routeMediaRemoteShutterCommand(
                session = session,
                command = MonitorRemoteShutterCommand.TOGGLE,
                isRecording = false,
                recordControlEnabled = true,
            ),
        )
        assertEquals(CameraRecordingState.RECORDING, session.recordingState.value)
        assertFalse(
            routeMediaRemoteShutterCommand(
                session = session,
                command = MonitorRemoteShutterCommand.START,
                isRecording = true,
                recordControlEnabled = true,
            ),
        )
        assertTrue(
            routeMediaRemoteShutterCommand(
                session = session,
                command = MonitorRemoteShutterCommand.STOP,
                isRecording = true,
                recordControlEnabled = true,
            ),
        )
        assertEquals(CameraRecordingState.STANDBY, session.recordingState.value)
        assertFalse(
            routeMediaRemoteShutterCommand(
                session = session,
                command = MonitorRemoteShutterCommand.TOGGLE,
                isRecording = false,
                recordControlEnabled = false,
            ),
        )
    }
}
