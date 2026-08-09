package com.opencapture.openzcine.settings

import com.opencapture.openzcine.frameio.FrameioNetworkState
import kotlin.test.Test
import kotlin.test.assertFalse
import kotlin.test.assertTrue

/**
 * The camera-AP gate in front of Operator Setup's two in-process internet actions (the anonymous
 * bug report and Adobe sign-in). Inverting it is silent: the button still renders, the request
 * just dies against a Wi-Fi network with no route out.
 */
class SettingsInternetHopTest {
    @Test
    fun `only the camera access point forces a hop`() {
        assertTrue(settingsActionNeedsInternetHop(FrameioNetworkState.CAMERA_ACCESS_POINT))
        assertFalse(settingsActionNeedsInternetHop(FrameioNetworkState.ONLINE))
        // Offline is not hoppable — there is no camera binding to release, and the failure the
        // operator needs to see is "no internet", not a camera disconnect.
        assertFalse(settingsActionNeedsInternetHop(FrameioNetworkState.OFFLINE))
        // Standalone setup carries no Frame.io controller at all.
        assertFalse(settingsActionNeedsInternetHop(null))
    }
}
