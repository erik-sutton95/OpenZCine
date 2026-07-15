package com.opencapture.openzcine.core

import kotlinx.coroutines.flow.Flow

/**
 * One camera-derived channel in the live-view audio meter.
 *
 * Values are already normalized to dBFS by the shared Swift core. Android
 * renders these values directly and never infers Nikon header offsets or
 * applies separate meter ballistics.
 *
 * @property levelDb Current bar level in dBFS.
 * @property peakDb Camera-provided peak-hold level in dBFS.
 */
public data class LiveAudioMeterChannel(
    public val levelDb: Double,
    public val peakDb: Double,
)

/**
 * Stereo audio-meter metadata accompanying one [LiveFrame].
 *
 * `null` on [LiveFrame.audioLevels] means the camera did not include a sound
 * indicator in that live-view header. A debug-only feed may set
 * [isDebugFixture] so the monitor can clearly distinguish synthetic bars from
 * camera data.
 */
public data class LiveAudioMeterLevels(
    /** Left-channel level and camera peak-hold marker. */
    public val left: LiveAudioMeterChannel,
    /** Right-channel level and camera peak-hold marker. */
    public val right: LiveAudioMeterChannel,
    /** True only for the debug synthetic feed; never set by the Swift camera bridge. */
    public val isDebugFixture: Boolean = false,
)

/**
 * One decoded-ready live-view frame from the camera.
 *
 * Not a data class on purpose: frames carry a payload buffer, and
 * structural equality over frame bytes is never wanted.
 *
 * @property timestampNanos Monotonic capture timestamp of the frame.
 * @property jpegData JPEG-encoded frame payload as delivered by the camera.
 * @property isRecording Whether the camera reported card recording in this
 *   frame's live-view header.
 * @property audioLevels Camera-derived stereo meter values, or `null` when
 *   the live-view header did not contain a sound indicator.
 */
public class LiveFrame(
    public val timestampNanos: Long,
    public val jpegData: ByteArray,
    public val isRecording: Boolean = false,
    public val audioLevels: LiveAudioMeterLevels? = null,
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
