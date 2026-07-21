package com.opencapture.openzcine

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import com.opencapture.openzcine.core.CameraSessionState
import com.opencapture.openzcine.frameio.FrameioInternetHopState

/**
 * Operator-facing feed status when live view is not available.
 *
 * After a RED / Frame.io internet hop the session is often
 * [CameraSessionState.Disconnected] for several seconds while Wi‑Fi rejoins.
 * Surfacing only "No camera" reads as a failure even though reconnect is in
 * progress — hop state is the reliable signal for that path.
 */
internal sealed interface MonitorCameraStatus {
    data class Connected(val name: String) : MonitorCameraStatus

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
        is CameraSessionState.Connected -> MonitorCameraStatus.Connected(sessionState.identity.name)
        CameraSessionState.Connecting -> MonitorCameraStatus.Connecting
        CameraSessionState.Disconnected -> MonitorCameraStatus.NoCamera
    }
}

/** Whether this status represents an in-progress search / rejoin (show spinner). */
internal fun MonitorCameraStatus.showsProgress(): Boolean =
    when (this) {
        is MonitorCameraStatus.Connected,
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
 * Center-of-feed placeholder: title, optional detail, optional spinner for hop / connect.
 */
@Composable
internal fun MonitorFeedCameraStatus(
    status: MonitorCameraStatus,
    modifier: Modifier = Modifier,
) {
    val title =
        when (status) {
            is MonitorCameraStatus.Connected -> status.name
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

    Column(
        modifier = modifier.fillMaxWidth().padding(horizontal = 32.dp),
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.spacedBy(10.dp),
    ) {
        if (status.showsProgress()) {
            CircularProgressIndicator(
                color = LiveDesign.accent,
                strokeWidth = 2.dp,
                modifier = Modifier.size(28.dp),
            )
        }
        Text(
            text = title,
            style = chromeStyle(15f, FontWeight.SemiBold),
            color = LiveDesign.text,
            textAlign = TextAlign.Center,
        )
        if (detail != null) {
            Text(
                text = detail,
                style = chromeStyle(12f, FontWeight.Normal),
                color = LiveDesign.muted,
                textAlign = TextAlign.Center,
            )
        }
    }
}
