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
 * There is NO pre-probe: the FIRST real drive is the drivability verdict — a
 * probe whose 1-pulse drive answered busy used to wedge the strip off-screen
 * forever, and connecting with MF already engaged never probed at all. A
 * definitive (non-busy) refusal latches the lens undrivable (hides the strip,
 * surfaces the mechanical-ring toast with the wire code); busy activations
 * requeue and retry, bounded. The latch belongs to one lens identity and
 * re-arms on a swap. [verify-on-HW: per-lens pulse feel and refusal codes]
 */
internal class MFDriveController(
    private val session: CameraSession,
    /** Injectable pacing for tests. */
    private val busyRetryDelayMillis: Long = 80L,
) {
    private val _atEnd = MutableStateFlow<Int?>(null)

    /** Travel-end feedback: −1 near limit, +1 infinity limit, null moving. */
    val atEnd: StateFlow<Int?> = _atEnd

    private val _lensUndrivable = MutableStateFlow(false)

    /** Latched once this lens definitively refused a drive (strip hides). */
    val lensUndrivable: StateFlow<Boolean> = _lensUndrivable

    private val _driveStats = MutableStateFlow(0 to 0)

    /** Debug caption counters: drives acknowledged vs busy-refused. */
    val driveStats: StateFlow<Pair<Int, Int>> = _driveStats

    /** Fired on the definitive refusal that latched the lens, with the code. */
    var onNonDrivableLens: ((String) -> Unit)? = null

    /** Fired once per exhausted busy-retry run (the body kept refusing). */
    var onBusyExhausted: ((String) -> Unit)? = null

    private var pendingPulses = 0
    private var driveJob: Job? = null
    private var knownLens: String? = null
    private var busyRetries = 0

    /**
     * Re-arms drivability when the mounted lens changes: an undrivable latch
     * belongs to one lens identity — swap the glass and the strip returns
     * until the new lens proves otherwise. Callers invoke this with the
     * CURRENT identity on first composition too, so connecting with MF
     * already engaged is covered, not only changes.
     */
    fun noteLensChanged(lensIdentity: String?) {
        if (knownLens == lensIdentity) return
        knownLens = lensIdentity
        _lensUndrivable.value = false
        _atEnd.value = null
    }

    /** Queues a relative drive; coalesces while one is in flight. */
    fun drive(scope: CoroutineScope, pulses: Int) {
        if (pulses == 0 || _lensUndrivable.value) return
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
                    busyRetries = 0
                    _driveStats.value = _driveStats.value.let { (ok, busy) -> ok + 1 to busy }
                    continue
                }
                MFDriveOutcome.EndOfTravel -> {
                    // The reached limit lights its side; queued pulses toward
                    // it are moot.
                    busyRetries = 0
                    _driveStats.value = _driveStats.value.let { (ok, busy) -> ok + 1 to busy }
                    _atEnd.value = if (pending < 0) -1 else 1
                    pendingPulses = 0
                }
                is MFDriveOutcome.Refused -> {
                    if (outcome.rawResponseCode == DEVICE_BUSY_RESPONSE) {
                        // The body answers busy at ACTIVATION while its
                        // acquisition is mid-frame internally — requeue the
                        // batch and retry shortly, bounded.
                        _driveStats.value =
                            _driveStats.value.let { (ok, busy) -> ok to busy + 1 }
                        if (busyRetries < MAX_BUSY_RETRIES) {
                            busyRetries += 1
                            pendingPulses += pending
                            delay(busyRetryDelayMillis)
                            continue
                        }
                        busyRetries = 0
                        pendingPulses = 0
                        onBusyExhausted?.invoke(
                            "The camera kept refusing focus drives (busy).",
                        )
                        continue
                    }
                    // A definitive refusal IS the drivability verdict: latch
                    // this lens undrivable instead of pre-probing at mount
                    // time. [verify-on-HW: which code a mechanical ring answers]
                    busyRetries = 0
                    pendingPulses = 0
                    _lensUndrivable.value = true
                    onNonDrivableLens?.invoke(
                        "The camera can't drive this lens's focus — its ring may be " +
                            "mechanical (0x%04X).".format(outcome.rawResponseCode),
                    )
                }
            }
        }
    }

    private companion object {
        const val MAX_PULSES = 32767

        /** Bounded activation-busy retries per run before surfacing once. */
        const val MAX_BUSY_RETRIES = 12

        /** Standard busy answer on the shared channel. */
        const val DEVICE_BUSY_RESPONSE = 0x2019
    }
}
