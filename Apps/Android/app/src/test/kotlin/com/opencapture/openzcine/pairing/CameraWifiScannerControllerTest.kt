package com.opencapture.openzcine.pairing

import com.google.mlkit.common.MlKitException
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

    @Test
    fun `opening the text recognizer never throws into the scanner UI`() {
        // On JVM unit tests ML Kit may return a client or fail soft (null). Either is fine —
        // the production scanner must not crash when getClient throws NullPointerException.
        var faults = 0
        val client = openCameraWifiTextRecognizer(onFault = { faults += 1 })
        // The cause is classified rather than swallowed: null and a reported fault
        // always travel together, so the UI can pick permanent vs retryable.
        assertEquals(if (client == null) 1 else 0, faults)
        client?.close()
    }

    @Test
    fun `a missing model or stripped class is permanent, everything else may clear`() {
        assertEquals(
            CameraWifiRecognizerFault.PERMANENT,
            cameraWifiRecognizerFault(UnsatisfiedLinkError("libmlkit_google_ocr_pipeline.so")),
        )
        assertEquals(
            CameraWifiRecognizerFault.PERMANENT,
            cameraWifiRecognizerFault(NoClassDefFoundError("com.google.mlkit.vision.text.Foo")),
        )
        // MlKitException cannot be constructed on the JVM (its constructor reaches
        // android.text.TextUtils), so its codes are asserted through the split-out
        // mapping the production classifier delegates to.
        assertEquals(
            CameraWifiRecognizerFault.PERMANENT,
            cameraWifiMlKitFault(MlKitException.NOT_FOUND),
        )
        assertEquals(
            CameraWifiRecognizerFault.PERMANENT,
            cameraWifiMlKitFault(MlKitException.UNIMPLEMENTED),
        )
        assertEquals(
            CameraWifiRecognizerFault.TRANSIENT,
            cameraWifiMlKitFault(MlKitException.UNAVAILABLE),
        )
        // The historic Play Vitals crash inside getClient must stay recoverable.
        assertEquals(
            CameraWifiRecognizerFault.TRANSIENT,
            cameraWifiRecognizerFault(NullPointerException()),
        )
    }

    @Test
    fun `the recognizer warms up for a few frames before OCR is called unavailable`() {
        val health = CameraWifiRecognizerHealth(tolerance = 2)
        val warmingUp = IllegalStateException("pipeline still loading")

        assertNull(health.recordFailure(warmingUp))
        assertNull(health.recordFailure(warmingUp))
        assertEquals(
            CameraWifiScannerFailure.RECOGNIZER_UNAVAILABLE,
            health.recordFailure(warmingUp),
        )
    }

    @Test
    fun `one good frame restores the warm-up budget and a permanent fault skips it`() {
        val health = CameraWifiRecognizerHealth(tolerance = 2)

        assertNull(health.recordFailure(IllegalStateException("blip")))
        assertNull(health.recordFailure(IllegalStateException("blip")))
        health.recordSuccess()
        assertNull(health.recordFailure(IllegalStateException("blip")))

        assertEquals(
            CameraWifiScannerFailure.RECOGNIZER_UNSUPPORTED,
            CameraWifiRecognizerHealth(tolerance = 99)
                .recordFailure(UnsatisfiedLinkError("no pipeline")),
        )
    }

    @Test
    fun `only a recoverable failure offers Try again, and both OCR faults are reportable`() {
        assertTrue(
            cameraWifiScannerFailureIsRetryable(CameraWifiScannerFailure.RECOGNIZER_UNAVAILABLE)
        )
        assertFalse(
            cameraWifiScannerFailureIsRetryable(CameraWifiScannerFailure.RECOGNIZER_UNSUPPORTED)
        )
        assertEquals(
            "failed.scannerRecognizer",
            cameraWifiScannerDiagnosticPhase(CameraWifiScannerFailure.RECOGNIZER_UNAVAILABLE),
        )
        assertEquals(
            "failed.scannerRecognizerUnsupported",
            cameraWifiScannerDiagnosticPhase(CameraWifiScannerFailure.RECOGNIZER_UNSUPPORTED),
        )
    }

    @Test
    fun `manual entry decodes only a fully validated shared-core result`() {
        val validating =
            CameraWifiManualParser { ssid, key ->
                "$ssid${CAMERA_WIFI_CREDENTIAL_WIRE_SEPARATOR}$key"
            }

        val candidate =
            assertNotNull(cameraWifiManualCandidate(validating, "NIKON_Z6III_00042", "abcd1234"))
        assertEquals("NIKON_Z6III_00042", candidate.ssid)
        assertEquals("abcd1234", candidate.key)
        // Swift rejecting either field, or an absent core, can never become a candidate.
        assertNull(cameraWifiManualCandidate({ _, _ -> null }, "NIKON_ZR_01234", "short"))
    }
}
