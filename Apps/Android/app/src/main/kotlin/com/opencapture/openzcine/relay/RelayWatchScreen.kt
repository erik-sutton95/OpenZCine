package com.opencapture.openzcine.relay

import android.content.res.Configuration
import androidx.compose.runtime.Composable
import androidx.compose.ui.platform.LocalConfiguration
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import com.opencapture.monitorui.MonitorWatcherConnectionOverlayValue
import com.opencapture.monitorui.MonitorWatcherConnectionPhase
import com.opencapture.monitorui.MonitorWatcherControlPlacement
import com.opencapture.opencine.cameracontrols.MonitorOperatorWatcherOverlay
import com.opencapture.opencine.cameracontrols.MonitorWatcherConnectionLabels
import com.opencapture.openzcine.R

/** Wire facts/localized content over the common watcher connection and live-surface owners. */
@Composable
fun RelayWatchOverlay(ui: RelayWatchUiState, onAskForControl: () -> Unit, onGiveBackControl: () -> Unit,
    onSubmitPasscode: (String) -> Unit, onRetry: () -> Unit, onLeave: () -> Unit) {
    val phase = when (ui.phase) {
        RelayWatchUiState.Phase.WATCHING -> MonitorWatcherConnectionPhase.WATCHING
        RelayWatchUiState.Phase.CONNECTING -> MonitorWatcherConnectionPhase.JOINING
        RelayWatchUiState.Phase.DENIED -> MonitorWatcherConnectionPhase.DENIED
        RelayWatchUiState.Phase.FAILED -> MonitorWatcherConnectionPhase.FAILED
    }
    MonitorOperatorWatcherOverlay(value = MonitorWatcherConnectionOverlayValue(phase = phase,
        canControl = ui.holdsControl, canRequestControl = ui.allowsControlRequests,
        needsPasscode = ui.needsPasscode, passcodeWasWrong = ui.passcodeWasWrong,
        failureReason = ui.failureReason, controlBottomInset = relayControlKeyBottomInset().value.toDouble()),
        labels = MonitorWatcherConnectionLabels(requestControl = stringResource(R.string.relay_ask_for_control),
            releaseControl = stringResource(R.string.relay_give_back_control),
            joining = stringResource(R.string.relay_watch_connecting), failureFallback = stringResource(R.string.relay_watch_dropped),
            retry = stringResource(R.string.relay_try_again), leave = stringResource(R.string.relay_leave),
            passcodeTitle = stringResource(R.string.relay_passcode_title), passcodeWrong = stringResource(R.string.relay_passcode_wrong),
            passcodeBody = stringResource(R.string.relay_passcode_body), passcodeHint = stringResource(R.string.relay_passcode_hint),
            connect = stringResource(R.string.action_connect), cancel = stringResource(R.string.action_cancel)),
        onAskForControl = onAskForControl, onGiveBackControl = onGiveBackControl, onSubmitPasscode = onSubmitPasscode,
        onRetry = onRetry, onLeave = onLeave)
}

/** Broadcaster and watcher keys consume the same common monitor lane. */
@Composable
internal fun relayControlKeyBottomInset(): Dp = MonitorWatcherControlPlacement.bottomInset(
    portrait = LocalConfiguration.current.orientation == Configuration.ORIENTATION_PORTRAIT).toFloat().dp
