package com.opencapture.openzcine.pairing

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNull

class CameraSessionDiagnosticsTest {
    @Test
    fun `pairing phase details never enter camera session diagnostics`() {
        assertNull(cameraSessionDiagnosticMessage("confirmOnCamera", "123456"))
        assertNull(cameraSessionDiagnosticMessage("handshaking", "192.168.1.1"))
    }

    @Test
    fun `safe terminal diagnostics retain their failure detail`() {
        assertEquals(
            "eventChannelEnded: The camera closed the connection.",
            cameraSessionDiagnosticMessage(
                "eventChannelEnded",
                "The camera closed the connection.",
            ),
        )
        assertEquals(
            "failed.usb: native link missing",
            cameraSessionDiagnosticMessage("failed.usb", "native link missing"),
        )
        assertEquals(
            "failed.ptp: unreachable",
            cameraSessionDiagnosticMessage("failed.ptp", "unreachable"),
        )
    }

    @Test
    fun `slow property write logs the property name that stalled the gate`() {
        // The detail is a closed CameraControl name + elapsed millis — no credential.
        assertEquals(
            "propertyWriteSlow: FOCUS_MODE 2100ms",
            cameraSessionDiagnosticMessage("propertyWriteSlow", "FOCUS_MODE 2100ms"),
        )
    }

    @Test
    fun `pairing path maps to closed diagnostic phase tokens`() {
        assertEquals("path.usb", diagnosticPhaseForPairingPath(PairingPath.USB_C))
        assertEquals(
            "path.cameraAp",
            diagnosticPhaseForPairingPath(PairingPath.CAMERA_ACCESS_POINT),
        )
        assertEquals(
            "path.phoneHotspot",
            diagnosticPhaseForPairingPath(PairingPath.PHONE_HOTSPOT),
        )
        assertEquals("path.hdmi", diagnosticPhaseForPairingPath(PairingPath.HDMI_CAPTURE))
    }
}
