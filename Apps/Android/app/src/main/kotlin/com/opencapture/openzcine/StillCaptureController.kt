package com.opencapture.openzcine

import com.opencapture.openzcine.core.CameraSession
import com.opencapture.openzcine.core.StillReleasePoll
import java.util.concurrent.atomic.AtomicBoolean
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.launch

/**
 * Press-tracked still release (iOS `shutterButtonPressed` / `shutterButtonReleased`
 * + `serviceStillCaptureWork`): single/timer presses fire one release; a press
 * held in a continuous drive opens the remote-mode bracket, sets the burst
 * ceiling, and chains releases until finger-up — the bracket closes on every
 * exit path, including failures. A second press ends a bulb/time exposure.
 * [verify-on-HW: continuous latch-until-terminate per body]
 */
internal class StillCaptureController(
    private val session: CameraSession,
    /** Injectable clock/pacing for tests. */
    private val pollDelayMillis: Long = 350L,
    private val releaseTimeoutMillis: Long = 45_000L,
) {
    private val _isCapturing = MutableStateFlow(false)

    /** True from the accepted release until the run (incl. every burst frame) ends. */
    val isCapturing: StateFlow<Boolean> = _isCapturing

    private val held = AtomicBoolean(false)
    private val openShutter = AtomicBoolean(false)
    private val latchedContinuous = AtomicBoolean(false)
    private var runJob: Job? = null

    /**
     * Fired once per completed run — never per frame — so a held burst
     * schedules exactly one instant review, of its last frame.
     */
    var onRunCompleted: (() -> Unit)? = null

    /**
     * Fired when a press cannot proceed (body refusal, busy channel, no
     * session) — silent no-ops are the enemy: the shell toasts this so a dead
     * shutter always explains itself. The quiet burst-end terminate and the
     * best-effort bracket never report here.
     */
    var onFailure: ((String) -> Unit)? = null

    /** Frames chained in one hold — a hard cap backstops a swallowed finger-up. */
    private companion object {
        const val MAX_CHAINED_FRAMES = 30
    }

    /**
     * Finger-down on the shutter control. [continuousDrive] latches the release
     * until [released]; a press while a bulb/time exposure holds the shutter
     * open ends it instead.
     */
    fun pressed(scope: CoroutineScope, continuousDrive: Boolean) {
        // Gate on the CAPTURING state, not the job handle: the previous run's
        // job stays briefly active while its post-run refresh detaches, and a
        // job-handle guard silently swallowed the timer chain's next shot
        // exactly there (iOS gates on isStillCapturing the same way).
        if (_isCapturing.value) {
            if (openShutter.get()) {
                // Second press ends the open exposure (iOS captureStill).
                scope.launch { runCatching { session.terminateStillCapture() } }
            }
            return
        }
        held.set(true)
        latchedContinuous.set(continuousDrive)
        runJob = scope.launch { runRelease(continuousDrive, scope) }
    }

    /**
     * Finger-up: ends a latched continuous burst — terminating the frame run
     * still in flight is a quiet courtesy the body may refuse. No-op for
     * single/timer/bulb presses (iOS `shutterButtonReleased`).
     */
    fun released(scope: CoroutineScope) {
        if (!held.getAndSet(false)) return
        if (latchedContinuous.get() && _isCapturing.value && !openShutter.get()) {
            scope.launch { runCatching { session.terminateStillCapture() } }
        }
    }

    private suspend fun runRelease(continuous: Boolean, scope: CoroutineScope) {
        _isCapturing.value = true
        openShutter.set(false)
        var chained = 0
        var bracketOpen = false
        try {
            if (continuous) {
                // The bracket is best-effort: a refusal (release/AF settling)
                // still lets the single-frame release proceed.
                runCatching { session.setStillBurstBracket(true) }
                    .onSuccess { bracketOpen = true }
            }
            session.initiateStillCapture()
            val startedAt = System.nanoTime()
            while (true) {
                delay(pollDelayMillis)
                when (session.pollStillRelease()) {
                    StillReleasePoll.COMPLETE -> {
                        openShutter.set(false)
                        if (continuous && held.get() && chained < MAX_CHAINED_FRAMES) {
                            // Finger still down: chain the next release — one
                            // command release delivers a bounded run of frames,
                            // so the hold itself drives the burst.
                            chained += 1
                            session.initiateStillCapture()
                        } else {
                            break
                        }
                    }
                    StillReleasePoll.IN_PROGRESS -> {
                        openShutter.set(false)
                        val elapsedMillis = (System.nanoTime() - startedAt) / 1_000_000
                        // Self-timer waits and bursts run long; only give up
                        // well past anything a working release should need.
                        if (elapsedMillis > releaseTimeoutMillis) break
                    }
                    StillReleasePoll.OPEN_SHUTTER -> {
                        // Bulb/time holds the shutter open — no timeout; the
                        // next press terminates.
                        openShutter.set(true)
                    }
                    StillReleasePoll.FAILED -> {
                        // A refused/failed release surfaces (iOS "Still
                        // capture failed"); quiet when a finger-up already
                        // terminated the latched run.
                        if (chained == 0 && held.get()) {
                            runCatching {
                                onFailure?.invoke("The camera refused the still release.")
                            }
                        }
                        break
                    }
                }
            }
        } catch (error: Exception) {
            // A refused release must never die silently — surface the typed
            // message (body rejection, busy channel, unsupported session) so
            // an on-device dead shutter always explains itself. State still
            // resets below; the property poll restores authoritative state.
            runCatching {
                onFailure?.invoke(
                    error.message ?: "The camera did not accept the still release.",
                )
            }
        } finally {
            if (bracketOpen) runCatching { session.setStillBurstBracket(false) }
            openShutter.set(false)
            held.set(false)
            _isCapturing.value = false
            // Detached: the SHOTS refresh and the review kickoff can take
            // seconds and must never keep the run "active" — the timer chain's
            // next shot fires the moment capturing clears.
            scope.launch {
                runCatching { session.refreshProperties() }
                runCatching { onRunCompleted?.invoke() }
            }
        }
    }
}
