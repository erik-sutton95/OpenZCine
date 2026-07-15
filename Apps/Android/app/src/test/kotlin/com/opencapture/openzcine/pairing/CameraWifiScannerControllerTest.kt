package com.opencapture.openzcine.pairing

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNotNull
import kotlin.test.assertNull
import kotlin.test.assertTrue

class CameraWifiScannerControllerTest {
    @Test
    fun `accepts one complete shared-core wire result until the operator rescans`() {
        val controller =
            CameraWifiScannerController(
                CameraWifiTranscriptParser {
                    "NIKON_ZR_01234${CAMERA_WIFI_CREDENTIAL_WIRE_SEPARATOR}a1b2c3d4"
                },
            )

        val candidate = controller.acceptTranscript("ephemeral ML Kit text")

        assertEquals("NIKON_ZR_01234", candidate?.ssid)
        assertEquals("a1b2c3d4", candidate?.key)
        assertNull(controller.acceptTranscript("another frame"))

        controller.rescan()
        assertEquals("NIKON_ZR_01234", controller.acceptTranscript("fresh frame")?.ssid)
    }

    @Test
    fun `invalid OCR or malformed native payload never becomes a candidate`() {
        val invalidOcr = CameraWifiScannerController(CameraWifiTranscriptParser { null })
        val malformedWire = CameraWifiScannerController(CameraWifiTranscriptParser { "one-field" })

        assertNull(invalidOcr.acceptTranscript("incomplete camera text"))
        assertNull(malformedWire.acceptTranscript("untrusted native payload"))
    }

    @Test
    fun `candidate diagnostics redact the key and close rejects late frames`() {
        val secret = "a1b2c3d4"
        val controller =
            CameraWifiScannerController(
                CameraWifiTranscriptParser {
                    "NIKON_ZR_01234${CAMERA_WIFI_CREDENTIAL_WIRE_SEPARATOR}$secret"
                },
            )

        val candidate = assertNotNull(controller.acceptTranscript("valid camera text"))
        controller.close()

        assertFalse(candidate.toString().contains(secret))
        assertFalse(candidate.toString().contains("NIKON_ZR_01234"))
        assertNull(controller.acceptTranscript("late frame after dismissal"))
    }

    @Test
    fun `scanner dismissal closes the analysis gate and releases its in-flight frame`() {
        val gate = CameraWifiAnalysisGate()
        var frameClosed = false

        assertTrue(gate.tryAcquireFrame())
        gate.stop()
        gate.releaseFrame { frameClosed = true }

        assertTrue(frameClosed)
        assertFalse(gate.isOpen())
        assertFalse(gate.tryAcquireFrame())
    }

    @Test
    fun `first camera denial keeps an in-app retry before Settings`() {
        assertFalse(shouldOpenCameraPermissionSettings(denialCount = 1, canRequestAgain = false))
        assertFalse(shouldOpenCameraPermissionSettings(denialCount = 2, canRequestAgain = true))
        assertTrue(shouldOpenCameraPermissionSettings(denialCount = 2, canRequestAgain = false))
    }
}
