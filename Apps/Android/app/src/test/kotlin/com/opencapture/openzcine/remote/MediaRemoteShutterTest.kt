package com.opencapture.openzcine.remote

import android.view.KeyEvent
import com.opencapture.openzcine.core.CameraIdentity
import com.opencapture.openzcine.core.CameraRecordingState
import com.opencapture.openzcine.core.FakeCameraSession
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNull
import kotlin.test.assertTrue
import kotlinx.coroutines.test.runTest

class MediaRemoteShutterTest {
    private var nowMillis: Long = 1_000L
    private val received = mutableListOf<MediaRemoteShutterCommand>()
    private val controller = MediaRemoteShutterController { nowMillis }

    @Test
    fun `only armed allowlisted hardware keys emit one command`() {
        assertFalse(key(KeyEvent.KEYCODE_MEDIA_PLAY_PAUSE))

        controller.arm(received::add)

        assertTrue(key(KeyEvent.KEYCODE_MEDIA_PLAY_PAUSE))
        assertEquals(listOf(MediaRemoteShutterCommand.TOGGLE), received)
        assertTrue(key(KeyEvent.KEYCODE_MEDIA_PLAY_PAUSE, KeyEvent.ACTION_UP))
        assertEquals(listOf(MediaRemoteShutterCommand.TOGGLE), received)
        assertFalse(key(KeyEvent.KEYCODE_CAMERA))

        nowMillis += 600
        assertTrue(key(KeyEvent.KEYCODE_VOLUME_UP))
        assertEquals(
            listOf(MediaRemoteShutterCommand.TOGGLE, MediaRemoteShutterCommand.TOGGLE),
            received,
        )
    }

    @Test
    fun `repeats and duplicate delivery are debounced while their key events remain consumed`() {
        controller.arm(received::add)

        assertTrue(key(KeyEvent.KEYCODE_HEADSETHOOK))
        assertTrue(key(KeyEvent.KEYCODE_HEADSETHOOK, repeatCount = 1))
        nowMillis += 100
        assertTrue(key(KeyEvent.KEYCODE_MEDIA_PLAY_PAUSE))
        assertEquals(listOf(MediaRemoteShutterCommand.TOGGLE), received)

        nowMillis += 500
        assertTrue(key(KeyEvent.KEYCODE_MEDIA_PLAY_PAUSE))
        assertEquals(
            listOf(MediaRemoteShutterCommand.TOGGLE, MediaRemoteShutterCommand.TOGGLE),
            received,
        )
    }

    @Test
    fun `disarming releases normal media-key handling and a later arm can receive a fresh command`() {
        controller.arm(received::add)
        assertTrue(key(KeyEvent.KEYCODE_MEDIA_PLAY))
        controller.disarm()

        assertFalse(controller.isArmed)
        assertFalse(key(KeyEvent.KEYCODE_MEDIA_PLAY))
        assertEquals(listOf(MediaRemoteShutterCommand.START), received)

        controller.arm(received::add)
        assertTrue(key(KeyEvent.KEYCODE_MEDIA_STOP))
        assertEquals(
            listOf(MediaRemoteShutterCommand.START, MediaRemoteShutterCommand.STOP),
            received,
        )
    }

    @Test
    fun `key map supports documented media and volume shutter actions`() {
        assertEquals(
            MediaRemoteShutterCommand.TOGGLE,
            MediaRemoteShutterKeyMap.commandFor(KeyEvent.KEYCODE_HEADSETHOOK),
        )
        assertEquals(
            MediaRemoteShutterCommand.START,
            MediaRemoteShutterKeyMap.commandFor(KeyEvent.KEYCODE_MEDIA_RECORD),
        )
        assertEquals(
            MediaRemoteShutterCommand.STOP,
            MediaRemoteShutterKeyMap.commandFor(KeyEvent.KEYCODE_MEDIA_PAUSE),
        )
        assertEquals(
            MediaRemoteShutterCommand.TOGGLE,
            MediaRemoteShutterKeyMap.commandFor(KeyEvent.KEYCODE_VOLUME_DOWN),
        )
        assertEquals(
            MediaRemoteShutterCommand.TOGGLE,
            MediaRemoteShutterKeyMap.commandFor(KeyEvent.KEYCODE_VOLUME_UP),
        )
        assertNull(MediaRemoteShutterKeyMap.commandFor(KeyEvent.KEYCODE_CAMERA))
    }

    @Test
    fun `arm decision rejects every non-ready monitor state`() {
        assertTrue(armDecision())
        assertFalse(armDecision(enabled = false))
        assertFalse(armDecision(monitorIsFront = false))
        assertFalse(armDecision(cameraConnected = false))
        assertFalse(armDecision(recordCommandPending = true))
        assertFalse(armDecision(applicationResumed = false))
        assertFalse(armDecision(recordConfirmationPending = true))
        assertFalse(armDecision(cameraControlPending = true))
    }

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
                command = MediaRemoteShutterCommand.TOGGLE,
                isRecording = false,
                recordControlEnabled = true,
            ),
        )
        assertEquals(CameraRecordingState.RECORDING, session.recordingState.value)
        assertFalse(
            routeMediaRemoteShutterCommand(
                session = session,
                command = MediaRemoteShutterCommand.START,
                isRecording = true,
                recordControlEnabled = true,
            ),
        )
        assertTrue(
            routeMediaRemoteShutterCommand(
                session = session,
                command = MediaRemoteShutterCommand.STOP,
                isRecording = true,
                recordControlEnabled = true,
            ),
        )
        assertEquals(CameraRecordingState.STANDBY, session.recordingState.value)
        assertFalse(
            routeMediaRemoteShutterCommand(
                session = session,
                command = MediaRemoteShutterCommand.TOGGLE,
                isRecording = false,
                recordControlEnabled = false,
            ),
        )
    }

    private fun key(
        keyCode: Int,
        action: Int = KeyEvent.ACTION_DOWN,
        repeatCount: Int = 0,
    ): Boolean =
        controller.handleKeyEvent(
            keyCode = keyCode,
            action = action,
            repeatCount = repeatCount,
        )

    private fun armDecision(
        enabled: Boolean = true,
        monitorIsFront: Boolean = true,
        cameraConnected: Boolean = true,
        recordCommandPending: Boolean = false,
        applicationResumed: Boolean = true,
        recordConfirmationPending: Boolean = false,
        cameraControlPending: Boolean = false,
    ): Boolean =
        shouldArmMediaRemoteShutter(
            enabled = enabled,
            monitorIsFront = monitorIsFront,
            cameraConnected = cameraConnected,
            recordCommandPending = recordCommandPending,
            applicationResumed = applicationResumed,
            recordConfirmationPending = recordConfirmationPending,
            cameraControlPending = cameraControlPending,
        )
}
