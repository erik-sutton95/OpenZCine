package com.opencapture.openzcine.remote

import com.opencapture.openzcine.core.CameraSession

/**
 * Whether the front monitor is in a safe state to claim Android media keys.
 *
 * This is deliberately separate from the key adapter so every control-surface
 * transition stays testable and a remote can never bypass a visible record
 * confirmation or a camera command that is already in flight.
 */
internal fun shouldArmMediaRemoteShutter(
    enabled: Boolean,
    monitorIsFront: Boolean,
    cameraConnected: Boolean,
    recordCommandPending: Boolean,
    applicationResumed: Boolean,
    recordConfirmationPending: Boolean,
    cameraControlPending: Boolean,
): Boolean =
    enabled &&
        monitorIsFront &&
        cameraConnected &&
        !recordCommandPending &&
        applicationResumed &&
        !recordConfirmationPending &&
        !cameraControlPending

/** Returns the safe camera target for one remote command, or null for a no-op. */
internal fun mediaRemoteShutterRecordingTarget(
    command: MediaRemoteShutterCommand,
    isRecording: Boolean,
): Boolean? =
    when (command) {
        MediaRemoteShutterCommand.TOGGLE -> !isRecording
        MediaRemoteShutterCommand.START -> if (isRecording) null else true
        MediaRemoteShutterCommand.STOP -> if (isRecording) false else null
    }

/**
 * Routes an accepted remote command through the existing [CameraSession]
 * record seam. Remote commands intentionally bypass the phone-side
 * confirmation dialog: an operator cannot answer that dialog from a remote.
 */
internal suspend fun routeMediaRemoteShutterCommand(
    session: CameraSession,
    command: MediaRemoteShutterCommand,
    isRecording: Boolean,
    recordControlEnabled: Boolean,
): Boolean {
    if (!recordControlEnabled) return false
    val target = mediaRemoteShutterRecordingTarget(command, isRecording) ?: return false
    session.setRecording(target)
    return true
}
