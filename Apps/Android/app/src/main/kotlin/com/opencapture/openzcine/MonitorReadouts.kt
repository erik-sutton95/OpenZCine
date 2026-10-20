package com.opencapture.openzcine

import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import com.opencapture.monitorui.MonitorIcon
import com.opencapture.monitorui.MonitorTimecodeFormat
import com.opencapture.opencine.appkit.MonitorCapturePresentation
import com.opencapture.opencine.cameracontrols.MonitorLinkObservation
import com.opencapture.opencine.core.Rational
import com.opencapture.opencine.core.ISOValue
import com.opencapture.opencine.core.SettingValue
import com.opencapture.opencine.nikon.CameraIdentity
import com.opencapture.opencine.nikon.CameraPropertySnapshot
import com.opencapture.opencine.nikon.CameraSessionState
import com.opencapture.opencine.nikon.CameraStorageStatus
import com.opencapture.opencine.nikon.IsoPickerPolicy
import com.opencapture.opencine.nikon.LiveFrameTimecode
import com.opencapture.opencine.nikon.MediaStatus
import com.opencapture.opencine.nikon.MonitorTextFormat
import com.opencapture.opencine.vocabulary.ConnectionPhase
import com.opencapture.opencine.vocabulary.SessionRecoveryUi
import java.util.concurrent.atomic.AtomicInteger

internal const val UNAVAILABLE_MONITOR_VALUE = "—"

/** Camera-owned values rendered around Android live view. */
internal data class MonitorCameraReadouts(
    val resolution: String,
    val codec: String,
    val media: String,
    val framesPerSecond: String,
    val batteryPercent: Int?,
    val externalPower: Boolean?,
)

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

/**
 * Title of the FORMAT readout in both capture modes, as iOS titles it: the value names the movie
 * format or, for a still, the image size.
 */
internal const val MONITOR_FORMAT_READOUT_TITLE = "Format"

/** Trims camera text and rejects blank wire values before they reach any monitor surface. */
internal fun String?.monitorValueOrNull(): String? =
    this?.trim()?.takeIf(String::isNotBlank)

/** Accepts only a positive recording frame rate. */
internal fun validMonitorFrameRate(frameRate: Int?): Int? = frameRate?.takeIf { it > 0 }

/** The shared recording-rate label (whole rates print whole), or an explicit unavailable marker. */
internal fun monitorFrameRateLabel(frameRate: Int?): String =
    validMonitorFrameRate(frameRate)
        ?.let { MonitorCapturePresentation.frameRate(Rational(it)) }
        ?: UNAVAILABLE_MONITOR_VALUE

/** Storage label derived from a complete, internally consistent camera readback. */
internal fun monitorStorageLabel(storage: CameraStorageStatus?): String =
    storage?.readout?.takeIf { it.totalBytes != null }?.label ?: UNAVAILABLE_MONITOR_VALUE

/** Accepts only a real battery percentage; platform sentinels stay unavailable. */
internal fun validBatteryPercent(percent: Int?): Int? = percent?.takeIf { it in 0..100 }

/**
 * The FORMAT readout: the common recording label behind the displayed movie token's image-area
 * tag (`[FX] 6K · 25p`), as the body shows it. Swift twin: `nikonRecordingFormatLabel`.
 */
internal fun nikonRecordingFormatLabel(label: String?, imageArea: String?): String? =
    label?.let { text -> imageArea?.let { "[$it] $text" } ?: text }

/**
 * The body's exposure indicator in stops for the shared EV gauge (A1-32, iOS
 * `NikonMonitorShell.exposureReading`): 1/6 EV steps, unknown while the body reports it unlit.
 */
internal fun nikonExposureStops(properties: CameraPropertySnapshot): Double? =
    if (properties.evIndicatorLit == false) null else properties.evIndicatorSixths?.let { it / 6.0 }

/** How the strip marks a camera-owned value and whether a hold on it toggles the body shutter lock. */
internal data class NikonReadoutCue(val dimmed: Boolean, val badge: MonitorIcon?, val holdTogglesShutterLock: Boolean)

internal fun nikonReadoutCue(setting: MonitorCaptureSettingPresentation, photography: Boolean): NikonReadoutCue =
    NikonReadoutCue(
        dimmed = setting.dimmed,
        badge = MonitorIcon.LOCK.takeIf { setting.controlLocked },
        // Stills shutter belongs to the program; the movie SHUTTER hold is the MovieTVLock toggle.
        holdTogglesShutterLock = setting.kind == MonitorPickerKind.SHUTTER && !photography,
    )

/**
 * Whether a press on a strip cell may open its quick drum: a movie SHUTTER adjusts only a known,
 * unlocked circuit, and a camera-owned (dimmed) value has nothing to adjust.
 */
