package com.opencapture.openzcine

import com.opencapture.openzcine.core.CameraPropertySnapshot
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

/**
 * Projects only values reported by the portable camera-property snapshot.
 * Missing, blank, or malformed fields stay visibly unavailable.
 */
internal fun monitorCameraReadouts(snapshot: CameraPropertySnapshot): MonitorCameraReadouts =
    MonitorCameraReadouts(
        resolution = snapshot.resolution.nonBlankOrUnavailable(),
        codec = snapshot.codec.nonBlankOrUnavailable(),
        media = monitorStorageLabel(snapshot.storage),
        framesPerSecond =
            snapshot.frameRate
                ?.takeIf { it > 0 }
                ?.let { String.format(Locale.ROOT, "%d.00", it) }
                ?: UNAVAILABLE_MONITOR_VALUE,
        batteryPercent = validBatteryPercent(snapshot.batteryPercent),
        externalPower = snapshot.externalPower,
    )

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

private fun String?.nonBlankOrUnavailable(): String =
    this?.takeIf(String::isNotBlank) ?: UNAVAILABLE_MONITOR_VALUE
