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

/** Camera-reported autofocus state for the primary AF box. */
public enum class LiveFocusResult {
    /** The camera did not report a recognized focus result. */
    UNKNOWN,
    /** The camera reports that the active AF point is not yet focused. */
    NOT_FOCUSED,
    /** The camera reports that the active AF point is in focus. */
    FOCUSED,
}

/**
 * One AF or subject-detection box in the camera's live-view coordinate space.
 *
 * The center and size remain in the camera's coordinate system. Presentation
 * code maps the box into the decoded frame's actual aspect-fit rectangle; it
 * must not assume that the monitor zone itself has the same aspect ratio.
 */
public data class LiveFocusBox(
    /** Horizontal centre in [LiveFocusInfo.coordinateWidth] units. */
    public val centerX: Int,
    /** Vertical centre in [LiveFocusInfo.coordinateHeight] units. */
    public val centerY: Int,
    /** Box width in camera coordinate units. */
    public val width: Int,
    /** Box height in camera coordinate units. */
    public val height: Int,
)

/**
 * Camera-derived AF and subject-detection metadata carried with one live frame.
 *
 * Kotlin receives already-decoded coordinates and state from the portable
 * Swift core; it never parses Nikon live-view headers. [isDebugFixture] is
 * true only for the debug synthetic feed and lets the UI avoid presenting
 * fixture boxes as camera data.
 */
public data class LiveFocusInfo(
    /** Camera coordinate-space width for every [boxes] entry. */
    public val coordinateWidth: Int,
    /** Camera coordinate-space height for every [boxes] entry. */
    public val coordinateHeight: Int,
    /** Focus state reported for the active AF point. */
    public val result: LiveFocusResult,
    /** Whether the camera reports face/subject detection as active. */
    public val subjectDetectionActive: Boolean,
    /** Whether the camera reports an active tracking-AF lock. */
    public val trackingAFActive: Boolean,
    /** Selected subject-box index, or `null` when the body did not select one. */
    public val selectedBoxIndex: Int?,
    /** AF point followed by any detected face or eye boxes. */
    public val boxes: List<LiveFocusBox>,
    /** True only when this metadata comes from the debug synthetic feed. */
    public val isDebugFixture: Boolean = false,
)

/**
 * Camera virtual-horizon angles already decoded by the portable Swift core.
 *
 * [rollDegrees] and [pitchDegrees] are signed about level (`-180…180`) so
 * Android only renders an operator readout and does not duplicate the Nikon
 * header or wrap policy. [isDebugFixture] is true only for synthetic debug
 * frames, never for the Swift camera bridge.
 */
public data class LiveCameraLevel(
    /** Signed horizon roll in degrees. */
    public val rollDegrees: Double,
    /** Signed fore/aft pitch in degrees. */
    public val pitchDegrees: Double,
    /** Camera yaw in degrees, retained for future camera-level instruments. */
    public val yawDegrees: Double,
    /** True only when this level comes from the debug synthetic feed. */
    public val isDebugFixture: Boolean = false,
)

/** Camera-owned timecode parsed from the same live-view header as [LiveFrame]. */
public data class LiveFrameTimecode(
    /** Whether the camera says the timecode readout is enabled. */
    public val on: Boolean,
    /** Hour component. */
    public val hour: Int,
    /** Minute component. */
    public val minute: Int,
    /** Second component. */
    public val second: Int,
    /** Frame component. */
    public val frame: Int,
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
 * @property focus Camera-derived AF and subject-detection data, or `null`
 *   when the live-view header did not contain valid focus metadata.
 * @property level Camera-derived virtual-horizon angles, or `null` when the
 *   camera did not report a reliable level.
 * @property timecode Camera-derived timecode from this frame's header.
 * @property measuredFramesPerSecond Measured delivery cadence calculated from
 *   consecutive monotonic frame timestamps, or `null` before it is known.
 */
public class LiveFrame(
    public val timestampNanos: Long,
    public val jpegData: ByteArray,
    public val isRecording: Boolean = false,
    public val audioLevels: LiveAudioMeterLevels? = null,
    public val focus: LiveFocusInfo? = null,
    public val level: LiveCameraLevel? = null,
    public val timecode: LiveFrameTimecode? = null,
    public val measuredFramesPerSecond: Double? = null,
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
