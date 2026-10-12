package com.opencapture.openzcine

import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.remember
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.compose.LocalLifecycleOwner
import androidx.lifecycle.compose.currentStateAsState
import com.opencapture.opencine.nikon.CameraSession
import com.opencapture.opencine.nikon.MonitorPictureClock
import com.opencapture.opencine.nikon.PictureAwareMonitorSessionRecoveryCoordinator
import com.opencapture.opencine.vocabulary.SessionRecoveryUi
import kotlinx.coroutines.flow.collectLatest

/**
 * Runs monitor recovery only while the owner is started and recovery is permitted.
 *
 * Recovery is the shared Core episode: it ends on a fresh [pictures] stamp, never on a returned
 * control session, and stops at the shared budget. Bump [retryTicket] from the operator's "Retry
 * connection" action for a fresh drop ledger and a fresh episode. [onRecoveryState] lifts the
 * published state so the monitor can render the affordance over the held frame.
 */
@Composable
internal fun MonitorSessionRecoveryEffect(
    session: CameraSession,
    pictures: MonitorPictureClock,
    enabled: Boolean,
    retryTicket: Int = 0,
    onRecoveryState: (SessionRecoveryUi) -> Unit = {},
) {
    val lifecycleState by LocalLifecycleOwner.current.lifecycle.currentStateAsState()
    val lifecycleActive = lifecycleState.isAtLeast(Lifecycle.State.STARTED)
    val coordinator =
        remember(session, pictures) {
            PictureAwareMonitorSessionRecoveryCoordinator(session, pictures)
        }
    val retriedTicket = remember(coordinator) { mutableIntStateOf(retryTicket) }
    LaunchedEffect(coordinator, enabled, lifecycleActive, retryTicket) {
        if (retryTicket != retriedTicket.intValue) {
            retriedTicket.intValue = retryTicket
            coordinator.retry()
        }
        if (enabled && lifecycleActive) coordinator.run()
    }
    LaunchedEffect(coordinator, onRecoveryState) {
        coordinator.recoveryState.collectLatest(onRecoveryState)
    }
}
