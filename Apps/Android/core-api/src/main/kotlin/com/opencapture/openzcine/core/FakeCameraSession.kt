package com.opencapture.openzcine.core

import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update

/**
 * In-memory [CameraSession] used by debug demo feeds and unit/UI tests.
 *
 * Drives the documented state machine without any I/O: [connect] moves
 * through [CameraSessionState.Connecting] and connects to [discoverable]
 * when one is provided, otherwise falls back to
 * [CameraSessionState.Disconnected] (the "no camera found" outcome).
 *
 * Seeds resolution/codec readouts and option lists so demo chrome can open
 * the same drums iOS shows in `CameraDisplayState.preview` / demo sessions.
 * [applyControl] applies those two controls locally (no PTP).
 *
 * @property discoverable The camera this fake "finds", or `null` to
 *   simulate an empty network.
 */
public class FakeCameraSession(
    private val discoverable: CameraIdentity? = null,
) : CameraSession {
    private val mutableState = MutableStateFlow<CameraSessionState>(CameraSessionState.Disconnected)
    private val mutableRecordingState = MutableStateFlow(CameraRecordingState.STANDBY)
    private val mutableProperties = MutableStateFlow(DEMO_PROPERTIES)

    override val state: StateFlow<CameraSessionState> = mutableState.asStateFlow()
    override val recordingState: StateFlow<CameraRecordingState> =
        mutableRecordingState.asStateFlow()
    override val cameraProperties: StateFlow<CameraPropertySnapshot> =
        mutableProperties.asStateFlow()
    override val propertyRefreshStatus: StateFlow<CameraPropertyRefreshStatus> =
        MutableStateFlow(CameraPropertyRefreshStatus.Ready)

    override suspend fun connect() {
        mutableState.value = CameraSessionState.Connecting
        mutableState.value =
            discoverable?.let { CameraSessionState.Connected(it) }
                ?: CameraSessionState.Disconnected
    }

    override suspend fun setRecording(recording: Boolean) {
        if (mutableState.value !is CameraSessionState.Connected) {
            throw CameraRecordingException.NotConnected
        }
        mutableRecordingState.value =
            if (recording) CameraRecordingState.STARTING else CameraRecordingState.STOPPING
        mutableRecordingState.value =
            if (recording) CameraRecordingState.RECORDING else CameraRecordingState.STANDBY
    }

    override suspend fun applyControl(control: CameraControl, label: String) {
        if (mutableState.value !is CameraSessionState.Connected) {
            throw CameraControlException.NotConnected
        }
        when (control) {
            CameraControl.RESOLUTION_FRAMERATE ->
                mutableProperties.update { it.copy(resolutionFrameRate = label) }
            CameraControl.CODEC ->
                mutableProperties.update {
                    it.copy(codec = label, codecSelection = label)
                }
            else -> throw CameraControlException.UnsupportedSelection
        }
    }

    override suspend fun disconnect() {
        mutableState.value = CameraSessionState.Disconnected
        mutableRecordingState.value = CameraRecordingState.STANDBY
        mutableProperties.value = DEMO_PROPERTIES
    }

    private companion object {
        /** Mirrors iOS demo seeds + `CameraPicker.options` for resolution/codec. */
        val DEMO_PROPERTIES =
            CameraPropertySnapshot(
                resolutionFrameRate = "6K · 25p",
                codec = "R3D NE",
                codecSelection = "R3D NE",
                controlCapabilities =
                    CameraControlCapabilities(
                        resolutionFrameRates =
                            listOf(
                                "6K · 24p",
                                "6K · 25p",
                                "6K · 30p",
                                "6K · 50p",
                                "4K · 60p",
                            ),
                        codecs =
                            listOf(
                                "R3D NE",
                                "N-RAW",
                                "ProRes RAW HQ",
                                "ProRes 422 HQ",
                                "H.265 10-bit",
                            ),
                    ),
            )
    }
}