internal fun nikonReadoutQuickEnabled(
    kind: MonitorPickerKind,
    photography: Boolean,
    shutterLocked: Boolean?,
    shutterModeKnown: Boolean,
    cue: NikonReadoutCue,
): Boolean =
    (kind != MonitorPickerKind.SHUTTER || photography || (shutterLocked == false && shutterModeKnown)) &&
        !cue.dimmed

/** A movie strip value from the common seam; `null` is unreported. */
internal fun nikonCommonReadoutLabel(value: SettingValue?, properties: CameraPropertySnapshot): String? =
    when ((value as? SettingValue.Iso)?.value) {
        ISOValue.Auto ->
            IsoPickerPolicy.autoISOLabel(properties.iso, properties.isoAuto, properties.codec.orEmpty())
                ?: MonitorCapturePresentation.label(value)
        else -> value?.let(MonitorCapturePresentation::label)
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
    var media: MediaStatus by mutableStateOf(PREVIEW_MEDIA)
        private set

    /**
     * A watcher's readouts arrive over the relay already formatted by the host — apply them
     * verbatim (iOS `applyRelayState`). Blank fields keep the last value, like [update].
     */
    fun applyRelayed(state: com.opencapture.opencine.nikonwire.MonitorRelayWire.State) {
        resolution = state.resolutionFrameRate.monitorValueOrNull() ?: resolution
        codec = state.codec.monitorValueOrNull() ?: codec
        media =
            state.mediaStatus?.let {
                MediaStatus(it.gigabytesFree, it.percentFree, it.minutesRemaining, it.estimatedMinutesRemaining, it.freeBytes)
            } ?: media
    }

    fun update(snapshot: CameraPropertySnapshot) {
        // Camera is the source of truth: prefer the control presentation
        // (`resolutionFrameRate`, including ZR `[FX]`/`[DX]` tags) over held
        // dimensions, then fall back to WxH+fps, then keep the last value only
        // when this poll omitted those fields entirely.
        resolution =
            snapshot.resolutionFrameRate.monitorValueOrNull()
                ?: MonitorTextFormat.resolutionLabel(
                    snapshot.resolution.monitorValueOrNull(),
                    validMonitorFrameRate(snapshot.frameRate) ?: 0,
                    resolution,
                )
        codec =
            (snapshot.codecSelection.monitorValueOrNull() ?: snapshot.codec.monitorValueOrNull())
                ?.let(MonitorTextFormat::codecCompactLabel)
                ?: codec
        media =
            MediaStatus.from(
                snapshot.storage, snapshot.codec, snapshot.resolution, validMonitorFrameRate(snapshot.frameRate),
            ) ?: media
    }

    private companion object {
        // iOS `CameraDisplayState.preview` seeds.
        const val PREVIEW_RESOLUTION = "6K · 25p"
        const val PREVIEW_CODEC = "R3D NE"
        val PREVIEW_MEDIA = MediaStatus(gigabytesFree = 521, percentFree = 47, minutesRemaining = 47)
    }
}

/** Pictures the monitor presented, counted for the shared link readout's rate. */
internal class PresentedFrameCounter {
    private val count = AtomicInteger()

    @Volatile
    var lastPresentedAtMillis: Long? = null
        private set

    val framesPresented: Int get() = count.get()

    fun presented(nowMillis: Long) {
        count.incrementAndGet()
        lastPresentedAtMillis = nowMillis
    }
}

/**
 * The Nikon monitor's link facts for the shared FPS chip and bars (A3-16). The chip owes the operator
 * two words: a dropped session under bounded recovery and a preview the live session rejected. The
 * bars are the Swift scorer's, which reads the Nikon pump watchdog and the USB transport that the
 * shared inputs cannot carry.
 */
internal fun nikonLinkObservation(
    state: CameraSessionState,
    recovery: SessionRecoveryUi,
    previewRejected: Boolean,
    frames: PresentedFrameCounter,
    linkBars: Int,
): MonitorLinkObservation =
    MonitorLinkObservation(
        connection = when (state) {
            is CameraSessionState.Connected -> ConnectionPhase.LIVE
            CameraSessionState.Connecting -> ConnectionPhase.OPENING_DATALINK
            CameraSessionState.Disconnected -> ConnectionPhase.IDLE
        },
        framesPresented = frames.framesPresented,
        lastPresentedAtMillis = frames.lastPresentedAtMillis,
        feedRecovering = previewRejected,
        sessionRecovering = recovery != SessionRecoveryUi.Idle,
        linkBars = linkBars,
    )

/** Shared monitor readout from enabled camera-header telemetry, including genuine frames. */
internal fun monitorTimecodeLabel(timecode: LiveFrameTimecode?): String? =
    timecode?.takeIf { it.on }?.let {
        MonitorTimecodeFormat.label(it.hour, it.minute, it.second, frames = it.frame)
    }
