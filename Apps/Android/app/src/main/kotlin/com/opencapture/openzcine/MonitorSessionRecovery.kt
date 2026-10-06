package com.opencapture.openzcine

import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.remember
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.compose.LocalLifecycleOwner
import androidx.lifecycle.compose.currentStateAsState
import com.opencapture.opencine.nikon.CameraSession
import com.opencapture.opencine.nikon.MonitorSessionRecoveryCoordinator
import com.opencapture.opencine.nikon.ProductionSessionRetryScheduleBridge
import com.opencapture.opencine.nikon.SessionRetryScheduleBridge
import com.opencapture.opencine.vocabulary.SessionRecoveryUi
import kotlinx.coroutines.flow.collectLatest

/**
 * Runs monitor recovery only while the owner is started and recovery is permitted.
 *
 * [retryTicket] restarts the loop with a fresh attempt budget — bump it from the
 * operator's "Retry connection" action. [onRecoveryState] lifts the published
 * state so the monitor can render the affordance over the held frame.
 */
@Composable
internal fun MonitorSessionRecoveryEffect(
    session: CameraSession,
    enabled: Boolean,
    schedule: SessionRetryScheduleBridge = ProductionSessionRetryScheduleBridge,
    retryTicket: Int = 0,
    onRecoveryState: (SessionRecoveryUi) -> Unit = {},
) {
    val lifecycleState by LocalLifecycleOwner.current.lifecycle.currentStateAsState()
    val lifecycleActive = lifecycleState.isAtLeast(Lifecycle.State.STARTED)
    val coordinator =
        remember(session, schedule) { MonitorSessionRecoveryCoordinator(session, schedule) }
    LaunchedEffect(coordinator, enabled, lifecycleActive, retryTicket) {
        if (enabled && lifecycleActive) coordinator.run()
    }
    LaunchedEffect(coordinator, onRecoveryState) {
        coordinator.recoveryState.collectLatest(onRecoveryState)
    }
}
