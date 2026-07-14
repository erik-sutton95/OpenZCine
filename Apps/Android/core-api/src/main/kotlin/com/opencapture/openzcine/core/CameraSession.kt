package com.opencapture.openzcine.core

import kotlinx.coroutines.flow.StateFlow

/**
 * Connection lifecycle of a [CameraSession].
 *
 * Failure detail states (why a connect attempt ended back at
 * [Disconnected]) land together with the real core backend.
 */
public sealed interface CameraSessionState {
    /** No camera is connected and no attempt is in flight. */
    public data object Disconnected : CameraSessionState

    /** A connection attempt is in progress. */
    public data object Connecting : CameraSessionState

    /** A camera is connected and ready for control. */
    public data class Connected(val identity: CameraIdentity) : CameraSessionState
}

/**
 * A control session with one camera — the seam the Android shell talks to.
 *
 * Implementations own transport, protocol, and threading; the shell only
 * observes [state] and drives the lifecycle. Either the shared Swift core
 * (bridged via JNI) or a Kotlin port of it provides the production
 * implementation behind this interface.
 */
public interface CameraSession {
    /** Current connection state, updated as the session progresses. */
    public val state: StateFlow<CameraSessionState>

    /**
     * Discovers and connects to a camera.
     *
     * Moves [state] through [CameraSessionState.Connecting] and ends at
     * [CameraSessionState.Connected] on success or back at
     * [CameraSessionState.Disconnected] when no camera is reachable.
     */
    public suspend fun connect()

    /** Tears down the session and returns [state] to [CameraSessionState.Disconnected]. */
    public suspend fun disconnect()
}
