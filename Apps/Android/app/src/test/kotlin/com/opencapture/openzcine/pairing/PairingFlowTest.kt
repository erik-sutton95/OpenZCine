package com.opencapture.openzcine.pairing

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import kotlin.test.assertFalse
import kotlin.test.assertTrue

class PairingFlowTest {
    @Test
    fun `camera-AP path walks permissions to network and ends there`() {
        var state = PairingFlowState.initial(permissionGranted = false)
        assertEquals(PairingStep.PERMISSIONS, state.step)
        assertEquals(4, state.stepCount)
        assertEquals(1, state.displayStepNumber)
        assertFalse(state.canRetreat)

        state = state.advance()
        assertEquals(PairingStep.CHOOSE_PATH, state.step)

        state = state.choose(PairingPath.CAMERA_ACCESS_POINT)
        assertEquals(PairingStep.PREPARE, state.step)
        assertEquals(3, state.displayStepNumber)

        state = state.advance()
        assertEquals(PairingStep.NETWORK, state.step)
        assertEquals(4, state.displayStepNumber)
        assertTrue(state.isFinalStep)

        // Advancing past the final step is a no-op.
        assertEquals(state, state.advance())
    }

    @Test
    fun `hotspot path adds the discover step as its final step`() {
        var state = PairingFlowState.initial(permissionGranted = false)
        state = state.advance().choose(PairingPath.PHONE_HOTSPOT)
        assertEquals(5, state.stepCount)

        state = state.advance()
        assertEquals(PairingStep.NETWORK, state.step)
        assertFalse(state.isFinalStep)

        state = state.advance()
        assertEquals(PairingStep.DISCOVER, state.step)
        assertEquals(5, state.displayStepNumber)
        assertTrue(state.isFinalStep)
        assertEquals(state, state.advance())
    }

    @Test
    fun `usb path skips Wi-Fi setup and ends at attached-camera discovery`() {
        var state = PairingFlowState.initial(permissionGranted = false)
        state = state.advance().choose(PairingPath.USB_C)

        assertEquals(PairingStep.PREPARE, state.step)
        assertEquals(4, state.stepCount)
        assertEquals(3, state.displayStepNumber)

        state = state.advance()
        assertEquals(PairingStep.DISCOVER, state.step)
        assertTrue(state.isFinalStep)
        assertEquals(4, state.displayStepNumber)
    }

    @Test
    fun `granted permission skips the permissions step and renumbers`() {
        var state = PairingFlowState.initial(permissionGranted = true)
        assertEquals(PairingStep.CHOOSE_PATH, state.step)
        assertEquals(3, state.stepCount)
        assertEquals(1, state.displayStepNumber)
        assertFalse(state.canRetreat)

        state = state.choose(PairingPath.PHONE_HOTSPOT)
        assertEquals(4, state.stepCount)
        assertEquals(2, state.displayStepNumber)
    }

    @Test
    fun `retreat walks back and stops at the first step`() {
        var state = PairingFlowState.initial(permissionGranted = false)
        state = state.advance().choose(PairingPath.CAMERA_ACCESS_POINT).advance()
        assertEquals(PairingStep.NETWORK, state.step)

        state = state.retreat()
        assertEquals(PairingStep.PREPARE, state.step)
        state = state.retreat()
        assertEquals(PairingStep.CHOOSE_PATH, state.step)
        state = state.retreat()
        assertEquals(PairingStep.PERMISSIONS, state.step)
        assertEquals(state, state.retreat())
    }

    @Test
    fun `choosing a new path from choose step resets onto that path`() {
        var state = PairingFlowState.initial(permissionGranted = false).advance()
        state = state.choose(PairingPath.PHONE_HOTSPOT)
        assertEquals(PairingPath.PHONE_HOTSPOT, state.path)

        // Back to choose, pick the other path.
        state = state.retreat().choose(PairingPath.CAMERA_ACCESS_POINT)
        assertEquals(PairingPath.CAMERA_ACCESS_POINT, state.path)
        assertEquals(4, state.stepCount)
    }

    @Test
    fun `discover step is rejected on the camera-AP path`() {
        assertFailsWith<IllegalArgumentException> {
            PairingFlowState(step = PairingStep.DISCOVER, path = PairingPath.CAMERA_ACCESS_POINT)
        }
    }

    @Test
    fun `permissions step is rejected while skipped`() {
        assertFailsWith<IllegalArgumentException> {
            PairingFlowState(step = PairingStep.PERMISSIONS, skipsPermissions = true)
        }
    }
}
