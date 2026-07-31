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
    fun `usb path includes a cable network step then attached-camera discovery`() {
        var state = PairingFlowState.initial(permissionGranted = false)
        state = state.advance().choose(PairingPath.USB_C)

        assertEquals(PairingStep.PREPARE, state.step)
        assertEquals(5, state.stepCount)
        assertEquals(3, state.displayStepNumber)

        state = state.advance()
        assertEquals(PairingStep.NETWORK, state.step)
        assertFalse(state.isFinalStep)
        assertEquals(4, state.displayStepNumber)

        state = state.advance()
        assertEquals(PairingStep.DISCOVER, state.step)
        assertTrue(state.isFinalStep)
        assertEquals(5, state.displayStepNumber)
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

    /**
     * The router path is the hotspot path's shape: the app joins and hosts nothing, so it walks
     * the same five steps and ends by finding a camera someone else's network is carrying.
     */
    @Test
    fun `router path walks the same steps as the hotspot path`() {
        var flow = PairingFlowState(path = PairingPath.WIFI_NETWORK)
        assertEquals(5, flow.stepCount)
        flow = flow.advance().advance().advance()
        assertEquals(PairingStep.NETWORK, flow.step)
        flow = flow.advance()
        assertEquals(PairingStep.DISCOVER, flow.step)
        assertTrue(flow.isFinalStep)
    }

    /**
     * The camera-AP mechanisms — the Wi-Fi join and the credential scanner — belong to exactly one
     * path. One question rather than a list of exclusions, because the list is what went wrong:
     * each new path had to remember to opt out, and the ones that forgot cost real bugs.
     */
    @Test
    fun `only the camera access point joins the camera's own network`() {
        for (path in PairingPath.entries) {
            assertEquals(path == PairingPath.CAMERA_ACCESS_POINT, path.joinsCameraAccessPoint)
        }
    }

    /** Every path is reachable from exactly one card. */
    @Test
    fun `cards group every path exactly once`() {
        val grouped = PairingCard.entries.flatMap { it.options }
        assertEquals(PairingPath.entries.toSet(), grouped.toSet())
        assertEquals(PairingPath.entries.size, grouped.size)
        for (path in PairingPath.entries) {
            assertTrue(PairingCard.of(path).options.contains(path))
        }
        // Both cable options live under one card, mirroring iOS's Cable Link.
        assertEquals(
            listOf(PairingPath.USB_C, PairingPath.HDMI_CAPTURE),
            PairingCard.CABLE_LINK.options,
        )
    }

    /**
     * HDMI capture is a cable to a capture device, not a network: the wizard goes from preparing
     * the cable straight to finding it, with no network step to mislead the operator into
     * configuring Wi-Fi that plays no part.
     */
    @Test
    fun `hdmi path skips the network step and ends at discovery`() {
        var flow = PairingFlowState.initial(permissionGranted = false)
        flow = flow.advance().choose(PairingPath.HDMI_CAPTURE)
        assertEquals(PairingStep.PREPARE, flow.step)
        assertEquals(4, flow.stepCount)
        assertEquals(3, flow.displayStepNumber)

        flow = flow.advance()
        assertEquals(PairingStep.DISCOVER, flow.step)
        assertTrue(flow.isFinalStep)
        assertEquals(4, flow.displayStepNumber)

        // And back: retreat from discovery lands on prepare, never a network step.
        assertEquals(PairingStep.PREPARE, flow.retreat().step)
    }

    @Test
    fun `network step is rejected on the hdmi path`() {
        assertFailsWith<IllegalArgumentException> {
            PairingFlowState(step = PairingStep.NETWORK, path = PairingPath.HDMI_CAPTURE)
        }
    }
}
