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
    private var lastPublishNanos: Long = 0L

    /**
     * Retains the exact timecode state paired with the latest displayed frame.
     * Skips Snapshot write when unchanged, and caps UI publishes at ~10 Hz so
     * the top bar does not recompose on every live frame (~25 Hz).
     */
    fun accept(timecode: LiveFrameTimecode?): Unit {
        val next =
            if (cameraIdentity == null) null else authoritativeTimecode(timecode)
        if (next == retainedTimecode) return
        val now = System.nanoTime()
        // Always publish the first value and any second-boundary jump immediately.
        val secondChanged =
            retainedTimecode == null ||
                next == null ||
                retainedTimecode!!.hour != next.hour ||
                retainedTimecode!!.minute != next.minute ||
                retainedTimecode!!.second != next.second
        if (!secondChanged && lastPublishNanos != 0L && now - lastPublishNanos < 100_000_000L) {
            return
        }
        lastPublishNanos = now
        retainedTimecode = next
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

// ── iOS top-bar readout parity (MonitorTextFormat + MediaStatus + FrameRateSampler) ──

/** iOS `MonitorTextFormat.resolutionLabel(fromProperty:)`: `"6048x3402"` + fps → `"6K · 25p"`. */
internal fun monitorResolutionLabel(
    resolution: String?,
    frameRate: Int?,
    fallback: String,
): String {
    val property = resolution.monitorValueOrNull() ?: return fallback
    val parts = property.split("x")
    val width = parts.getOrNull(0)?.trim()?.toIntOrNull()
    val height = parts.getOrNull(1)?.trim()?.toIntOrNull()
    if (parts.size != 2 || width == null || height == null) return fallback
    val resolutionClass =
        when {
            width >= 7680 -> "8K"
            width >= 5000 -> "6K"
            width >= 3500 -> "4K"
            else -> "$width"
        }
    return "$resolutionClass · ${frameRate ?: 0}p"
}

/** iOS `MonitorTextFormat.codecShortLabel`: `"R3D NE 12-bit R3D"` → `"R3D NE"`. */
internal fun monitorCodecShortLabel(codec: String): String {
    val stripped = codec.trim()
    val redundantQualifier = Regex("""\s+\d+-bit\s+.+$""").find(stripped) ?: return stripped
    return stripped.substring(0, redundantQualifier.range.first).trim()
}

/** iOS `MonitorTextFormat.codecCompactLabel`: `ProRes`→`PR`, H.26x drops the bit depth. */
internal fun monitorCodecCompactLabel(codec: String?, fallback: String): String {
    val value = codec.monitorValueOrNull() ?: return fallback
    var label = monitorCodecShortLabel(value).replace("ProRes", "PR")
    if (label.startsWith("H.26")) {
        Regex("""\s+\d+-bit$""").find(label)?.let { label = label.substring(0, it.range.first) }
    }
    return label.trim()
}

/** iOS `MediaStatus`: free space plus the conservative remaining-minutes estimate. */
internal data class MonitorMediaStatus(
    val gigabytesFree: Long,
    val percentFree: Long,
    val minutesRemaining: Int,
) {
    /** iOS `MediaStatus.capacityLabel`. */
    val capacityLabel: String get() = "$gigabytesFree GB · $percentFree%"

    /** iOS `MediaStatus.durationLabel`. */
    val durationLabel: String get() = "$minutesRemaining Min"
}

/**
 * iOS `RecordDurationEstimator`, ported table and scaling verbatim: per-codec
 * base Mbps at UHD 24p, scaled by pixel count and frame rate, rounded down so
 * the "Min" readout under-promises.
 */
internal object MonitorRecordDurationEstimator {
    private val baseBitrateMbps =
        mapOf(
            "R3D NE" to 600.0,
            "N-RAW" to 470.0,
            "ProRes RAW HQ" to 1700.0,
            "ProRes 422 HQ" to 707.0,
            "H.265" to 190.0,
            "H.264" to 75.0,
        )
    private const val FALLBACK_BITRATE_MBPS = 250.0
    private const val REFERENCE_PIXELS = 3840.0 * 2160.0
    private const val REFERENCE_FRAME_RATE = 24.0

    fun minutesRemaining(
        codecShortLabel: String,
        resolutionWidth: Int,
        resolutionHeight: Int,
        frameRate: Int,
        gigabytesFree: Long,
    ): Int {
        if (gigabytesFree <= 0L) return 0
        val base = baseBitrateMbps[codecShortLabel] ?: FALLBACK_BITRATE_MBPS
        val mbps =
            base * (resolutionWidth.toDouble() * resolutionHeight / REFERENCE_PIXELS) *
                (frameRate / REFERENCE_FRAME_RATE)
        if (!mbps.isFinite() || mbps <= 0.0) return 0
        val seconds = gigabytesFree * 8_000.0 / mbps
        return (seconds / 60.0).toInt()
    }
}

/** Builds the iOS-parity media status from an internally consistent storage readback. */
internal fun monitorMediaStatus(
    storage: CameraStorageStatus?,
    codec: String?,
    resolution: String?,
    frameRate: Int?,
): MonitorMediaStatus? {
    if (storage == null || storage.totalCapacityBytes <= 0L) return null
    if (storage.freeSpaceBytes !in 0L..storage.totalCapacityBytes) return null
    val gigabytesFree = storage.freeSpaceBytes / 1_000_000_000L
    val percentFree =
        (storage.freeSpaceBytes.toDouble() * 100.0 / storage.totalCapacityBytes.toDouble()).toLong()
    val parts = resolution.orEmpty().split("x")
    val width = parts.getOrNull(0)?.trim()?.toIntOrNull() ?: 0
    val height = parts.getOrNull(1)?.trim()?.toIntOrNull() ?: 0
    val minutes =
        MonitorRecordDurationEstimator.minutesRemaining(
            codecShortLabel = codec?.let(::monitorCodecShortLabel).orEmpty(),
            resolutionWidth = width,
            resolutionHeight = height,
            frameRate = validMonitorFrameRate(frameRate) ?: 0,
            gigabytesFree = gigabytesFree,
        )
    return MonitorMediaStatus(gigabytesFree, percentFree, minutes)
}

/**
 * iOS never blanks a top-bar readout: values seed from `CameraDisplayState.preview`
 * and each later camera readback replaces its field while missing fields hold
 * the previous value. Scoped per connected-camera identity like the timecode.
 */
internal class MonitorReadoutRetention(private val cameraIdentity: CameraIdentity?) {
    var resolution: String by mutableStateOf(PREVIEW_RESOLUTION)
        private set
    var codec: String by mutableStateOf(PREVIEW_CODEC)
        private set
    var media: MonitorMediaStatus by mutableStateOf(PREVIEW_MEDIA)
        private set

    fun update(snapshot: CameraPropertySnapshot) {
        resolution = monitorResolutionLabel(snapshot.resolution, snapshot.frameRate, resolution)
        codec = monitorCodecCompactLabel(snapshot.codec, codec)
        media =
            monitorMediaStatus(
                snapshot.storage, snapshot.codec, snapshot.resolution, snapshot.frameRate,
            ) ?: media
    }

    private companion object {
        // iOS `CameraDisplayState.preview` seeds.
        const val PREVIEW_RESOLUTION = "6K · 25p"
        const val PREVIEW_CODEC = "R3D NE"
        val PREVIEW_MEDIA = MonitorMediaStatus(gigabytesFree = 521, percentFree = 47, minutesRemaining = 47)
    }
}

/**
 * iOS `FrameRateSampler`: live-measured delivery rate over a rolling 30-interval
 * window, published at most ~1 Hz, `"%.2f"`. Starts as iOS's `"READY"` until the
 * first measurable interval.
 */
internal class MonitorFrameRateSampler {
    private val intervals = ArrayDeque<Double>()
    private var lastFrameNanos = 0L
    private var lastPublishNanos = 0L

    var formatted: String by mutableStateOf(READY)
        private set

    fun accept(nowNanos: Long) {
        if (lastFrameNanos != 0L) {
            val seconds = (nowNanos - lastFrameNanos) / 1e9
            if (seconds > 0.0) {
                intervals.addLast(seconds)
                while (intervals.size > WINDOW) intervals.removeFirst()
            }
        }
        lastFrameNanos = nowNanos
        if (intervals.isNotEmpty() && nowNanos - lastPublishNanos >= 1_000_000_000L) {
            lastPublishNanos = nowNanos
            formatted = String.format(Locale.ROOT, "%.2f", intervals.size / intervals.sum())
        }
    }

    private companion object {
        const val WINDOW = 30
        const val READY = "READY"
    }
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
