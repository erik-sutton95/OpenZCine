package com.opencapture.openzcine.pairing

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNull
import com.opencapture.opencine.nikon.CameraControl
import com.opencapture.openzcine.diagnostics.AndroidDiagnosticEvent
import com.opencapture.openzcine.transport.UsbPtpCameraAccess

class CameraSessionDiagnosticsTest {
    @Test
    fun `pairing phase details never enter camera session diagnostics`() {
        assertNull(cameraSessionDiagnosticMessage("confirmOnCamera", "123456"))
        assertNull(cameraSessionDiagnosticMessage("handshaking", "192.168.1.1"))
        assertEquals("liveViewPreviewRejected", cameraSessionDiagnosticMessage("liveViewPreviewRejected", "123456"))
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
        assertEquals(
            "usb.handshake.write: ",
            cameraSessionDiagnosticMessage("usb.handshake.write", ""),
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
    fun `showing the USB permission prompt is not recorded as a failure`() {
        // OPENZCINE-ANDROID-D: every first connect logged error.connection.usb.permission
        // just for asking, which a reporter read as "the permission request fails each time".
        val asked = usbPermissionDiagnosticPhase(UsbPtpCameraAccess.NEEDS_PERMISSION)
        assertEquals(AndroidDiagnosticEvent.USB_PERMISSION_REQUESTED, AndroidDiagnosticEvent.fromPhase(asked))
        assertFalse(AndroidDiagnosticEvent.USB_PERMISSION_REQUESTED.wireValue.startsWith("error."))
        assertEquals(
            AndroidDiagnosticEvent.CONNECTION_USB_PERMISSION,
            AndroidDiagnosticEvent.fromPhase(usbPermissionDiagnosticPhase(UsbPtpCameraAccess.DENIED)),
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
