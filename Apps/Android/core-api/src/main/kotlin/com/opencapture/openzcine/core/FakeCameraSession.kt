package com.opencapture.openzcine.core

import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow

/**
 * In-memory [CameraSession] used until a real core backend lands.
 *
 * Drives the documented state machine without any I/O: [connect] moves
 * through [CameraSessionState.Connecting] and connects to [discoverable]
 * when one is provided, otherwise falls back to
 * [CameraSessionState.Disconnected] (the "no camera found" outcome).
 *
 * @property discoverable The camera this fake "finds", or `null` to
 *   simulate an empty network.
 */
public class FakeCameraSession(
    private val discoverable: CameraIdentity? = null,
) : CameraSession {
    private val mutableState = MutableStateFlow<CameraSessionState>(CameraSessionState.Disconnected)
    private val mutableRecordingState = MutableStateFlow(CameraRecordingState.STANDBY)

    override val state: StateFlow<CameraSessionState> = mutableState.asStateFlow()
    override val recordingState: StateFlow<CameraRecordingState> =
        mutableRecordingState.asStateFlow()

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

    override suspend fun disconnect() {
        mutableState.value = CameraSessionState.Disconnected
        mutableRecordingState.value = CameraRecordingState.STANDBY
    }
}
