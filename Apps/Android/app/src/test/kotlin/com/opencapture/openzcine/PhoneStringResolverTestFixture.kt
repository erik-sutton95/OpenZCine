package com.opencapture.openzcine

import com.opencapture.openzcine.core.CameraPropertyRefreshStatus
import com.opencapture.openzcine.core.CameraPropertySnapshot
import com.opencapture.openzcine.core.CameraSessionState

internal val testPhoneStrings =
    PhoneStringResolver { resource, args ->
        when (resource) {
            R.string.command_section_image -> "Image"
            R.string.command_section_exposure -> "Exposure"
            R.string.command_section_focus -> "Focus"
            R.string.command_section_audio -> "Audio"
            R.string.command_title_tone -> "Tone"
            R.string.command_title_evr -> "e-VR"
            R.string.temperature_ok -> "OK"
            R.string.command_failure_unsupported -> "Limited by camera"
            R.string.command_limited_readback ->
                "Camera property readback is limited: ${args[0]}."
            R.string.command_reason_aperture ->
                "This camera did not provide apertures for the mounted lens."
            R.string.command_reason_evr ->
                "Electronic VR is unavailable for this camera or active codec."
            R.string.command_shutter_wait_lock -> "Waiting for the camera shutter lock state."
            R.string.command_shutter_locked -> "Shutter is locked on the camera."
            R.string.command_iso_recording_locked -> "ISO is locked while recording in R3D NE."
            R.string.command_iso_recording_wait ->
                "ISO is unavailable during recording until codec readback completes."
            else -> "resource-$resource"
        }
    }

/** Test-only overload that keeps pure dashboard fixtures independent of Android resources. */
internal fun commandDashboardPresentation(
    snapshot: CameraPropertySnapshot,
    refreshStatus: CameraPropertyRefreshStatus,
    sessionState: CameraSessionState,
    tileOrder: List<CommandTileKind>,
    recording: Boolean = false,
): CommandDashboardPresentation =
    commandDashboardPresentation(
        snapshot = snapshot,
        refreshStatus = refreshStatus,
        sessionState = sessionState,
        tileOrder = tileOrder,
        strings = testPhoneStrings,
        recording = recording,
    )
