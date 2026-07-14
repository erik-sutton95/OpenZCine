package com.opencapture.openzcine.core

import kotlinx.coroutines.flow.MutableSharedFlow
import kotlinx.coroutines.flow.SharedFlow
import kotlinx.coroutines.flow.StateFlow

private val noCameraSessionEvents: SharedFlow<CameraSessionEvent> =
    MutableSharedFlow<CameraSessionEvent>()

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
 * The camera's movie-record lifecycle as exposed to the Android shell.
 *
 * `STARTING` and `STOPPING` keep an accepted command visible while the camera
 * applies it; callers must not send a second command until the state returns
 * to a stable value.
 */
public enum class CameraRecordingState {
    /** The connected camera is not recording. */
    STANDBY,

    /** A start command is in flight. */
    STARTING,

    /** The camera is recording to its card. */
    RECORDING,

    /** A stop command is in flight. */
    STOPPING,
}

/**
 * One camera-pushed PTP event observed on a connected session's event socket.
 *
 * PTP event codes and parameters are unsigned wire values. Kotlin represents
 * them as non-negative [Int] / [Long] values so unknown Nikon events are
 * preserved instead of being decoded speculatively. Every variant retains the
 * complete wire fields through [rawEventCode], [transactionId], and
 * [rawParameters].
 */
public sealed interface CameraSessionEvent {
    /** The exact PTP event code sent by the camera (`0..0xFFFF`). */
    public val rawEventCode: Int

    /** The exact PTP transaction ID associated with this event (`0..0xFFFFFFFF`). */
    public val transactionId: Long

    /** All raw UINT32 event parameters in their original order. */
    public val rawParameters: List<Long>

    /** Nikon MovieRecordStarted (`0xC10A`), an authoritative recording transition. */
    public data class RecordingStarted(
        override val rawEventCode: Int,
        override val transactionId: Long,
        override val rawParameters: List<Long>,
    ) : CameraSessionEvent

    /** Nikon MovieRecordComplete (`0xC108`), an authoritative standby transition. */
    public data class RecordingStopped(
        override val rawEventCode: Int,
        override val transactionId: Long,
        override val rawParameters: List<Long>,
    ) : CameraSessionEvent

    /**
     * Nikon MovieRecordInterrupted (`0xC105`). [errorCode] is intentionally
     * raw: Nikon does not publish a stable table for this camera-provided
     * value, so callers must not label it as thermal, card, or buffer failure.
     */
    public data class RecordingInterrupted(
        override val rawEventCode: Int,
        override val transactionId: Long,
        override val rawParameters: List<Long>,
        val errorCode: Long?,
    ) : CameraSessionEvent

    /**
     * Standard DevicePropChanged (`0x4006`). [propertyCode] is its first raw
     * UINT32 parameter when present; no property value is invented by this
     * notification alone.
     */
    public data class PropertyChanged(
        override val rawEventCode: Int,
        override val transactionId: Long,
        override val rawParameters: List<Long>,
        val propertyCode: Long?,
    ) : CameraSessionEvent

    /** A valid camera event whose model-specific semantics are not known here. */
    public data class Unknown(
        override val rawEventCode: Int,
        override val transactionId: Long,
        override val rawParameters: List<Long>,
    ) : CameraSessionEvent
}

/** Typed failures from [CameraSession.setRecording]. */
public sealed class CameraRecordingException(message: String) : Exception(message) {
    /** A recording command needs a connected camera session. */
    public data object NotConnected :
        CameraRecordingException("Connect to a camera before changing recording.")

    /** The Swift protocol library was not bundled into the installed APK. */
    public data object CoreUnavailable :
        CameraRecordingException("The shared camera core is unavailable in this app build.")

    /** Camera media owns the serialized command channel. */
    public data object MediaBusy :
        CameraRecordingException("Close camera media before changing recording.")

    /** The camera received and rejected the Nikon recording command. */
    public data object CommandRejected :
        CameraRecordingException("The camera rejected the recording command.")

    /** This session implementation has no protocol path for recording control. */
    public data object Unsupported :
        CameraRecordingException("This camera connection cannot control recording.")

    /** The command channel failed before the camera confirmed the command. */
    public data object TransportFailed :
        CameraRecordingException("The camera connection failed while changing recording.")
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

    /** Current movie-record lifecycle for this session. */
    public val recordingState: StateFlow<CameraRecordingState>

    /**
     * Camera-pushed PTP events from the active event channel.
     *
     * Production sessions use a bounded, non-blocking stream so slow UI
     * collectors cannot back up the camera socket. Implementations without an
     * event-capable transport expose an empty stream.
     */
    public val events: SharedFlow<CameraSessionEvent>
        get() = noCameraSessionEvents

    /**
     * Discovers and connects to a camera.
     *
     * Moves [state] through [CameraSessionState.Connecting] and ends at
     * [CameraSessionState.Connected] on success or back at
     * [CameraSessionState.Disconnected] when no camera is reachable.
     */
    public suspend fun connect()

    /**
     * Starts or stops movie recording on the connected camera.
     *
     * Implementations serialize this with their live-view and teardown work,
     * then update [recordingState] only after the camera accepts the command.
     * A failure is reported as a typed [CameraRecordingException].
     */
    @Throws(CameraRecordingException::class)
    public suspend fun setRecording(recording: Boolean)

    /** Tears down the session and returns [state] to [CameraSessionState.Disconnected]. */
    public suspend fun disconnect()
}
