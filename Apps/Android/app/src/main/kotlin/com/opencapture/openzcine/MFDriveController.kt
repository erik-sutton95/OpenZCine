package com.opencapture.openzcine

import com.opencapture.openzcine.core.CameraSession
import com.opencapture.openzcine.core.MFDriveOutcome
import kotlin.math.abs
import kotlin.math.min
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Job
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.launch

/** Drivability of the attached lens for focus-by-wire, proven by a probe. */
internal enum class MFDriveLensState {
    /** Not yet probed (or a busy/transport answer left it unproven). */
    UNKNOWN,

    /** The lens classified a 1-pulse drive — the strip shows. */
    DRIVABLE,

    /** Mechanical/incompatible ring — the strip stays hidden. */
    UNDRIVABLE,
}

/**
 * Focus-by-wire drive queue (iOS `driveManualFocus`): signed pulses
 * (+ toward infinity, − toward near) accumulate while a single in-flight
 * drive drains them, so gesture speed never floods the command channel.
 * Travel ends feed the scrub UI (−1 near / +1 infinity); a busy channel
 * retries silently on the next gesture; a lens the body cannot drive
 * (mechanical ring) surfaces ONCE with the body's answer.
 * [verify-on-HW: per-lens pulse feel]
 */
internal class MFDriveController(private val session: CameraSession) {
    private val _atEnd = MutableStateFlow<Int?>(null)

    /** Travel-end feedback: −1 near limit, +1 infinity limit, null moving. */
    val atEnd: StateFlow<Int?> = _atEnd

    /** Fired once per session for a non-drivable lens, with the body's code. */
    var onNonDrivableLens: ((String) -> Unit)? = null

    private val _lensState = MutableStateFlow(MFDriveLensState.UNKNOWN)

    /** Whether the attached lens is PROVEN focus-by-wire (gates the strip). */
    val lensState: StateFlow<MFDriveLensState> = _lensState

    private var pendingPulses = 0
    private var driveJob: Job? = null
    private var probeJob: Job? = null
    private var probedLens: String? = null
    private var refusalSurfaced = false

    /**
     * Proves drivability once per lens identity when MF engages: a single
     * 1-pulse drive — a drivable lens answers complete (then 1 pulse back
     * restores the nudge) or amount-too-small, with no perceptible motion; a
     * mechanical/incompatible lens answers the invalid-status class and the
     * strip hides. Busy answers leave the gate unknown and the next poll tick
     * re-probes. [verify-on-HW: probe answers per lens]
     */
    fun probeIfNeeded(scope: CoroutineScope, lensIdentity: String?) {
        if (lensIdentity != probedLens) {
            // A lens swap invalidates the cached proof (and the end flash).
            probedLens = lensIdentity
            _lensState.value = MFDriveLensState.UNKNOWN
            _atEnd.value = null
        }
        if (_lensState.value != MFDriveLensState.UNKNOWN) return
        if (probeJob?.isActive == true || driveJob?.isActive == true) return
        probeJob = scope.launch {
            val outcome =
                runCatching { session.mfDrive(towardNear = true, pulses = 1) }
                    .getOrElse { MFDriveOutcome.Refused(DEVICE_BUSY_RESPONSE) }
            _lensState.value =
                when (outcome) {
                    MFDriveOutcome.Complete -> {
                        // The pulse moved the lens imperceptibly — restore it.
                        runCatching { session.mfDrive(towardNear = false, pulses = 1) }
                        MFDriveLensState.DRIVABLE
                    }
                    // The lens classified the drive — it is by-wire (an end
                    // answer means it sits parked at a limit). [verify-on-HW]
                    MFDriveOutcome.StepTooSmall,
                    MFDriveOutcome.EndOfTravel,
                    -> MFDriveLensState.DRIVABLE
                    is MFDriveOutcome.Refused ->
                        if (outcome.rawResponseCode == DEVICE_BUSY_RESPONSE ||
                            outcome.rawResponseCode == 0
                        ) {
                            // Busy/transport: unknown — the next tick retries.
                            MFDriveLensState.UNKNOWN
                        } else {
                            MFDriveLensState.UNDRIVABLE
                        }
                }
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
                }.getOrElse { MFDriveOutcome.Refused(rawResponseCode = 0) }
            when (outcome) {
                MFDriveOutcome.Complete, MFDriveOutcome.StepTooSmall -> continue
                MFDriveOutcome.EndOfTravel -> {
                    // The reached limit lights its side; queued pulses toward
                    // it are moot.
                    _atEnd.value = if (pending < 0) -1 else 1
                    pendingPulses = 0
                }
                is MFDriveOutcome.Refused -> {
                    pendingPulses = 0
                    if (outcome.rawResponseCode == DEVICE_BUSY_RESPONSE) {
                        // Busy channel: quiet — the next gesture retries.
                        continue
                    }
                    if (!refusalSurfaced) {
                        refusalSurfaced = true
                        onNonDrivableLens?.invoke(
                            "The camera can't drive this lens's focus — its ring may be " +
                                "mechanical (0x%04X).".format(outcome.rawResponseCode),
                        )
                    }
                }
            }
        }
    }

    private companion object {
        const val MAX_PULSES = 32767

        /** Standard busy answer on the shared channel. */
        const val DEVICE_BUSY_RESPONSE = 0x2019
    }
}
