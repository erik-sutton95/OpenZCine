package com.opencapture.openzcine

import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import com.opencapture.openzcine.core.CameraIdentity
import com.opencapture.openzcine.core.CameraPropertySnapshot
import com.opencapture.openzcine.core.CameraSessionState
import com.opencapture.openzcine.core.CameraStorageStatus
import com.opencapture.openzcine.core.LiveFrameTimecode
import java.util.Locale

internal const val UNAVAILABLE_MONITOR_VALUE = "—"
internal const val UNAVAILABLE_TIMECODE = "—:—:—:—"

/** Camera-owned values rendered around Android live view. */
internal data class MonitorCameraReadouts(
    val resolution: String,
    val codec: String,
    val media: String,
    val framesPerSecond: String,
    val batteryPercent: Int?,
    val externalPower: Boolean?,
)

/** Visual battery state, including a separately rendered external-power marker. */
internal data class MonitorBatteryPresentation(
    val percent: Int?,
    val label: String,
    val externalPower: Boolean,
)

/**
 * Last camera timecode accepted by the existing display decoder.
 *
 * The holder is remembered by connected-camera identity, not by preview source,
 * so DISP 3 can release every frame collector without discarding its camera-owned
 * hero value. A disconnect or replacement camera receives a new empty holder.
 */
internal class MonitorTimecodeRetention(private val cameraIdentity: CameraIdentity?) {
    private var retainedTimecode: LiveFrameTimecode? by mutableStateOf(null)

    /** Retains the exact timecode state paired with the latest displayed frame. */
    fun accept(timecode: LiveFrameTimecode?): Unit {
        retainedTimecode =
            if (cameraIdentity == null) null else authoritativeTimecode(timecode)
    }

    /** Returns the retained value only while the same camera is still connected. */
    fun timecodeFor(sessionState: CameraSessionState): LiveFrameTimecode? {
        val currentIdentity = (sessionState as? CameraSessionState.Connected)?.identity
        return retainedTimecode.takeIf { cameraIdentity != null && currentIdentity == cameraIdentity }
    }
}

/** Identity key that scopes retained frame metadata to one connected camera. */
internal fun monitorTimecodeOwner(sessionState: CameraSessionState): CameraIdentity? =
    (sessionState as? CameraSessionState.Connected)?.identity

/**
 * Projects only values reported by the portable camera-property snapshot.
 * Missing, blank, or malformed fields stay visibly unavailable.
 */
internal fun monitorCameraReadouts(snapshot: CameraPropertySnapshot): MonitorCameraReadouts =
    MonitorCameraReadouts(
        resolution = snapshot.resolution.monitorValueOrNull() ?: UNAVAILABLE_MONITOR_VALUE,
        codec = snapshot.codec.monitorValueOrNull() ?: UNAVAILABLE_MONITOR_VALUE,
        media = monitorStorageLabel(snapshot.storage),
        framesPerSecond = monitorFrameRateLabel(snapshot.frameRate),
        batteryPercent = validBatteryPercent(snapshot.batteryPercent),
        externalPower = snapshot.externalPower,
    )

/** Trims camera text and rejects blank wire values before they reach any monitor surface. */
internal fun String?.monitorValueOrNull(): String? =
    this?.trim()?.takeIf(String::isNotBlank)

/** Accepts only a positive recording frame rate. */
internal fun validMonitorFrameRate(frameRate: Int?): Int? = frameRate?.takeIf { it > 0 }

/** Camera recording-rate label, or an explicit unavailable marker. */
internal fun monitorFrameRateLabel(frameRate: Int?): String =
    validMonitorFrameRate(frameRate)
        ?.let { String.format(Locale.ROOT, "%d.00", it) }
        ?: UNAVAILABLE_MONITOR_VALUE

/** Storage label derived from a complete, internally consistent camera readback. */
internal fun monitorStorageLabel(storage: CameraStorageStatus?): String {
    if (storage == null || storage.totalCapacityBytes <= 0L) return UNAVAILABLE_MONITOR_VALUE
    if (storage.freeSpaceBytes !in 0L..storage.totalCapacityBytes) {
        return UNAVAILABLE_MONITOR_VALUE
    }
    val percent =
        (storage.freeSpaceBytes.toDouble() * 100.0 / storage.totalCapacityBytes.toDouble())
            .toLong()
    val freeGigabytes = storage.freeSpaceBytes / 1_000_000_000L
    return "$freeGigabytes GB · $percent%"
}

/** Accepts only a real battery percentage; platform sentinels stay unavailable. */
internal fun validBatteryPercent(percent: Int?): Int? = percent?.takeIf { it in 0..100 }

/** Camera battery label that preserves authoritative external-power-only readback. */
internal fun batteryReadoutLabel(percent: Int?, externalPower: Boolean? = null): String =
    validBatteryPercent(percent)?.let { "$it%" }
        ?: if (externalPower == true) "EXT" else UNAVAILABLE_MONITOR_VALUE

/** Builds the battery label and visible power-marker state from authoritative readback. */
internal fun monitorBatteryPresentation(
    percent: Int?,
    externalPower: Boolean? = null,
): MonitorBatteryPresentation {
    val validPercent = validBatteryPercent(percent)
    return MonitorBatteryPresentation(
        percent = validPercent,
        label = batteryReadoutLabel(validPercent, externalPower),
        externalPower = externalPower == true,
    )
}

/**
 * Keeps only enabled, structurally valid camera timecode. No shell clock or
 * elapsed-time extrapolation is allowed to stand in for a missing frame value.
 */
internal fun authoritativeTimecode(timecode: LiveFrameTimecode?): LiveFrameTimecode? =
    timecode?.takeIf {
        it.on &&
            it.hour in 0..23 &&
            it.minute in 0..59 &&
            it.second in 0..59 &&
            it.frame in 0..255
    }

/** Exact camera timecode label, or the explicit unavailable placeholder. */
internal fun cameraTimecodeLabel(timecode: LiveFrameTimecode?): String =
    authoritativeTimecode(timecode)?.let {
        String.format(Locale.ROOT, "%02d:%02d:%02d:%02d", it.hour, it.minute, it.second, it.frame)
    } ?: UNAVAILABLE_TIMECODE
