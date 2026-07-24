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
 * There is NO drivability verdict. A focus-by-wire drive can be refused for
 * transient state reasons — the stepping-motor lens is still initializing
 * after a focus-mode change, or autofocus is momentarily active/settling —
 * none of which mean the lens can't be driven. So every refusal (busy OR
 * access-denied) requeues and retries, bounded; only a sustained refusal
 * surfaces one message, and the strip is never hidden. The strip's own
 * visibility depends solely on the focus mode being MF.
 * [verify-on-HW: per-lens pulse feel and which codes a given lens answers]
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

    /** Fired once per exhausted retry run (the body kept refusing), with the code. */
    var onRefusalExhausted: ((String) -> Unit)? = null

    private var pendingPulses = 0
    private var driveJob: Job? = null
    private var retries = 0

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
                    _driveStats.value = _driveStats.value.let { (ok, busy) -> ok + 1 to busy }
                    continue
                }
                MFDriveOutcome.EndOfTravel -> {
                    // The reached limit lights its side; queued pulses toward
                    // it are moot.
                    retries = 0
                    _driveStats.value = _driveStats.value.let { (ok, busy) -> ok + 1 to busy }
                    _atEnd.value = if (pending < 0) -1 else 1
                    pendingPulses = 0
                }
                is MFDriveOutcome.Refused -> {
                    // Every refusal is transient state, not a lens verdict: busy = the
                    // stepping-motor lens is still initializing (or an acquisition is
                    // running); access-denied = autofocus is momentarily active. Requeue
                    // and retry; a genuinely stuck state surfaces one message but leaves the
                    // strip up so the next gesture tries again.
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
                        "Couldn't drive focus just now — make sure focus mode is MF and " +
                            "autofocus isn't running, then try again (0x%04X)."
                            .format(outcome.rawResponseCode),
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
    }
}
