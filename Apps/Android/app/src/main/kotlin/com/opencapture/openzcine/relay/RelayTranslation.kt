package com.opencapture.openzcine.relay

import com.opencapture.openzcine.core.CameraControl
import com.opencapture.openzcine.core.LiveAudioMeterChannel
import com.opencapture.openzcine.core.LiveAudioMeterLevels
import com.opencapture.openzcine.core.LiveFeedRotation
import kotlin.math.roundToInt

/**
 * Body orientation on the wire — the core `PTPLiveViewRotation` raw value, the mirror of the
 * bridge's `liveFeedRotationFromWire`. Spelled out rather than taken from the enum's ordinal:
 * a reordered enum must not silently turn every watcher's feed sideways.
 */
internal fun relayRotationWireValue(rotation: LiveFeedRotation): Int =
    when (rotation) {
        LiveFeedRotation.LANDSCAPE -> 0
        LiveFeedRotation.PORTRAIT_GRIP_UP -> 1
        LiveFeedRotation.PORTRAIT_GRIP_DOWN -> 2
        LiveFeedRotation.UPSIDE_DOWN -> 3
    }

/**
 * Translations between this shell's typed values and the relay wire's vocabulary. Pure and
 * shared by both ends: the watcher encodes with them, the broadcaster decodes with them, so a
 * word can never mean one thing going out and another coming in.
 */
internal object RelayPickerVocabulary {
    /** One decoded picker command, ready for [com.opencapture.openzcine.core.CameraSession]. */
    data class Write(val control: CameraControl, val label: String)

    /**
     * The wire's `picker` field is an iOS `CameraPicker` raw value — the core states it outright
     * (`MonitorRelayCommand.pickerValue`: "the shells share that vocabulary already"), so a
     * watcher on either platform names the same control with the same word. This map is the
     * whole of that vocabulary on this side; nothing else translates it.
     *
     * Only the controls iOS actually round-trips are here. FOCUS, AUDIO, stabilization and the
     * stills SIZE tabs are deliberately absent: iOS routes those per-tab through helpers that
     * have no relay fork at all (`applyFocusControl` / `applyAudioControl` queue a LOCAL write),
     * and its own host-side `applyPickerValue` refuses them for want of a control. Sending them
     * would be inventing a wire contract the other platform does not answer.
     */
    private val controlToPicker =
        mapOf(
            CameraControl.ISO to "iso",
            CameraControl.SHUTTER to "shutter",
            CameraControl.IRIS to "iris",
            CameraControl.WHITE_BALANCE to "whiteBalance",
            CameraControl.RESOLUTION_FRAMERATE to "resolution",
            CameraControl.CODEC to "codec",
            CameraControl.EXPOSURE_MODE to "mode",
            CameraControl.STILL_ISO to "stillISO",
            CameraControl.STILL_SHUTTER to "stillShutter",
            CameraControl.STILL_IRIS to "stillIris",
            CameraControl.STILL_DRIVE to "stillDrive",
            CameraControl.STILL_METER to "stillMeter",
            CameraControl.STILL_QUALITY to "stillQuality",
            CameraControl.STILL_PICTURE_CONTROL to "stillPicture",
        )

    private val pickerToControl = controlToPicker.entries.associate { (k, v) -> v to k }

    // The HELPER vocabulary (iOS `forwardExposureHelperOverRelay` / `routeRelayHelperValue`):
    // base ISO, ISO auto and the shutter circuit have no picker of their own on the wire — they
    // ride inside the picker that owns them, as a value the far side recognises by name. The
    // words are iOS's because iOS is the baseline; this side's own labels sit beside them.
    private const val BASE_ISO_LOW = "Low base"
    private const val BASE_ISO_HIGH = "High base"
    private const val ISO_AUTO_ON = "Auto on"
    private const val ISO_AUTO_OFF = "Auto off"

    /** The command a watcher sends for one typed write, or null when the wire has no word. */
    fun command(control: CameraControl, label: String): MonitorRelayWire.Command.PickerValue? =
        when (control) {
            CameraControl.BASE_ISO ->
                pickerValue("iso", if (label.equals("High", true)) BASE_ISO_HIGH else BASE_ISO_LOW)
            CameraControl.ISO_AUTO ->
                pickerValue("iso", if (isOn(label)) ISO_AUTO_ON else ISO_AUTO_OFF)
            // "Angle"/"Speed" — the same two words both shells write, so nothing to translate.
            CameraControl.SHUTTER_MODE -> pickerValue("shutter", label)
            else -> controlToPicker[control]?.let { pickerValue(it, label) }
        }

    /** The typed write a host runs for one received command, or null when it has no meaning. */
    fun write(picker: String, value: String): Write? =
        when {
            picker == "iso" && (value == BASE_ISO_HIGH || value == BASE_ISO_LOW) ->
                Write(CameraControl.BASE_ISO, if (value == BASE_ISO_HIGH) "High" else "Low")
            picker == "iso" && (value == ISO_AUTO_ON || value == ISO_AUTO_OFF) ->
                Write(CameraControl.ISO_AUTO, if (value == ISO_AUTO_ON) "ON" else "OFF")
            // Unambiguous: a shutter VALUE is a time or an angle ("1/50", "180.0°"), never the
            // circuit's own name, so the two words can only be the mode.
            picker == "shutter" && (value == "Angle" || value == "Speed") ->
                Write(CameraControl.SHUTTER_MODE, value)
            else -> pickerToControl[picker]?.let { Write(it, value) }
        }

    private fun pickerValue(picker: String, value: String) =
        MonitorRelayWire.Command.PickerValue(picker, value)

    private fun isOn(label: String): Boolean = label.equals("ON", true) || label == ISO_AUTO_ON
}

/**
 * The camera's 15-segment live-view sound indicator ⇄ the dBFS the meter renders — the core's
 * `AudioMeterLevels(cameraIndicator:)`, transcribed, because the wire carries the body's raw
 * segments (that is what an iOS broadcaster reads out of header bytes 824–827) while this
 * shell's [LiveAudioMeterLevels] is already normalised. Even spacing between silence and 0 dBFS,
 * exactly as the core does it, so a watcher's meter matches the broadcaster's bar for bar.
 */
internal object RelayAudioMeter {
    /** Core `PTPLiveViewSoundIndicator.maxSegment`. */
    private const val MAX_SEGMENT = 14

    /** Core `AudioMeterBallistics.floorDB`. */
    private const val FLOOR_DB = -60.0

    fun decibels(segment: Int): Double =
        FLOOR_DB * (1.0 - segment.coerceIn(0, MAX_SEGMENT).toDouble() / MAX_SEGMENT)

    fun segment(decibels: Double): Int =
        ((1.0 - decibels.coerceIn(FLOOR_DB, 0.0) / FLOOR_DB) * MAX_SEGMENT).roundToInt()

    fun levels(sound: MonitorRelayWire.Sound): LiveAudioMeterLevels =
        LiveAudioMeterLevels(
            left =
                LiveAudioMeterChannel(
                    levelDb = decibels(sound.currentLeft),
                    peakDb = decibels(sound.peakLeft),
                ),
            right =
                LiveAudioMeterChannel(
                    levelDb = decibels(sound.currentRight),
                    peakDb = decibels(sound.peakRight),
                ),
        )

    fun sound(levels: LiveAudioMeterLevels): MonitorRelayWire.Sound =
        MonitorRelayWire.Sound(
            peakLeft = segment(levels.left.peakDb),
            peakRight = segment(levels.right.peakDb),
            currentLeft = segment(levels.left.levelDb),
            currentRight = segment(levels.right.levelDb),
        )
}
