package com.opencapture.openzcine

import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.remember
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.compose.LocalLifecycleOwner
import androidx.lifecycle.compose.currentStateAsState
import com.opencapture.openzcine.core.CameraSession
import com.opencapture.openzcine.core.CameraSessionState
import com.opencapture.openzcine.transport.ReconnectBackoff
import kotlin.random.Random
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.delay
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.isActive

/** Monitor retries start at 500 ms and stay frequent enough to recover during a shoot. */
internal fun defaultMonitorSessionRetryPolicy(): ReconnectBackoff =
    ReconnectBackoff(baseMillis = 500L, maxMillis = 8_000L)

/**
 * Owns reconnection only while its monitor coroutine is active.
 *
 * Every attempt calls [CameraSession.connect], so identity, property, event,
 * and recording readback all restart through the existing full session path.
 */
internal class MonitorSessionRecoveryCoordinator(
    private val session: CameraSession,
    private val retryPolicy: ReconnectBackoff = defaultMonitorSessionRetryPolicy(),
    private val jitterSample: () -> Double = { Random.nextDouble() },
    private val sleep: suspend (Long) -> Unit = { delay(it) },
) {
    /** Connects immediately, then recovers unexpected disconnections until cancelled. */
    suspend fun run(): Unit {
        var firstConnection = true
        var consecutiveFailures = 0
        while (currentCoroutineContext().isActive) {
            when (session.state.value) {
                is CameraSessionState.Connected -> {
                    firstConnection = false
                    consecutiveFailures = 0
                    session.state.first { it !is CameraSessionState.Connected }
                }

                CameraSessionState.Connecting -> {
                    firstConnection = false
                    session.state.first { it !is CameraSessionState.Connecting }
                }

                CameraSessionState.Disconnected -> {
                    if (firstConnection) {
                        firstConnection = false
                    } else {
                        sleep(retryPolicy.delayMillis(consecutiveFailures, jitterSample()))
                        consecutiveFailures += 1
                        currentCoroutineContext().ensureActive()
                        if (session.state.value !is CameraSessionState.Disconnected) continue
                    }
                    session.connect()
                }
            }
        }
    }
}

/** Runs monitor recovery only while the owner is started and recovery is permitted. */
@Composable
internal fun MonitorSessionRecoveryEffect(
    session: CameraSession,
    enabled: Boolean,
    retryPolicy: ReconnectBackoff = defaultMonitorSessionRetryPolicy(),
) {
    val lifecycleState by LocalLifecycleOwner.current.lifecycle.currentStateAsState()
    val lifecycleActive = lifecycleState.isAtLeast(Lifecycle.State.STARTED)
    val coordinator =
        remember(session, retryPolicy) {
            MonitorSessionRecoveryCoordinator(session, retryPolicy)
        }
    LaunchedEffect(coordinator, enabled, lifecycleActive) {
        if (enabled && lifecycleActive) coordinator.run()
    }
}
