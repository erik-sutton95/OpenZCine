package com.opencapture.openzcine.remote

import com.opencapture.opencine.appkit.MonitorRemoteShutterCommand
import com.opencapture.opencine.appkit.monitorRemoteShutterRecordingTarget
import com.opencapture.opencine.nikon.CameraSession

/**
 * Routes an accepted remote command from OpenCine's `MonitorRemoteShutter` through the existing
 * [CameraSession] record seam. Remote commands intentionally bypass the phone-side confirmation
 * dialog: an operator cannot answer that dialog from a remote.
 */
internal suspend fun routeMediaRemoteShutterCommand(
    session: CameraSession,
    command: MonitorRemoteShutterCommand,
    isRecording: Boolean,
    recordControlEnabled: Boolean,
): Boolean {
    if (!recordControlEnabled) return false
    val target = monitorRemoteShutterRecordingTarget(command, isRecording) ?: return false
    session.setRecording(target)
    return true
}
