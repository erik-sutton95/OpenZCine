package com.opencapture.openzcine.core

import kotlinx.coroutines.flow.Flow

/**
 * One decoded-ready live-view frame from the camera.
 *
 * Not a data class on purpose: frames carry a payload buffer, and
 * structural equality over frame bytes is never wanted.
 *
 * @property timestampNanos Monotonic capture timestamp of the frame.
 * @property jpegData JPEG-encoded frame payload as delivered by the camera.
 */
public class LiveFrame(
    public val timestampNanos: Long,
    public val jpegData: ByteArray,
)

/**
 * Emits live-view frames for a connected camera.
 *
 * Provided by the same backend as [CameraSession]; the shell collects
 * [frames] only while a session is [CameraSessionState.Connected].
 */
public interface LiveFrameSource {
    /** Stream of live-view frames. Completes when live view stops. */
    public val frames: Flow<LiveFrame>
}
