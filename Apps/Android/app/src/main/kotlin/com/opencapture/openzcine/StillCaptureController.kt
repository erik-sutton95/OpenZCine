package com.opencapture.openzcine

import com.opencapture.opencine.nikon.CameraSession
import com.opencapture.opencine.nikon.StillReleasePoll
import com.opencapture.opencine.nikon.StillShutterHold
import java.util.concurrent.atomic.AtomicBoolean
import kotlin.coroutines.cancellation.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.launch

/**
 * Press-tracked still release (iOS `shutterButtonPressed` / `shutterButtonReleased`
 * + `serviceStillCaptureWork`), on Core's `StillShutterHold`: every press fires one
 * plain single-frame release that a finger-up never cancels or terminates, so a tap
 * takes one frame in every drive mode. A press still held in a continuous drive when
 * that frame completes opens the remote-mode bracket, sets the burst ceiling, and
 * chains burst runs until finger-up; the bracket closes on every exit path, including
 * failures. A second press ends a bulb/time exposure.
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

    private val openShutter = AtomicBoolean(false)
    @Volatile private var hold: StillShutterHold? = null
    private var runJob: Job? = null

    /**
     * Fired once per completed run — never per frame — so a held burst
     * schedules exactly one instant review, of its last frame.
     */
    var onRunCompleted: (() -> Unit)? = null

    /**
     * Fired synchronously when a run ends, before capturing clears, so the shell can attribute
     * the run's late card objects (Core `NikonBodyCaptureFilter`) without a gap.
     */
    var onReleaseEnded: (() -> Unit)? = null

    /**
     * Fired when a press cannot proceed (body refusal, busy channel, no
     * session) — silent no-ops are the enemy: the shell toasts this so a dead
     * shutter always explains itself. The quiet burst-end terminate and the
     * best-effort bracket never report here.
     */
    var onFailure: ((String) -> Unit)? = null

    /**
     * Finger-down on the shutter control. [continuousDrive] latches the release
     * until [released]; a press while a bulb/time exposure holds the shutter
     * open ends it instead. [preserveFocus] releases without the AF-driving step so a focus
     * set with the dial survives the shutter; it is read once here so a chained burst keeps
     * the value the press started with.
     */
    fun pressed(scope: CoroutineScope, continuousDrive: Boolean, preserveFocus: Boolean = false) {
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
        val press = StillShutterHold(continuousDrive)
        hold = press
        runJob = scope.launch { runRelease(press, preserveFocus, scope) }
    }

    /**
     * Finger-up: ends a chained burst, terminating the run in flight as a quiet
     * courtesy the body may refuse. The press's first release always finishes on
     * its own, so a quick tap in a continuous drive keeps its frame (it used to be
     * terminated before the body exposed it). No-op for single/timer/bulb presses
     * (iOS `shutterButtonReleased`).
     */
    fun released(scope: CoroutineScope) {
        val press = hold ?: return
        if (press.fingerUp() != StillShutterHold.FingerUp.END_BURST) return
        if (_isCapturing.value && !openShutter.get()) {
            scope.launch { runCatching { session.terminateStillCapture() } }
        }
    }

    private suspend fun runRelease(
        press: StillShutterHold,
        preserveFocus: Boolean,
        scope: CoroutineScope,
    ) {
        _isCapturing.value = true
        openShutter.set(false)
        var bracketOpen = false
        try {
            // The first release is one plain frame, outside the burst bracket.
            session.initiateStillCapture(preserveFocus)
            val startedAt = System.nanoTime()
            while (true) {
                delay(pollDelayMillis)
                when (session.pollStillRelease()) {
                    StillReleasePoll.COMPLETE -> {
                        openShutter.set(false)
                        if (press.releaseCompleted()) {
                            // Finger still down: chain a burst run — one command
                            // release delivers a bounded run of frames, so the hold
                            // itself drives the burst. The bracket is best-effort: a
                            // refusal (release/AF settling) still lets the run fire.
                            if (!bracketOpen) {
                                runCatching { session.setStillBurstBracket(true) }
                                    .onSuccess { bracketOpen = true }
                            }
                            session.initiateStillCapture(preserveFocus)
                            // A finger-up that landed while the run was being sent
                            // terminated nothing yet; end the run it asked to end.
                            if (!press.isHeld) runCatching { session.terminateStillCapture() }
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
                        if (press.burstRuns == 0) {
                            runCatching {
                                onFailure?.invoke("The camera refused the still release.")
                            }
                        }
                        break
                    }
                }
            }
        } catch (cancelled: CancellationException) {
            // The monitor left composition mid-release; that is not a refusal to report.
            throw cancelled
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
            press.fingerUp()
            if (hold === press) hold = null
            runCatching { onReleaseEnded?.invoke() }
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
