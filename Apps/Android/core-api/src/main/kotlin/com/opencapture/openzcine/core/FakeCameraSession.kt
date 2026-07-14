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

    override val state: StateFlow<CameraSessionState> = mutableState.asStateFlow()

    override suspend fun connect() {
        mutableState.value = CameraSessionState.Connecting
        mutableState.value =
            discoverable?.let { CameraSessionState.Connected(it) }
                ?: CameraSessionState.Disconnected
    }

    override suspend fun disconnect() {
        mutableState.value = CameraSessionState.Disconnected
    }
}
