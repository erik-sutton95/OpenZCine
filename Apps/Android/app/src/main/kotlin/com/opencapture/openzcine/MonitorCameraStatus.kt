package com.opencapture.openzcine

import com.opencapture.opencine.cameracontrols.MonitorOperatorPictureNotice
import androidx.compose.runtime.Composable
import androidx.compose.ui.res.stringResource
import com.opencapture.opencine.nikon.CameraSessionState
import com.opencapture.opencine.frameio.FrameioInternetHopState

/**
 * Operator-facing feed status when live view is not available.
 *
 * After a RED / Frame.io internet hop the session is often
 * [CameraSessionState.Disconnected] for several seconds while Wi‑Fi rejoins.
 * Surfacing only "No camera" reads as a failure even though reconnect is in
 * progress — hop state is the reliable signal for that path.
 */
internal sealed interface MonitorCameraStatus {
    /** [readingSettings]: the post-connect property bootstrap still holds live view back. */
    data class Connected(val name: String, val readingSettings: Boolean = false) : MonitorCameraStatus

    data object Connecting : MonitorCameraStatus

    data object NoCamera : MonitorCameraStatus

    data object HopLeavingCamera : MonitorCameraStatus

    data object HopWaitingForInternet : MonitorCameraStatus

    data object HopReconnecting : MonitorCameraStatus

    data object HopRejoining : MonitorCameraStatus

    data object HopRejoinedRestoring : MonitorCameraStatus

    data class HopFailed(val message: String) : MonitorCameraStatus
}

/**
 * Resolves feed placeholder status from session + shared hop lifecycle.
 *
 * [hopState] may be null when no Frame.io / RED hop controller is attached.
 */
internal fun resolveMonitorCameraStatus(
    sessionState: CameraSessionState,
    hopState: FrameioInternetHopState?,
    initialPropertiesReady: Boolean = true,
): MonitorCameraStatus {
    if (sessionState !is CameraSessionState.Connected) {
        when (hopState) {
            FrameioInternetHopState.LeavingCamera -> return MonitorCameraStatus.HopLeavingCamera
            FrameioInternetHopState.WaitingForInternet ->
                return MonitorCameraStatus.HopWaitingForInternet
            FrameioInternetHopState.Online -> return MonitorCameraStatus.HopReconnecting
            FrameioInternetHopState.RejoiningCamera -> return MonitorCameraStatus.HopRejoining
            is FrameioInternetHopState.Failed ->
                return MonitorCameraStatus.HopFailed(hopState.message)
            is FrameioInternetHopState.Rejoined ->
                return MonitorCameraStatus.HopRejoinedRestoring
            FrameioInternetHopState.Idle, null -> Unit
        }
    }

    return when (sessionState) {
        is CameraSessionState.Connected ->
            MonitorCameraStatus.Connected(sessionState.identity.name, readingSettings = !initialPropertiesReady)
        CameraSessionState.Connecting -> MonitorCameraStatus.Connecting
        CameraSessionState.Disconnected -> MonitorCameraStatus.NoCamera
    }
}

/** Whether this status represents an in-progress search / rejoin (show spinner). */
internal fun MonitorCameraStatus.showsProgress(): Boolean =
    when (this) {
        is MonitorCameraStatus.Connected -> readingSettings
        MonitorCameraStatus.NoCamera,
        is MonitorCameraStatus.HopFailed,
        -> false
        MonitorCameraStatus.Connecting,
        MonitorCameraStatus.HopLeavingCamera,
        MonitorCameraStatus.HopWaitingForInternet,
        MonitorCameraStatus.HopReconnecting,
        MonitorCameraStatus.HopRejoining,
        MonitorCameraStatus.HopRejoinedRestoring,
        -> true
    }

/** TalkBack / accessibility one-line description for the monitor feed. */
@Composable
internal fun monitorCameraStatusAccessibility(status: MonitorCameraStatus): String =
    when (status) {
        is MonitorCameraStatus.Connected -> stringResource(R.string.camera_connected)
        MonitorCameraStatus.Connecting -> stringResource(R.string.camera_connecting)
        MonitorCameraStatus.NoCamera -> stringResource(R.string.camera_disconnected)
        MonitorCameraStatus.HopLeavingCamera -> stringResource(R.string.camera_hop_leaving_title)
        MonitorCameraStatus.HopWaitingForInternet ->
            stringResource(R.string.camera_hop_waiting_internet_title)
        MonitorCameraStatus.HopReconnecting ->
            stringResource(R.string.camera_hop_reconnecting_title)
        MonitorCameraStatus.HopRejoining -> stringResource(R.string.camera_hop_rejoining_title)
        MonitorCameraStatus.HopRejoinedRestoring ->
            stringResource(R.string.camera_hop_rejoined_title)
        is MonitorCameraStatus.HopFailed -> stringResource(R.string.camera_hop_failed_title)
    }

/**
 * The picture well's words when there is no live feed (no camera, connecting, or a RED / Frame.io
 * internet hop), shown on the shared waiting plate: title, optional detail, spinner while in progress.
 */
@Composable
internal fun monitorCameraStatusNotice(status: MonitorCameraStatus): MonitorOperatorPictureNotice {
    val title =
        when (status) {
            is MonitorCameraStatus.Connected ->
                if (status.readingSettings) stringResource(R.string.camera_reading_properties) else status.name
            MonitorCameraStatus.Connecting -> stringResource(R.string.camera_connecting_short)
            MonitorCameraStatus.NoCamera -> stringResource(R.string.camera_none)
            MonitorCameraStatus.HopLeavingCamera ->
                stringResource(R.string.camera_hop_leaving_title)
            MonitorCameraStatus.HopWaitingForInternet ->
                stringResource(R.string.camera_hop_waiting_internet_title)
            MonitorCameraStatus.HopReconnecting ->
                stringResource(R.string.camera_hop_reconnecting_title)
            MonitorCameraStatus.HopRejoining ->
                stringResource(R.string.camera_hop_rejoining_title)
            MonitorCameraStatus.HopRejoinedRestoring ->
                stringResource(R.string.camera_hop_rejoined_title)
            is MonitorCameraStatus.HopFailed -> stringResource(R.string.camera_hop_failed_title)
        }
    val detail: String? =
        when (status) {
            is MonitorCameraStatus.Connected, MonitorCameraStatus.NoCamera -> null
            MonitorCameraStatus.Connecting -> stringResource(R.string.camera_connecting_detail)
            MonitorCameraStatus.HopLeavingCamera ->
                stringResource(R.string.camera_hop_leaving_detail)
            MonitorCameraStatus.HopWaitingForInternet ->
                stringResource(R.string.camera_hop_waiting_internet_detail)
            MonitorCameraStatus.HopReconnecting ->
                stringResource(R.string.camera_hop_reconnecting_detail)
            MonitorCameraStatus.HopRejoining ->
                stringResource(R.string.camera_hop_rejoining_detail)
            MonitorCameraStatus.HopRejoinedRestoring ->
                stringResource(R.string.camera_hop_rejoined_detail)
            is MonitorCameraStatus.HopFailed ->
                status.message.ifBlank { stringResource(R.string.camera_hop_failed_fallback) }
        }

    return MonitorOperatorPictureNotice(title, detail, status.showsProgress())
}
