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
    }
}
