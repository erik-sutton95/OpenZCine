package com.opencapture.openzcine.frameio

import com.opencapture.openzcine.core.CameraIdentity
import com.opencapture.openzcine.core.CameraRecordingState
import com.opencapture.openzcine.core.CameraSession
import com.opencapture.openzcine.core.CameraSessionState
import com.opencapture.openzcine.pairing.PairedCamera
import com.opencapture.openzcine.pairing.PairingCredentials
import com.opencapture.openzcine.pairing.PairingEnvironment
import com.opencapture.openzcine.pairing.SavedCameraRecord
import com.opencapture.openzcine.pairing.SavedCameraTransport
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNotNull
import kotlin.test.assertNull
import kotlin.test.assertTrue
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.emptyFlow
import kotlinx.coroutines.test.runTest

class FrameioCameraApHopTest {
    @Test
    fun `availability distinguishes fixture topology and missing credential`() {
        val record = savedCamera()

        assertEquals(
            FrameioHopAvailability.FIXTURE_UNAVAILABLE,
            frameioHopAvailability(record, fixtureSession = true, credentialAvailable = true),
        )
        assertEquals(
            FrameioHopAvailability.NOT_CAMERA_ACCESS_POINT,
            frameioHopAvailability(
                record.copy(transport = SavedCameraTransport.PHONE_HOTSPOT),
                fixtureSession = false,
                credentialAvailable = true,
            ),
        )
        assertEquals(
            FrameioHopAvailability.MISSING_SAVED_PROFILE,
            frameioHopAvailability(record, fixtureSession = false, credentialAvailable = false),
        )
        assertEquals(
            FrameioHopAvailability.READY,
            frameioHopAvailability(record, fixtureSession = false, credentialAvailable = true),
        )
    }

    @Test
    fun `hop releases only after disconnect and rejoins with connected session evidence`() = runTest {
        val active = FakeSession(connectSucceeds = true, initiallyConnected = true)
        val harness = EnvironmentHarness()
        var handedOff: PairedCamera? = null
        val hop =
            AndroidFrameioCameraApHop(
                activeSession = active,
                savedCamera = savedCamera(),
                environment = harness.environment,
                fixtureSession = false,
                onReconnected = { handedOff = it },
                clock = { 456_000L },
            )

        assertTrue(hop.leaveCameraNetwork())
        assertEquals(1, active.disconnectCalls)
        assertEquals(1, harness.releaseCalls)

        val evidence = hop.rejoinCameraNetwork()

        assertNotNull(evidence)
        assertEquals("Nikon ZR", evidence.cameraName)
        assertEquals(456_000L, evidence.verifiedAtEpochMillis)
        assertEquals(1, harness.joinCalls)
        assertNotNull(handedOff)
        assertEquals(456_000L, handedOff.savedCamera.lastSeenAtEpochMillis)
        assertTrue(handedOff.session === active)
    }

    @Test
    fun `failed replacement never emits rejoin evidence`() = runTest {
        val active = FakeSession(connectSucceeds = false, initiallyConnected = true)
        val harness = EnvironmentHarness()
        var handedOff = false
        val hop =
            AndroidFrameioCameraApHop(
                activeSession = active,
                savedCamera = savedCamera(),
                environment = harness.environment,
                fixtureSession = false,
                onReconnected = { handedOff = true },
            )

        assertTrue(hop.leaveCameraNetwork())
        assertNull(hop.rejoinCameraNetwork())
        assertFalse(handedOff)
        assertEquals(2, active.disconnectCalls)
        assertEquals(2, harness.releaseCalls)
    }

    private fun savedCamera(): SavedCameraRecord =
        SavedCameraRecord(
            host = "192.168.1.1",
            cameraName = "Nikon ZR",
            transport = SavedCameraTransport.CAMERA_ACCESS_POINT,
            lastSeenAtEpochMillis = 100L,
            wifiSsid = "NIKON_ZR_UNIT",
        )

    private class EnvironmentHarness {
        var joinCalls = 0
        var releaseCalls = 0

        val environment =
            PairingEnvironment(
                joinCameraAp = { ssid, passphrase ->
                    joinCalls += 1
                    ssid == "NIKON_ZR_UNIT" && passphrase == "unit-passphrase"
                },
                releaseCameraAp = { releaseCalls += 1 },
                hotspotCameras = emptyFlow(),
                createSession = { error("A Frame.io rejoin reuses the monitor session owner") },
                usbCameraSource = null,
                createUsbSession = { error("USB is not used by this test") },
                credentials =
                    object : PairingCredentials {
                        override var lastSsid: String? = null

                        override fun passphrase(ssid: String): String? =
                            "unit-passphrase".takeIf { ssid == "NIKON_ZR_UNIT" }

                        override fun save(ssid: String, passphrase: String) = Unit
                    },
            )
    }

    private class FakeSession(
        private val connectSucceeds: Boolean,
        initiallyConnected: Boolean = false,
    ) : CameraSession {
        private val identity = CameraIdentity("Nikon ZR", "ZR", "unit-serial")
        private val mutableState =
            MutableStateFlow<CameraSessionState>(
                if (initiallyConnected) CameraSessionState.Connected(identity)
                else CameraSessionState.Disconnected,
            )
        override val state = mutableState
        override val recordingState = MutableStateFlow(CameraRecordingState.STANDBY)
        var disconnectCalls = 0

        override suspend fun connect() {
            mutableState.value = CameraSessionState.Connecting
            mutableState.value =
                if (connectSucceeds) CameraSessionState.Connected(identity)
                else CameraSessionState.Disconnected
        }

        override suspend fun setRecording(recording: Boolean) = Unit

        override suspend fun disconnect() {
            disconnectCalls += 1
            mutableState.value = CameraSessionState.Disconnected
        }
    }
}
