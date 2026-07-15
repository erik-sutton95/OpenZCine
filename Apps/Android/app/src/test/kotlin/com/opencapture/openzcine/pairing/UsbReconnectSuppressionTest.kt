package com.opencapture.openzcine.pairing

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertTrue

class UsbReconnectSuppressionTest {
    private val usbRecord =
        SavedCameraRecord(
            host = "usb:camera-a",
            cameraName = "Nikon ZR",
            transport = SavedCameraTransport.USB_C,
            lastSeenAtEpochMillis = null,
            wifiSsid = null,
        )

    @Test
    fun `explicit disconnect holds an attached USB profile until detach and replug re-arm it`() {
        val attached = setOf(usbRecord.host)
        val suppressed =
            usbAutoReconnectSuppressionAfterUserAction(
                suppressedHosts = emptySet(),
                record = usbRecord,
                reconnect = false,
            )

        assertFalse(
            mayAutoReconnectUsb(
                record = usbRecord,
                attachedHosts = attached,
                attemptedHosts = emptySet(),
                suppressedHosts = suppressed,
            ),
        )
        val afterDetach =
            attachedUsbAutoReconnectSuppressions(
                suppressedHosts = suppressed,
                attachedHosts = emptySet(),
            )
        assertEquals(
            emptySet(),
            afterDetach,
        )
        val afterReplug =
            attachedUsbAutoReconnectSuppressions(
                suppressedHosts = afterDetach,
                attachedHosts = attached,
            )
        assertTrue(
            mayAutoReconnectUsb(
                record = usbRecord,
                attachedHosts = attached,
                attemptedHosts = emptySet(),
                suppressedHosts = afterReplug,
            ),
        )
    }

    @Test
    fun `explicit reconnect clears only the disconnected USB profile hold`() {
        val held =
            usbAutoReconnectSuppressionAfterUserAction(
                suppressedHosts = setOf(usbRecord.host, "usb:other"),
                record = usbRecord,
                reconnect = false,
            )

        val reconnected =
            usbAutoReconnectSuppressionAfterUserAction(
                suppressedHosts = held,
                record = usbRecord,
                reconnect = true,
            )

        assertEquals(setOf("usb:other"), reconnected)
        assertTrue(
            mayAutoReconnectUsb(
                record = usbRecord,
                attachedHosts = setOf(usbRecord.host),
                attemptedHosts = emptySet(),
                suppressedHosts = reconnected,
            ),
        )
        assertFalse(
            mayAutoReconnectUsb(
                record = usbRecord,
                attachedHosts = setOf(usbRecord.host),
                attemptedHosts = setOf(usbRecord.host),
                suppressedHosts = reconnected,
            ),
        )
    }
}
