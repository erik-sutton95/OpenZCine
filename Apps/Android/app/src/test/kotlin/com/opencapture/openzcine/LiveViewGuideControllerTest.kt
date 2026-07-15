package com.opencapture.openzcine

import com.opencapture.openzcine.diagnostics.AndroidDiagnosticEvent
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNull
import kotlin.test.assertTrue

class LiveViewGuideControllerTest {
    @Test
    fun `automatic guide waits for a decoded real camera frame`() {
        val events = mutableListOf<AndroidDiagnosticEvent>()
        val controller = LiveViewGuideController(TestSharedPreferences(), events::add)

        assertNull(controller.activeStep)
        assertFalse(controller.blocksCameraCommands)
        assertEquals(LiveViewGuideStatus.FIRST_FRAME_PENDING, controller.status)

        controller.onRealDecodedFrame()

        assertEquals(LiveViewGuideStep.CAMERA_CONTROLS, controller.activeStep)
        assertTrue(controller.blocksCameraCommands)
        assertEquals(
            listOf(
                AndroidDiagnosticEvent.LIVE_VIEW_STARTED,
                AndroidDiagnosticEvent.GUIDE_PRESENTED,
            ),
            events,
        )
    }

    @Test
    fun `real frame gate rejects demo explicit synthetic and disconnected paths`() {
        assertTrue(
            realDecodedFrameCanTriggerGuide(
                isDemoSession = false,
                hasExplicitFrameSource = false,
                monitorUsesSwiftCameraSource = true,
                cameraConnected = true,
            ),
        )
        assertFalse(
            realDecodedFrameCanTriggerGuide(
                isDemoSession = true,
                hasExplicitFrameSource = false,
                monitorUsesSwiftCameraSource = true,
                cameraConnected = true,
            ),
        )
        assertFalse(
            realDecodedFrameCanTriggerGuide(
                isDemoSession = false,
                hasExplicitFrameSource = true,
                monitorUsesSwiftCameraSource = true,
                cameraConnected = true,
            ),
        )
        assertFalse(
            realDecodedFrameCanTriggerGuide(
                isDemoSession = false,
                hasExplicitFrameSource = false,
                monitorUsesSwiftCameraSource = false,
                cameraConnected = true,
            ),
        )
        assertFalse(
            realDecodedFrameCanTriggerGuide(
                isDemoSession = false,
                hasExplicitFrameSource = false,
                monitorUsesSwiftCameraSource = true,
                cameraConnected = false,
            ),
        )
    }

    @Test
    fun `three steps complete and persist across a reload`() {
        val preferences = TestSharedPreferences()
        val events = mutableListOf<AndroidDiagnosticEvent>()
        val controller = LiveViewGuideController(preferences, events::add)
        controller.onRealDecodedFrame()

        controller.advance()
        assertEquals(LiveViewGuideStep.VIEW_ASSIST, controller.activeStep)
        controller.advance()
        assertEquals(LiveViewGuideStep.SYSTEM_CONTROLS, controller.activeStep)
        controller.advance()

        assertNull(controller.activeStep)
        assertFalse(controller.blocksCameraCommands)
        assertEquals(LiveViewGuideStatus.COMPLETED, controller.status)
        assertEquals(AndroidDiagnosticEvent.GUIDE_COMPLETED, events.last())

        val restored = LiveViewGuideController(preferences)
        restored.onRealDecodedFrame()
        assertNull(restored.activeStep)
        assertEquals(LiveViewGuideStatus.COMPLETED, restored.status)
    }

    @Test
    fun `active step survives controller recreation and waits for a fresh real frame`() {
        val preferences = TestSharedPreferences()
        LiveViewGuideController(preferences).apply {
            onRealDecodedFrame()
            advance()
        }

        val restored = LiveViewGuideController(preferences)
        assertNull(restored.activeStep)
        assertTrue(restored.needsRealDecodedFrame)

        restored.onRealDecodedFrame()

        assertEquals(LiveViewGuideStep.VIEW_ASSIST, restored.activeStep)
        assertTrue(restored.blocksCameraCommands)
    }

    @Test
    fun `skip marks this guide version complete`() {
        val preferences = TestSharedPreferences()
        val events = mutableListOf<AndroidDiagnosticEvent>()
        val controller = LiveViewGuideController(preferences, events::add)
        controller.onRealDecodedFrame()

        controller.skip()

        assertNull(controller.activeStep)
        assertEquals(LiveViewGuideStatus.COMPLETED, controller.status)
        assertEquals(AndroidDiagnosticEvent.GUIDE_SKIPPED, events.last())
    }

    @Test
    fun `settings replay now and next frame expose truthful state`() {
        val preferences = TestSharedPreferences()
        val controller = LiveViewGuideController(preferences)
        controller.onRealDecodedFrame()
        controller.skip()

        controller.replayNow()
        assertEquals(LiveViewGuideStatus.SHOWING, controller.status)
        controller.skip()

        controller.replayOnNextRealFrame()
        assertEquals(LiveViewGuideStatus.SCHEDULED, controller.status)
        assertNull(controller.activeStep)

        controller.onRealDecodedFrame()
        assertEquals(LiveViewGuideStep.CAMERA_CONTROLS, controller.activeStep)
        assertEquals(LiveViewGuideStatus.SHOWING, controller.status)
    }

    @Test
    fun `guide becomes inert when the real frame is no longer available`() {
        val controller = LiveViewGuideController(TestSharedPreferences())
        controller.onRealDecodedFrame()
        assertTrue(controller.blocksCameraCommands)

        controller.onRealFrameUnavailable()

        assertFalse(controller.blocksCameraCommands)
        assertNull(controller.activeStep)
        assertTrue(controller.needsRealDecodedFrame)
    }
}
