package com.opencapture.openzcine

import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.remember
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.compose.LocalLifecycleOwner
import androidx.lifecycle.compose.currentStateAsState
import com.opencapture.openzcine.bridge.SwiftCore
import com.opencapture.openzcine.core.CameraSession
import com.opencapture.openzcine.core.CameraSessionState
import kotlin.random.Random
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.delay
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.collectLatest
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.isActive

/**
 * What the operator is told while an established session is being recovered.
 * Mirrors the shared core's `SessionRecoveryState`.
 */
internal sealed interface MonitorRecoveryState {
    /** Live, or never established — nothing to show. */
    data object Idle : MonitorRecoveryState

    /** An automatic reconnect is running or waiting out its backoff. */
    data class Retrying(val attempt: Int, val maxAttempts: Int) : MonitorRecoveryState

    /** The automatic budget is spent; the operator decides what happens next. */
    data class WaitingForOperator(val attemptsMade: Int) : MonitorRecoveryState

    /**
     * Reconnects kept succeeding but the session kept dying young (the shared
     * core's `SessionDropStormGuard`). Automatic recovery is paused to protect
     * the camera; the operator decides.
     */
    data class PausedAfterRepeatedDrops(val drops: Int) : MonitorRecoveryState
}

/**
 * Injectable seam over the shared reconnect schedule, so Kotlin never owns a
 * second copy of when to retry or when to give up. Mirrors the
 * `LinkHealthBridge` pattern.
 */
internal fun interface SessionRetryScheduleBridge {
    /**
     * Milliseconds to wait before the next attempt after [failures]
     * consecutive failures, or `null` once the automatic budget is spent.
     */
    fun retryDelayMillis(failures: Int, jitter: Double): Long?

    /** The shared automatic-attempt budget, for a truthful "attempt N of M". */
    fun maxAutomaticAttempts(): Int = DEFAULT_MAX_AUTOMATIC_ATTEMPTS

    /**
     * Records one drop of an established session in the shared drop-storm
     * ledger; `true` = pause automatic recovery for the operator. Success is
     * exactly what a storm fakes well, so the per-run failure budget cannot
     * catch it — only this cross-run count can.
     */
    fun noteSessionDrop(): Boolean = false

    /** Drops inside the storm window, for the operator-facing count. */
    fun dropsInStormWindow(): Int = 0

    /** Operator action (retry, disconnect, fresh connect) starts a fresh ledger. */
    fun resetDropStormGuard() {}

    companion object {
        /**
         * Shown only when the core is unavailable, in which case no camera work
         * is possible anyway and [ProductionSessionRetryScheduleBridge] stops
         * immediately — this exists so the label never renders as "of 0".
         */
        const val DEFAULT_MAX_AUTOMATIC_ATTEMPTS: Int = 1
    }
}

/**
 * Production schedule: `SessionRecoveryPolicy.monitor` in the Swift core.
 *
 * Without the core there is no camera stack at all, so the honest answer is to
 * stop rather than invent a Kotlin-side fallback schedule that could drift from
 * the shared one.
 */
internal object ProductionSessionRetryScheduleBridge : SessionRetryScheduleBridge {
    override fun retryDelayMillis(failures: Int, jitter: Double): Long? {
        if (!SwiftCore.isAvailable) return null
        val millis = SwiftCore.sessionRetryDelayMillis(failures, jitter)
        return if (millis < 0) null else millis
    }

    override fun maxAutomaticAttempts(): Int =
        if (SwiftCore.isAvailable) {
            SwiftCore.sessionMaxAutomaticAttempts()
        } else {
            SessionRetryScheduleBridge.DEFAULT_MAX_AUTOMATIC_ATTEMPTS
        }

    override fun noteSessionDrop(): Boolean =
        SwiftCore.isAvailable && SwiftCore.sessionNoteSessionDrop()

    override fun dropsInStormWindow(): Int =
        if (SwiftCore.isAvailable) SwiftCore.sessionDropsInStormWindow() else 0

    override fun resetDropStormGuard() {
        if (SwiftCore.isAvailable) SwiftCore.sessionResetDropStormGuard()
    }
}

/**
 * Owns reconnection only while its monitor coroutine is active.
 *
 * Every attempt calls [CameraSession.connect], so identity, property, event,
 * and recording readback all restart through the existing full session path.
 * The retry cadence and the give-up point come from the shared core through
 * [SessionRetryScheduleBridge]; this class only sequences them and publishes
 * what the operator should be told.
 */
internal class MonitorSessionRecoveryCoordinator(
    private val session: CameraSession,
    private val schedule: SessionRetryScheduleBridge = ProductionSessionRetryScheduleBridge,
    private val jitterSample: () -> Double = { Random.nextDouble() },
    private val sleep: suspend (Long) -> Unit = { delay(it) },
) {
    init {
        // A fresh monitor entry starts a fresh storm ledger (parity with iOS, which resets on
        // operator connect and disconnect): the ledger is process-static in the facade and must
        // not carry drops across a deliberate exit-and-return.
        schedule.resetDropStormGuard()
    }

    private val mutableRecoveryState =
        MutableStateFlow<MonitorRecoveryState>(MonitorRecoveryState.Idle)

    /** Drives the monitor's recovery affordance. */
    val recoveryState: StateFlow<MonitorRecoveryState> = mutableRecoveryState.asStateFlow()

    /** Connects immediately, then recovers unexpected disconnections until cancelled. */
    suspend fun run(): Unit {
        mutableRecoveryState.value = MonitorRecoveryState.Idle
        var firstConnection = true
        var consecutiveFailures = 0
        while (currentCoroutineContext().isActive) {
            when (session.state.value) {
                is CameraSessionState.Connected -> {
                    firstConnection = false
                    consecutiveFailures = 0
                    mutableRecoveryState.value = MonitorRecoveryState.Idle
                    session.state.first { it !is CameraSessionState.Connected }
                    // An established session just dropped. If drops keep clustering while every
                    // reconnect succeeds (the storm signature — `consecutiveFailures` above
                    // resets on success and can never catch it), pause instead of churning the
                    // body's PTP stack toward its battery-pull wedge.
                    if (schedule.noteSessionDrop()) {
                        mutableRecoveryState.value =
                            MonitorRecoveryState.PausedAfterRepeatedDrops(
                                schedule.dropsInStormWindow()
                            )
                        return
                    }
                }

                CameraSessionState.Connecting -> {
                    firstConnection = false
                    session.state.first { it !is CameraSessionState.Connecting }
                }

                CameraSessionState.Disconnected -> {
                    if (firstConnection) {
                        firstConnection = false
                    } else {
                        val wait = schedule.retryDelayMillis(consecutiveFailures, jitterSample())
                        if (wait == null) {
                            // Budget spent. Stop burning the radio on a camera that is not coming
                            // back and hand the decision to the operator (retry, or leave the
                            // monitor) instead of retrying forever behind a static "No camera".
                            mutableRecoveryState.value =
                                MonitorRecoveryState.WaitingForOperator(consecutiveFailures)
                            return
                        }
                        mutableRecoveryState.value =
                            MonitorRecoveryState.Retrying(
                                attempt = consecutiveFailures + 1,
                                maxAttempts = schedule.maxAutomaticAttempts(),
                            )
                        sleep(wait)
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
    onRecoveryState: (MonitorRecoveryState) -> Unit = {},
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
