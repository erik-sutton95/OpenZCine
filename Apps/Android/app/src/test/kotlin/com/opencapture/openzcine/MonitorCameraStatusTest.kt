package com.opencapture.openzcine

import com.opencapture.openzcine.core.CameraIdentity
import com.opencapture.openzcine.core.CameraSessionState
import com.opencapture.openzcine.frameio.FrameioCameraRejoinEvidence
import com.opencapture.openzcine.frameio.FrameioInternetHopState
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertIs
import kotlin.test.assertTrue

class MonitorCameraStatusTest {
    @Test
    fun `disconnected without hop shows no camera`() {
        val status =
            resolveMonitorCameraStatus(
                CameraSessionState.Disconnected,
                hopState = null,
            )
        assertEquals(MonitorCameraStatus.NoCamera, status)
        assertFalse(status.showsProgress())
    }

    @Test
    fun `connecting without hop shows connecting with progress`() {
        val status =
            resolveMonitorCameraStatus(
                CameraSessionState.Connecting,
                hopState = FrameioInternetHopState.Idle,
            )
        assertEquals(MonitorCameraStatus.Connecting, status)
        assertTrue(status.showsProgress())
    }

    @Test
    fun `rejoining hop overrides disconnected no-camera`() {
        val status =
            resolveMonitorCameraStatus(
                CameraSessionState.Disconnected,
                hopState = FrameioInternetHopState.RejoiningCamera,
            )
        assertEquals(MonitorCameraStatus.HopRejoining, status)
        assertTrue(status.showsProgress())
    }

    @Test
    fun `online hop while disconnected shows reconnecting not no camera`() {
        val status =
            resolveMonitorCameraStatus(
                CameraSessionState.Disconnected,
                hopState = FrameioInternetHopState.Online,
            )
        assertEquals(MonitorCameraStatus.HopReconnecting, status)
        assertTrue(status.showsProgress())
    }

    @Test
    fun `hop failed surfaces failure while disconnected`() {
        val status =
            resolveMonitorCameraStatus(
                CameraSessionState.Disconnected,
                hopState = FrameioInternetHopState.Failed("Wi-Fi join timed out."),
            )
        val failed = assertIs<MonitorCameraStatus.HopFailed>(status)
        assertEquals("Wi-Fi join timed out.", failed.message)
        assertFalse(status.showsProgress())
    }

    @Test
    fun `connected session ignores hop rejoined messaging`() {
        val status =
            resolveMonitorCameraStatus(
                CameraSessionState.Connected(
                    identity = CameraIdentity(name = "ZR", model = "ZR", serialNumber = "1"),
                ),
                hopState =
                    FrameioInternetHopState.Rejoined(
                        FrameioCameraRejoinEvidence(
                            cameraName = "ZR",
                            cameraModel = "ZR",
                            verifiedAtEpochMillis = 1L,
                        ),
                    ),
            )
        val connected = assertIs<MonitorCameraStatus.Connected>(status)
        assertEquals("ZR", connected.name)
    }

    @Test
    fun `rejoined hop while still connecting shows restoring progress`() {
        val status =
            resolveMonitorCameraStatus(
                CameraSessionState.Connecting,
                hopState =
                    FrameioInternetHopState.Rejoined(
                        FrameioCameraRejoinEvidence(
                            cameraName = "ZR",
                            cameraModel = "ZR",
                            verifiedAtEpochMillis = 1L,
                        ),
                    ),
            )
        assertEquals(MonitorCameraStatus.HopRejoinedRestoring, status)
        assertTrue(status.showsProgress())
    }
}
