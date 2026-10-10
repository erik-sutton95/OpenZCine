package com.opencapture.openzcine

import com.opencapture.opencine.nikon.CameraRecordingState
import com.opencapture.opencine.nikon.LiveFrameSource

/**
 * Returns the monitor-owned live source only while a preview-bearing monitor
 * mode is visible. Command mode deliberately has no *preview* consumers, so
 * decode, scopes, audio and the wearable relay all stop there.
 *
 * This is not the whole story for command mode any more: the timecode readout
 * keeps the raw source (see `monitorTimecodeFrameSource`), because timecode
 * only exists in the live-view frame header.
 */
internal fun monitorPreviewFrameSource(
    source: LiveFrameSource?,
    isCommandMode: Boolean,
): LiveFrameSource? = source?.takeIf { !isCommandMode }

/**
 * The source the live-timecode readout observes.
 *
 * Command mode (DISP 3) hides the image but its hero readout *is* the timecode,
 * and timecode rides the live-view frame header only — there is no PTP timecode
 * property. Ending live view there froze the clock at whatever the last
 * pre-command frame carried, which reads as plausible and is actively wrong
 * while the camera rolls (#271). So the timecode collector deliberately keeps
 * the raw source in every DISP mode; everything else still drops out through
 * [monitorPreviewFrameSource].
 */
internal fun monitorTimecodeFrameSource(source: LiveFrameSource?): LiveFrameSource? = source

/**
 * Recording inputs for preview policy use confirmed camera state. A start is
 * not confirmed until the facade reports [CameraRecordingState.RECORDING],
 * while a stop keeps the active-take preview constraints until it succeeds.
 */
internal fun previewPolicyRecordingActive(state: CameraRecordingState): Boolean =
    state == CameraRecordingState.RECORDING || state == CameraRecordingState.STOPPING

/**
 * Whether the on-feed focus dial can drive the lens in the body's current focus mode.
 *
 * Kotlin mirror of `MFDriveEligibility` in the shared core — the rule lives there; this only
 * transcribes it, the way the rest of this file mirrors core monitor policy.
 */
internal enum class MfDriveEligibility {
    /** No dial: no focus mode read yet, or MF, where the lens ring owns focus. */
    UNAVAILABLE,

    /** Dial mounted but inert and dimmed: AF-F re-focuses continuously, overriding any drive. */
    BLOCKED_BY_CONTINUOUS_AF,

    /** AF-S and AF-C hold focus between acquisitions, so a pull sticks. */
    DRIVABLE,
}

/**
 * Resolves dial eligibility from the body's reported focus mode.
 *
 * Refusals are not a factor: `Device_Busy` (STM lens initialising) and `Access_Denied` (AF
 * settling) are always transient, so nothing about a refusal makes a lens undrivable.
 */
internal fun mfDriveEligibility(focusMode: String?): MfDriveEligibility =
    when (focusMode) {
        null, "MF" -> MfDriveEligibility.UNAVAILABLE
        "AF-F" -> MfDriveEligibility.BLOCKED_BY_CONTINUOUS_AF
        else -> MfDriveEligibility.DRIVABLE
    }
