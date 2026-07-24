package com.opencapture.openzcine

import com.opencapture.openzcine.core.CameraSession
import com.opencapture.openzcine.core.MFDriveOutcome
import kotlin.math.abs
import kotlin.math.min
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
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
    private val retryDelayMillis: Long = 80L,
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

    private var pendingPulses = 0
    private var driveJob: Job? = null
    private var retries = 0
    private var nearPulses: Int? = null
    private var infinityPulses: Int? = null

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
        _atEnd.value = null
        if (driveJob?.isActive == true) return
        driveJob = scope.launch { drain() }
    }

    private suspend fun drain() {
        while (pendingPulses != 0) {
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
                    retries = 0
                    _netPulses.value += pending
                    recalculateFraction()
                    continue
                }
                MFDriveOutcome.EndOfTravel -> {
                    // The reached limit lights its side and pins that end so the relative
                    // position can calibrate; queued pulses toward it are moot.
                    retries = 0
                    _netPulses.value += pending
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
                    if (retries < MAX_RETRIES) {
                        retries += 1
                        pendingPulses += pending
                        delay(retryDelayMillis)
                        continue
                    }
                    retries = 0
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

    private companion object {
        const val MAX_PULSES = 32767

        /** Bounded refusal retries per run before surfacing once. */
        const val MAX_RETRIES = 16

        /** Standard busy answer on the shared channel. */
        const val DEVICE_BUSY_RESPONSE = 0x2019

        /**
         * The body's "remote focus drive refused because the focus mode is MF" status — in MF the
         * lens ring has exclusive control. Gets its own actionable message. [verify-on-HW]
         */
        const val INVALID_STATUS_RESPONSE = 0xA004
    }
}
