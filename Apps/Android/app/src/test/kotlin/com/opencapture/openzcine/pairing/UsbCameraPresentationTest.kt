package com.opencapture.openzcine.pairing

import com.opencapture.openzcine.transport.UsbPtpCameraAccess
import kotlin.test.Test
import kotlin.test.assertEquals

class UsbCameraPresentationTest {
    @Test
    fun `debug USB cards remain visibly synthetic and do not expose an identity`() {
        assertEquals("DEBUG FIXTURE — NOT USB HARDWARE", USB_DEBUG_FIXTURE_LABEL)
        assertEquals(
            "SIMULATED · ready",
            usbCameraDetail(UsbPtpCameraAccess.READY, isDebugFixture = true),
        )
        assertEquals(
            "USB-C · ready to connect",
            usbCameraDetail(UsbPtpCameraAccess.READY),
        )
    }
}
