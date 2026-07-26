package com.opencapture.openzcine

import com.opencapture.openzcine.core.CameraSession
import com.opencapture.openzcine.core.MFDriveOutcome
import kotlin.coroutines.coroutineContext
import kotlin.math.abs
import kotlin.math.min
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch

/**
 * Focus-by-wire drive queue (iOS `driveManualFocus`): signed pulses
 * (+ toward infinity, − toward near) accumulate while a single in-flight
 * drive drains them, so gesture speed never floods the command channel.
 *
 * A focus-by-wire drive can be refused for transient reasons — the stepping-motor lens is still
 * initializing after a mode change, or autofocus is momentarily active/settling — none of which
 * mean the lens can't be driven, so every refusal requeues and retries, bounded; only a sustained
 * refusal surfaces one message, and the strip is never hidden. The camera permits a remote drive
 * ONLY in an AF focus mode — in MF the lens ring has exclusive control and the body refuses every
 * drive with Invalid_Status ("the focus mode is MF"). So the strip is gated on an AF mode (NOT MF)
 * and the app scrub acts as a manual-focus override, the way the lens ring overrides during AF.
 * [verify-on-HW: per-lens pulse feel, and whether continuous AF fights the drive in AF-C vs AF-S]
 */
internal class MFDriveController(
    private val session: CameraSession,
    /** Injectable pacing for tests. */
    private val retryDelayMillis: Long = RETRY_DELAY_MILLIS,
    /** Injectable clock so the refusal budget is testable on a virtual scheduler. */
    private val elapsedMillis: () -> Long = System::currentTimeMillis,
) {
    private val _atEnd = MutableStateFlow<Int?>(null)

    /** Travel-end feedback: −1 near limit, +1 infinity limit, null moving. */
    val atEnd: StateFlow<Int?> = _atEnd

    private val _driveStats = MutableStateFlow(0 to 0)

    /** Debug caption counters: drives acknowledged vs retried. */
    val driveStats: StateFlow<Pair<Int, Int>> = _driveStats

    private val _netPulses = MutableStateFlow(0)

    /** Net acknowledged pulses since the dial was armed (+ toward infinity) — drives the drum. */
    val netPulses: StateFlow<Int> = _netPulses

    private val _dialFraction = MutableStateFlow<Float?>(null)

    /** Relative focus position 0 (near) … 1 (infinity) once a full sweep pins both ends; null
     * while uncalibrated. The camera exposes no absolute distance for AF lenses. */
    val dialFraction: StateFlow<Float?> = _dialFraction

    /** Fired once per exhausted retry run (the body kept refusing), with the code. */
    var onRefusalExhausted: ((String) -> Unit)? = null

    /**
     * True once the operator drove focus with the dial and hasn't tapped to AF since — the still
     * release then fires WITHOUT AF so the manually-set focus is preserved (iOS
     * `focusManuallyDialed`). Cleared by [clearManualFocus] on a tap-to-AF; deliberately NOT
     * cleared by a focus-mode change or a focus-point recenter, matching iOS.
     */
    @Volatile
    var focusManuallyDialed: Boolean = false
        private set

    /** The operator chose to AF at a point — subsequent releases resume normal AF focus. */
    fun clearManualFocus() {
        focusManuallyDialed = false
    }

    private var pendingPulses = 0
    private var driveJob: Job? = null
    private var refusalRunStartedAt: Long? = null
    private var nearPulses: Int? = null
    private var infinityPulses: Int? = null

    /**
     * Drops the in-flight drive and everything queued behind it, freeing `cameraCommandMutex`
     * immediately. An AF-point tap is interactive and must win — queueing it behind a retrying
     * drive is what left tap-to-focus dead until a shutter release (iOS `cancelManualFocusDrive`).
     */
    fun cancel() {
        pendingPulses = 0
        refusalRunStartedAt = null
        driveJob?.cancel()
        driveJob = null
    }

    /** Re-arms the relative position (call when the strip appears / lens or mode changes). */
    fun resetDial() {
        _netPulses.value = 0
        _dialFraction.value = null
        _atEnd.value = null
        nearPulses = null
        infinityPulses = null
    }

    private fun recalculateFraction() {
        val near = nearPulses
        val far = infinityPulses
        _dialFraction.value =
            if (near != null && far != null && far > near) {
                ((_netPulses.value - near).toFloat() / (far - near)).coerceIn(0f, 1f)
            } else {
                null
            }
    }

    /** Queues a relative drive; coalesces while one is in flight. */
    fun drive(scope: CoroutineScope, pulses: Int) {
        if (pulses == 0) return
        pendingPulses += pulses
        // Focus is now operator-set; the next release preserves it (no AF) until a tap-to-AF.
        focusManuallyDialed = true
        // Advance the dial position on the DRAG, not the ack — the drum tracks the finger
        // smoothly instead of stepping at the command round-trip rate. Clamp to pinned ends.
        _netPulses.value =
            (_netPulses.value + pulses).let { advanced ->
                var v = advanced
                nearPulses?.let { v = maxOf(v, it) }
                infinityPulses?.let { v = minOf(v, it) }
                v
            }
        recalculateFraction()
        _atEnd.value = null
        if (driveJob?.isActive == true) return
        driveJob = scope.launch { drain() }
    }

    private suspend fun drain() {
        // `isActive` as well as the queue: a cancelled drive can still be parked in a
        // NonCancellable native call, and it must not resume alongside its replacement — two
        // drains sharing the command channel is the ownership bug this whole path is about.
        while (pendingPulses != 0 && coroutineContext.isActive) {
            val pending = pendingPulses
            pendingPulses = 0
            val outcome =
                runCatching {
                    session.mfDrive(
                        towardNear = pending < 0,
                        pulses = min(abs(pending), MAX_PULSES),
                    )
                }.getOrElse { MFDriveOutcome.Refused(DEVICE_BUSY_RESPONSE) }
            when (outcome) {
                MFDriveOutcome.Complete, MFDriveOutcome.StepTooSmall -> {
                    // Position already advanced optimistically on the drag (in drive()).
                    refusalRunStartedAt = null
                    continue
                }
                MFDriveOutcome.EndOfTravel -> {
                    // Pin this end at the current (optimistic) position so the relative position
                    // calibrates and the dial clamps here on further drives toward it.
                    refusalRunStartedAt = null
                    if (pending < 0) {
                        nearPulses = _netPulses.value
                        _atEnd.value = -1
                    } else {
                        infinityPulses = _netPulses.value
                        _atEnd.value = 1
                    }
                    recalculateFraction()
                    pendingPulses = 0
                }
                is MFDriveOutcome.Refused -> {
                    // A refusal is transient while AF is momentarily driving (access-denied) or
                    // the lens is still initializing (busy): requeue and retry. A sustained
                    // refusal is a real state block — Invalid_Status means either an unusable lens
                    // or that the focus mode slipped back to MF (the body refuses a remote drive in
                    // MF). Surface one message and leave the strip up so the next gesture retries.
                    _driveStats.value = _driveStats.value.let { (ok, busy) -> ok to busy + 1 }
                    val startedAt = refusalRunStartedAt ?: elapsedMillis().also {
                        refusalRunStartedAt = it
                    }
                    if (elapsedMillis() - startedAt < REFUSAL_RETRY_BUDGET_MILLIS) {
                        pendingPulses += pending
                        delay(retryDelayMillis)
                        continue
                    }
                    // Give the command channel back: the next gesture retries from a clean slate,
                    // and a tap-to-focus waiting on cameraCommandMutex goes through now.
                    refusalRunStartedAt = null
                    pendingPulses = 0
                    onRefusalExhausted?.invoke(
                        if (outcome.rawResponseCode == INVALID_STATUS_RESPONSE) {
                            "Can't drive focus in MF — set the camera to an AF focus mode to " +
                                "scrub focus from the app."
                        } else {
                            "Couldn't drive focus just now — try again (0x%04X)."
                                .format(outcome.rawResponseCode)
                        },
                    )
                }
            }
        }
    }

    internal companion object {
        const val MAX_PULSES = 32767

        /**
         * Wall clock a run of refusals may keep retrying before it gives up and frees
         * `cameraCommandMutex`. Mirrors Swift `MFDriveChannelBudget.refusalRetrySeconds`.
         *
         * Deliberately NOT an iteration count: one drive already costs an activation plus a
         * bounded readiness poll, so "16 retries" was tens of seconds of channel ownership —
         * during which `changeAfArea` could not run at all.
         */
        const val REFUSAL_RETRY_BUDGET_MILLIS = 1_200L

        /** Mirrors Swift `MFDriveChannelBudget.refusalRetryIntervalSeconds`. */
        const val RETRY_DELAY_MILLIS = 80L

        /** Standard busy answer on the shared channel. */
        const val DEVICE_BUSY_RESPONSE = 0x2019

        /**
         * The body's "remote focus drive refused because the focus mode is MF" status — in MF the
         * lens ring has exclusive control. Gets its own actionable message. [verify-on-HW]
         */
        const val INVALID_STATUS_RESPONSE = 0xA004
    }
}
