package com.opencapture.openzcine.core

import kotlinx.coroutines.flow.MutableSharedFlow
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.SharedFlow
import kotlinx.coroutines.flow.StateFlow

private val noCameraSessionEvents: SharedFlow<CameraSessionEvent> =
    MutableSharedFlow<CameraSessionEvent>()

private val noCameraProperties: StateFlow<CameraPropertySnapshot> =
    MutableStateFlow(CameraPropertySnapshot())

private val noCameraPropertyRefreshStatus: StateFlow<CameraPropertyRefreshStatus> =
    MutableStateFlow(CameraPropertyRefreshStatus.Idle)

private val alwaysReadyInitialMonitorProperties: StateFlow<Boolean> = MutableStateFlow(true)

private val noCameraRoundTripMilliseconds: StateFlow<Double?> = MutableStateFlow(null)

private val noCameraConnectionProgress: StateFlow<CameraConnectionProgress> =
    MutableStateFlow(CameraConnectionProgress())

/**
 * The operator-visible stage of a camera connection attempt.
 *
 * This deliberately distinguishes PTP-IP reachability from Nikon profile
 * pairing. A successful Init handshake only reaches [HANDSHAKING]; a camera
 * is not paired until its pairing request has been accepted and the profile
 * has survived the camera-side confirmation/reconnect cycle.
 */
public enum class CameraConnectionPhase {
    /** No connection work is active. */
    IDLE,

    /** The operator can now join the camera network. */
    READY_TO_JOIN,

    /** Android is joining the camera's Wi-Fi network. */
    JOINING_WIFI,

    /** The app is looking for a reachable camera endpoint. */
    DISCOVERING,

    /** PTP-IP transport/session establishment is in progress. */
    HANDSHAKING,

    /** Nikon first-time pairing is in progress. */
    PAIRING,

    /** The Nikon accepted pairing; confirm on the camera body and await its restart. */
    CONFIRM_ON_CAMERA,

    /** A validated profile is opening the live-view surface. */
    PREPARING_LIVE_VIEW,

    /** The camera profile is validated and ready for control. */
    CONNECTED,

    /** The current connection attempt failed. */
    FAILED,
}

/**
 * A connection phase and optional operator-facing detail from a camera session.
 *
 * The detail carries only display-safe information, such as a camera name or
 * pairing PIN. It must never contain Wi-Fi credentials or raw protocol data.
 */
public data class CameraConnectionProgress(
    public val phase: CameraConnectionPhase = CameraConnectionPhase.IDLE,
    public val detail: String = "",
)

/**
 * Connection lifecycle of a [CameraSession].
 *
 * Failure detail states (why a connect attempt ended back at
 * [Disconnected]) land together with the real core backend.
 */
public sealed interface CameraSessionState {
    /** No camera is connected and no attempt is in flight. */
    public data object Disconnected : CameraSessionState

    /** A connection attempt is in progress. */
    public data object Connecting : CameraSessionState

    /** A camera is connected and ready for control. */
    public data class Connected(val identity: CameraIdentity) : CameraSessionState
}

/**
 * The camera's movie-record lifecycle as exposed to the Android shell.
 *
 * `STARTING` and `STOPPING` keep an accepted command visible while the camera
 * applies it; callers must not send a second command until the state returns
 * to a stable value.
 */
public enum class CameraRecordingState {
    /** The connected camera is not recording. */
    STANDBY,

    /** A start command is in flight. */
    STARTING,

    /** The camera is recording to its card. */
    RECORDING,

    /** A stop command is in flight. */
    STOPPING,
}

/**
 * A human-readable movie-control selection that the Android shell may ask a
 * connected camera to apply.
 *
 * The selection label is supplied separately to
 * [CameraSession.applyControl]. Kotlin never encodes PTP property identifiers
 * or raw values: the shared Swift core validates the label and builds the
 * Nikon write sequence.
 */
public enum class CameraControl {
    /** Movie ISO sensitivity, such as `"800"`. */
    ISO,

    /**
     * Movie ISO auto/manual (`MovISOAutoControl`), `"ON"` or `"OFF"`.
     * Independent of [EXPOSURE_MODE] Auto.
     */
    ISO_AUTO,

    /** Movie shutter speed or angle, such as `"1/50"` or `"180.0°"`. */
    SHUTTER,

    /** Lens aperture, such as `"f/2.8"`. */
    IRIS,

    /** White-balance preset or Kelvin selection, such as `"5600K"`. */
    WHITE_BALANCE,

    /** Movie autofocus mode, such as `"AF-C"`. */
    FOCUS_MODE,

    /** Movie autofocus area, such as `"Subject"`. */
    FOCUS_AREA,

    /** Movie autofocus subject-detection mode, such as `"People"`. */
    FOCUS_SUBJECT,

    /** Exposure-program selection, such as `"M"`. */
    EXPOSURE_MODE,

    /** Audio input sensitivity, such as `"Auto"` or `"12"`. */
    AUDIO_SENSITIVITY,

    /** Audio input source, such as `"Mic"` or `"Line"`. */
    AUDIO_INPUT,

    /** Wind-noise filter selection, `"ON"` or `"OFF"`. */
    WIND_FILTER,

    /** Input attenuator selection, `"ON"` or `"OFF"`. */
    ATTENUATOR,

    /** 32-bit float audio recording selection, `"ON"` or `"OFF"`. */
    AUDIO_32_BIT_FLOAT,

    /** Camera-advertised dual-base ISO circuit, `"Low"` or `"High"`. */
    BASE_ISO,

    /** Camera-advertised shutter display circuit, `"Angle"` or `"Speed"`. */
    SHUTTER_MODE,

    /** Camera-advertised movie shutter lock state. */
    SHUTTER_LOCK,

    /** Fine-tune selection for the active camera white-balance mode. */
    WHITE_BALANCE_TINT,

    /** Exact camera-advertised recording resolution and frame-rate mode. */
    RESOLUTION_FRAMERATE,

    /** Exact camera-advertised recording codec mode. */
    CODEC,

    /** Camera-advertised movie vibration-reduction mode. */
    VIBRATION_REDUCTION,

    /** Camera-advertised electronic vibration-reduction state. */
    ELECTRONIC_VR,

    // Stills / photo-mode controls (photography pickers; the movie controls
    // above stay untouched in photo mode).

    /** Stills ISO sensitivity, such as `"800"`. */
    STILL_ISO,

    /** Stills Auto-ISO toggle, `"On"` or `"Off"`. */
    STILL_ISO_AUTO,

    /** Stills shutter speed, such as `"1/250"`, `"30s"`, or `"Bulb"`. */
    STILL_SHUTTER,

    /** Stills lens aperture, such as `"f/2.8"`. */
    STILL_IRIS,

    /** Still release/drive mode, such as `"Single"` or `"Continuous H"`. */
    STILL_DRIVE,

    /** Stills autofocus mode, such as `"AF-S"`. */
    STILL_FOCUS_MODE,

    /** Stills autofocus area, such as `"Wide-L"`. */
    STILL_FOCUS_AREA,

    /** Stills subject-detection mode, such as `"People"`. */
    STILL_FOCUS_SUBJECT,

    /** Exposure metering pattern, such as `"Matrix"`. */
    STILL_METER,

    /** Photo sensor crop, such as `"FX"` or `"16:9"`. */
    STILL_IMAGE_AREA,

    /** Camera-enumerated still image-size string, sent back verbatim. */
    STILL_IMAGE_SIZE,

    /** Still image quality, such as `"RAW+JPEG Fine"`. */
    STILL_QUALITY,

    /** NEF (RAW) recording compression, such as `"High efficiency★"`. */
    STILL_RAW_COMPRESSION,

    /** The shooting program a U bank runs as (`"P"`/`"S"`/`"A"`/`"M"`). */
    STILL_USER_MODE_PROGRAM,

    /** Active picture control (profile), such as `"Standard"` or `"Cloud 3"`. */
    STILL_PICTURE_CONTROL,
}

/** Progress of a still release as reported by polling after the release op. */
public enum class StillReleasePoll {
    /** The release (including every frame of a burst) finished. */
    COMPLETE,

    /** AF / shooting / self-timer still running — poll again. */
    IN_PROGRESS,

    /** A bulb or time exposure is holding the shutter open. */
    OPEN_SHUTTER,

    /** The release failed (out of focus, storage full, …) or could not be polled. */
    FAILED,
}

/** The camera's active movie-shutter display convention. */
public enum class CameraShutterMode {
    /** The camera displays a reciprocal exposure time, such as `1/50`. */
    SPEED,

    /** The camera displays a shutter angle, such as `180°`. */
    ANGLE,
}

/** Camera-derived temperature/warning state, never a fabricated temperature reading. */
public enum class CameraTemperatureStatus {
    /** The camera reported a clear warning aggregate. */
    NORMAL,

    /** The camera reported a warning whose specific bit is not yet hardware-verified. */
    WARNING,

    /** The camera reported its hardware-verified overheating state. */
    HOT,
}

/** Capacity and free space for the connected camera's active recording card. */
public data class CameraStorageStatus(
    /** Total capacity in bytes, or zero only when the camera explicitly reports it as unknown. */
    val totalCapacityBytes: Long,
    /** Currently free capacity in bytes. */
    val freeSpaceBytes: Long,
)

/** Capacity and identity for one connected camera recording card. */
public data class CameraStorageSlotStatus(
    /** Authoritative unsigned PTP StorageID represented exactly in a Kotlin [Long]. */
    val storageId: Long,
    /** One-based camera order after unusable storage IDs are removed. */
    val slotNumber: Int,
    /** Total capacity in bytes, or zero only when the camera explicitly reports it as unknown. */
    val totalCapacityBytes: Long,
    /** Currently free capacity in bytes. */
    val freeSpaceBytes: Long,
)

/**
 * Swift-authorized control labels whose protocol values remain in the native session.
 *
 * Values normally come from the connected body's descriptors. A Nikon ZR may also receive a
 * model-scoped fallback for stable controls that its firmware omits or temporarily narrows. An
 * empty list means no safe write domain is known in the current mode. Kotlin must never synthesize
 * values for these fields.
 */
public data class CameraControlCapabilities(
    /** Movie ISO values valid for the active codec and base-ISO circuit. */
    val isoValues: List<String> = emptyList(),
    /** Values from the active shutter angle/speed descriptor. */
    val shutterValues: List<String> = emptyList(),
    /** Apertures advertised for the mounted lens, or the body-scoped lens fallback. */
    val irisValues: List<String> = emptyList(),
    /** Kelvin and preset white-balance values valid on the connected body. */
    val whiteBalanceValues: List<String> = emptyList(),
    /** Movie autofocus modes valid on the connected body. */
    val focusModes: List<String> = emptyList(),
    /** Movie autofocus areas valid on the connected body. */
    val focusAreas: List<String> = emptyList(),
    /** Movie autofocus subject modes valid on the connected body. */
    val focusSubjects: List<String> = emptyList(),
    /** Audio-input sensitivity values valid on the connected body. */
    val audioSensitivities: List<String> = emptyList(),
    /** Audio input-source values valid on the connected body. */
    val audioInputs: List<String> = emptyList(),
    /** Wind-filter values valid on the connected body. */
    val windFilters: List<String> = emptyList(),
    /** Input-attenuator values valid on the connected body. */
    val attenuators: List<String> = emptyList(),
    /** 32-bit-float audio states valid on the connected body. */
    val audio32BitFloat: List<String> = emptyList(),
    /** Dual-base ISO circuits advertised by the camera. */
    val baseIso: List<String> = emptyList(),
    /** Shutter display circuits advertised by the camera. */
    val shutterModes: List<String> = emptyList(),
    /** Shutter lock states advertised by the camera. */
    val shutterLocks: List<String> = emptyList(),
    /** Fine-tune grid values for the active advertised WB tune property. */
    val whiteBalanceTints: List<String> = emptyList(),
    /** Exact recording resolution/frame-rate modes advertised by the camera. */
    val resolutionFrameRates: List<String> = emptyList(),
    /** Exact codec modes advertised by the camera. */
    val codecs: List<String> = emptyList(),
    /** Movie VR modes advertised by the camera. */
    val vibrationReduction: List<String> = emptyList(),
    /** Electronic-VR states advertised by the camera. */
    val electronicVr: List<String> = emptyList(),
    /** Photo image-size strings enumerated by the camera, verbatim. */
    val imageSizes: List<String> = emptyList(),
) {
    /** Returns the advertised labels for one descriptor-dependent control. */
    public fun options(control: CameraControl): List<String> =
        when (control) {
            CameraControl.ISO -> isoValues
            CameraControl.ISO_AUTO -> listOf("ON", "OFF")
            CameraControl.SHUTTER -> shutterValues
            CameraControl.IRIS -> irisValues
            CameraControl.WHITE_BALANCE -> whiteBalanceValues
            // Photo mode: the facade swaps shutter/WB/iris domains to the
            // stills enums, so the still controls read the same lists.
            CameraControl.STILL_SHUTTER -> shutterValues
            CameraControl.STILL_IRIS -> irisValues
            CameraControl.STILL_IMAGE_SIZE -> imageSizes
            CameraControl.FOCUS_MODE -> focusModes
            CameraControl.FOCUS_AREA -> focusAreas
            CameraControl.FOCUS_SUBJECT -> focusSubjects
            CameraControl.AUDIO_SENSITIVITY -> audioSensitivities
            CameraControl.AUDIO_INPUT -> audioInputs
            CameraControl.WIND_FILTER -> windFilters
            CameraControl.ATTENUATOR -> attenuators
            CameraControl.AUDIO_32_BIT_FLOAT -> audio32BitFloat
            CameraControl.BASE_ISO -> baseIso
            CameraControl.SHUTTER_MODE -> shutterModes
            CameraControl.SHUTTER_LOCK -> shutterLocks
            CameraControl.WHITE_BALANCE_TINT -> whiteBalanceTints
            CameraControl.RESOLUTION_FRAMERATE -> resolutionFrameRates
            CameraControl.CODEC -> codecs
            CameraControl.VIBRATION_REDUCTION -> vibrationReduction
            CameraControl.ELECTRONIC_VR -> electronicVr
            else -> emptyList()
        }
}

/**
 * Real, progressively populated camera-property readback for the Android shell.
 *
 * Every value originates in the shared Swift core's `PTPCameraPropertySnapshot`.
 * A `null` field means the body has not reported that property or does not support
 * it in its current mode; it never means a UI/demo fallback value.
 */
public data class CameraPropertySnapshot(
    /** Movie ISO sensitivity. */
    val iso: Long? = null,
    /** Dual-base ISO circuit label when the camera exposes one. */
    val baseIso: String? = null,
    /**
     * Movie ISO auto (`MovISOAutoControl` 0xD0AD). `true` = camera owns ISO.
     * Independent of [exposureMode] Auto.
     */
    val isoAuto: Boolean? = null,
    /** Exposure-program label, such as `M`. */
    val exposureMode: String? = null,
    /** The camera's active shutter display convention. */
    val shutterMode: CameraShutterMode? = null,
    /** Whether the camera reports its movie shutter control as locked. */
    val shutterLocked: Boolean? = null,
    /** Reciprocal shutter-speed label, such as `1/50`. */
    val shutterSpeed: String? = null,
    /** Shutter-angle label, such as `180°`. */
    val shutterAngle: String? = null,
    /** Current aperture label. */
    val iris: String? = null,
    /** White-balance mode label. */
    val whiteBalanceMode: String? = null,
    /** White-balance colour temperature in Kelvin when the body reports one. */
    val whiteBalanceKelvin: Int? = null,
    /** Recording resolution label. */
    val resolution: String? = null,
    /** Recording frame rate. */
    val frameRate: Int? = null,
    /** Camera-reported recording codec label. */
    val codec: String? = null,
    /** Shared-core tone/gamma label inferred from the active recording codec. */
    val tone: String? = null,
    /** Shared-core resolution/frame-rate label matching the active advertised option. */
    val resolutionFrameRate: String? = null,
    /** Shared-core short codec label matching the active advertised option. */
    val codecSelection: String? = null,
    /** Active camera white-balance fine-tune label. */
    val whiteBalanceTint: String? = null,
    /** Battery percentage. */
    val batteryPercent: Int? = null,
    /** Whether the body reports external or USB power. */
    val externalPower: Boolean? = null,
    /** Raw camera warning aggregate, retained without speculative bit decoding. */
    val warningRaw: Int? = null,
    /** Semantic temperature/warning state derived only after [warningRaw] is read. */
    val temperatureStatus: CameraTemperatureStatus? = null,
    /** Current recording-card capacity/free-space readback. */
    val storage: CameraStorageStatus? = null,
    /** Every valid recording card in camera-advertised order. */
    val storageSlots: List<CameraStorageSlotStatus> = emptyList(),
    /** Derived mounted-lens description when sufficient lens properties are available. */
    val lens: String? = null,
    /** Current focal-length label. */
    val focalLength: String? = null,
    /** Movie focus-mode label. */
    val focusMode: String? = null,
    /** Movie focus-area label. */
    val focusArea: String? = null,
    /** Movie focus subject-detection label. */
    val focusSubject: String? = null,
    /** Microphone sensitivity label. */
    val microphoneSensitivity: String? = null,
    /** Microphone level label. */
    val microphoneLevel: String? = null,
    /** Wind-noise-reduction label. */
    val windFilter: String? = null,
    /** Input-attenuator label. */
    val inputAttenuator: String? = null,
    /** Audio input source label. */
    val audioInput: String? = null,
    /** Audio input sensitivity label. */
    val audioSensitivity: String? = null,
    /** 32-bit-float audio-recording label. */
    val audio32BitFloat: String? = null,
    /** Movie vibration-reduction label. */
    val vibrationReduction: String? = null,
    /** Electronic vibration-reduction label. */
    val electronicVr: String? = null,
    /** Camera framing-grid label. */
    val cameraGrid: String? = null,
    /**
     * Photo vs video live-view mode (`LiveViewSelector`). `"photo"` or `"video"`.
     * When `"photo"`, the shell presents photography chrome instead of the cinema strip.
     */
    val captureSelector: String? = null,
    /** Still release/drive mode label (`StillCaptureMode`), such as `Single` or `C30`. */
    val stillCaptureMode: String? = null,
    /** Stills tone mode label (`SDR` or `HLG`) — the photo live-view preview rendering. */
    val stillToneMode: String? = null,
    /** Still image size label. */
    val imageSize: String? = null,
    /** Still compression / quality label. */
    val compression: String? = null,
    /** Exposure metering label. */
    val meteringMode: String? = null,
    /** Flash mode label. */
    val flashMode: String? = null,
    /** Exposure-compensation label. */
    val exposureBias: String? = null,
    /** Frames remaining on the active card in photo mode. */
    val shotsRemaining: Int? = null,
    /** Photo sensor-crop (image area) label, such as `FX` or `16:9`. */
    val imageArea: String? = null,
    /** NEF (RAW) recording compression label. */
    val rawCompression: String? = null,
    /** The shooting program the active U bank runs as (`P`/`S`/`A`/`M`). */
    val userModeProgram: String? = null,
    /** Active picture-control (profile) label, such as `Standard`. */
    val pictureControl: String? = null,
    /** The body's exposure-indicator needle in 1/6 EV steps (±60 == ±10 EV). */
    val evIndicatorSixths: Int? = null,
    /** Whether the body reports its exposure indicator lit (value undefined while off). */
    val evIndicatorLit: Boolean? = null,
    /** Current descriptor-dependent camera-control capabilities. */
    val controlCapabilities: CameraControlCapabilities = CameraControlCapabilities(),
)

/** The non-terminal reason an Android property refresh could not update the snapshot. */
public enum class CameraPropertyRefreshFailure {
    /** No camera control session is connected. */
    NOT_CONNECTED,

    /** The shared Swift protocol library is not bundled into this APK. */
    CORE_UNAVAILABLE,

    /** Camera media owns the command channel until the media screen closes. */
    MEDIA_BUSY,

    /** The requested property is unsupported or unavailable in the current camera mode. */
    UNSUPPORTED_PROPERTY,

    /** A transient command-channel failure prevented this readback. */
    TRANSPORT_FAILED,
}

/** Current readback activity for [CameraSession.cameraProperties]. */
public sealed interface CameraPropertyRefreshStatus {
    /** No connected-session refresh is currently scheduled. */
    public data object Idle : CameraPropertyRefreshStatus

    /** A bounded bootstrap, periodic, or event-triggered read is in flight. */
    public data object Refreshing : CameraPropertyRefreshStatus

    /** The latest read completed and [CameraSession.cameraProperties] is current as far as supported. */
    public data object Ready : CameraPropertyRefreshStatus

    /** The latest read was skipped or failed without changing camera connection state. */
    public data class Degraded(val failure: CameraPropertyRefreshFailure) :
        CameraPropertyRefreshStatus
}

/**
 * One camera-pushed PTP event observed on a connected session's event socket.
 *
 * PTP event codes and parameters are unsigned wire values. Kotlin represents
 * them as non-negative [Int] / [Long] values so unknown Nikon events are
 * preserved instead of being decoded speculatively. Every variant retains the
 * complete wire fields through [rawEventCode], [transactionId], and
 * [rawParameters].
 */
public sealed interface CameraSessionEvent {
    /** The exact PTP event code sent by the camera (`0..0xFFFF`). */
    public val rawEventCode: Int

    /** The exact PTP transaction ID associated with this event (`0..0xFFFFFFFF`). */
    public val transactionId: Long

    /** All raw UINT32 event parameters in their original order. */
    public val rawParameters: List<Long>

    /** Nikon MovieRecordStarted (`0xC10A`), an authoritative recording transition. */
    public data class RecordingStarted(
        override val rawEventCode: Int,
        override val transactionId: Long,
        override val rawParameters: List<Long>,
    ) : CameraSessionEvent

    /** Nikon MovieRecordComplete (`0xC108`), an authoritative standby transition. */
    public data class RecordingStopped(
        override val rawEventCode: Int,
        override val transactionId: Long,
        override val rawParameters: List<Long>,
    ) : CameraSessionEvent

    /**
     * Nikon MovieRecordInterrupted (`0xC105`). [errorCode] is intentionally
     * raw: Nikon does not publish a stable table for this camera-provided
     * value, so callers must not label it as thermal, card, or buffer failure.
     */
    public data class RecordingInterrupted(
        override val rawEventCode: Int,
        override val transactionId: Long,
        override val rawParameters: List<Long>,
        val errorCode: Long?,
    ) : CameraSessionEvent

    /**
     * Standard DevicePropChanged (`0x4006`). [propertyCode] is its first raw
     * UINT32 parameter when present; no property value is invented by this
     * notification alone.
     */
    public data class PropertyChanged(
        override val rawEventCode: Int,
        override val transactionId: Long,
        override val rawParameters: List<Long>,
        val propertyCode: Long?,
    ) : CameraSessionEvent

    /** A valid camera event whose model-specific semantics are not known here. */
    public data class Unknown(
        override val rawEventCode: Int,
        override val transactionId: Long,
        override val rawParameters: List<Long>,
    ) : CameraSessionEvent
}

/** Typed failures from [CameraSession.setRecording]. */
public sealed class CameraRecordingException(message: String) : Exception(message) {
    /** A recording command needs a connected camera session. */
    public data object NotConnected :
        CameraRecordingException("Connect to a camera before changing recording.")

    /** The Swift protocol library was not bundled into the installed APK. */
    public data object CoreUnavailable :
        CameraRecordingException("The shared camera core is unavailable in this app build.")

    /** Camera media owns the serialized command channel. */
    public data object MediaBusy :
        CameraRecordingException("Close camera media before changing recording.")

    /** The camera received and rejected the Nikon recording command. */
    public data object CommandRejected :
        CameraRecordingException("The camera rejected the recording command.")

    /** This session implementation has no protocol path for recording control. */
    public data object Unsupported :
        CameraRecordingException("This camera connection cannot control recording.")

    /** The command channel failed before the camera confirmed the command. */
    public data object TransportFailed :
        CameraRecordingException("The camera connection failed while changing recording.")
}

/** Typed failures from [CameraSession.applyControl]. */
public sealed class CameraControlException(message: String) : Exception(message) {
    /** A camera-control write needs a connected camera session. */
    public data object NotConnected :
        CameraControlException("Connect to a camera before changing a camera control.")

    /** The Swift protocol library was not bundled into the installed APK. */
    public data object CoreUnavailable :
        CameraControlException("The shared camera core is unavailable in this app build.")

    /** Camera media owns the serialized command channel. */
    public data object MediaBusy :
        CameraControlException("Close camera media before changing a camera control.")

    /** The selection is not supported by the camera-control protocol surface. */
    public data object UnsupportedSelection :
        CameraControlException("This camera control or value is not supported.")

    /** The camera received and rejected the property write. */
    public data object CommandRejected :
        CameraControlException("The camera rejected the control change.")

    /** The camera accepted the write response but did not confirm the requested value. */
    public data object ReadbackMismatch :
        CameraControlException(
            "The camera did not keep that control value. Check its recording mode and try again.",
        )

    /** The command channel failed before the camera confirmed the write. */
    public data object TransportFailed :
        CameraControlException("The camera connection failed while changing a control.")
}

/**
 * One autofocus-area centre in the camera's authoritative live-view coordinate space.
 *
 * Coordinates are semantic values only. The shared Swift core owns Nikon operation codes,
 * transaction framing, and transport-specific containers.
 */
public data class CameraFocusPoint(
    /** Inclusive horizontal coordinate reported by the latest camera focus header. */
    public val x: Int,
    /** Inclusive vertical coordinate reported by the latest camera focus header. */
    public val y: Int,
) {
    init {
        require(x >= 0) { "Focus-point x must not be negative." }
        require(y >= 0) { "Focus-point y must not be negative." }
    }
}

/** Typed failures from [CameraSession.changeAfArea] and [CameraSession.resetFocusPoint]. */
public sealed class CameraFocusException(message: String) : Exception(message) {
    /** A focus command needs a connected camera session. */
    public data object NotConnected :
        CameraFocusException("Connect to a camera before changing the focus point.")

    /** The Swift protocol library was not bundled into the installed APK. */
    public data object CoreUnavailable :
        CameraFocusException("The shared camera core is unavailable in this app build.")

    /** Camera media owns the serialized command channel. */
    public data object MediaBusy :
        CameraFocusException("Close camera media before changing the focus point.")

    /** Current camera-owned focus dimensions or reset state are not authoritative yet. */
    public data object Unavailable :
        CameraFocusException("Camera focus metadata is not available yet.")

    /** The camera received and rejected the autofocus-area command. */
    public data object CommandRejected :
        CameraFocusException("The camera rejected the focus-point change.")

    /** The command channel failed before the camera confirmed the command. */
    public data object TransportFailed :
        CameraFocusException("The camera connection failed while changing the focus point.")
}

/**
 * A control session with one camera — the seam the Android shell talks to.
 *
 * Implementations own transport, protocol, and threading; the shell only
 * observes [state] and drives the lifecycle. Either the shared Swift core
 * (bridged via JNI) or a Kotlin port of it provides the production
 * implementation behind this interface.
 */
public interface CameraSession {
    /** Current connection state, updated as the session progresses. */
    public val state: StateFlow<CameraSessionState>

    /**
     * The granular operator-visible progress of the current connection.
     *
     * Transport-only and test sessions expose [CameraConnectionPhase.IDLE]
     * until they opt into this richer lifecycle.
     */
    public val connectionProgress: StateFlow<CameraConnectionProgress>
        get() = noCameraConnectionProgress

    /** Current movie-record lifecycle for this session. */
    public val recordingState: StateFlow<CameraRecordingState>

    /**
     * The latest real camera-property readback.
     *
     * Production sessions populate this after connection, then update it with
     * low-rate polling and debounced `DevicePropChanged` events. Transport-only
     * implementations expose an all-null snapshot.
     */
    public val cameraProperties: StateFlow<CameraPropertySnapshot>
        get() = noCameraProperties

    /**
     * Activity/failure state for [cameraProperties]. A degraded readback does
     * not imply that [state] has disconnected.
     */
    public val propertyRefreshStatus: StateFlow<CameraPropertyRefreshStatus>
        get() = noCameraPropertyRefreshStatus

    /**
     * True after the first post-connect property bootstrap has finished (or
     * when this session does not perform a bootstrap).
     *
     * Production sessions set this false while the full AF/lens/focus/audio
     * burst runs, then true so the monitor can open live view. Transport-only
     * and demo sessions default to true so they never block the feed.
     */
    public val initialMonitorPropertiesReady: StateFlow<Boolean>
        get() = alwaysReadyInitialMonitorProperties

    /**
     * Latest real serialized PTP command round-trip duration.
     *
     * Null means unavailable and is restored on disconnect/session replacement;
     * implementations must never synthesize a latency value.
     */
    public val latestCommandRoundTripMilliseconds: StateFlow<Double?>
        get() = noCameraRoundTripMilliseconds

    /**
     * Camera-pushed PTP events from the active event channel.
     *
     * Production sessions use a bounded, non-blocking stream so slow UI
     * collectors cannot back up the camera socket. Implementations without an
     * event-capable transport expose an empty stream.
     */
    public val events: SharedFlow<CameraSessionEvent>
        get() = noCameraSessionEvents

    /**
     * Discovers and connects to a camera.
     *
     * Moves [state] through [CameraSessionState.Connecting] and ends at
     * [CameraSessionState.Connected] on success or back at
     * [CameraSessionState.Disconnected] when no camera is reachable.
     */
    public suspend fun connect()

    /**
     * Starts or stops movie recording on the connected camera.
     *
     * Implementations serialize this with their live-view and teardown work,
     * then update [recordingState] only after the camera accepts the command.
     * A failure is reported as a typed [CameraRecordingException].
     */
    @Throws(CameraRecordingException::class)
    public suspend fun setRecording(recording: Boolean)

    /**
     * Applies one human-readable [label] for a typed [control] on the connected
     * camera.
     *
     * Implementations must keep protocol encoding in their camera core and
     * serialize the write with recording, live-view, and teardown work. The
     * default is intentionally unsupported for transport-only implementations
     * that never opened a PTP control session.
     */
    @Throws(CameraControlException::class)
    public suspend fun applyControl(control: CameraControl, label: String) {
        throw CameraControlException.UnsupportedSelection
    }

    /**
     * Fires one still release when the body is in photo mode (AF-then-release
     * to the card). Activation-style: returning confirms the release started;
     * poll [pollStillRelease] between frames for completion. The protocol
     * operation stays behind the shared Swift boundary.
     */
    @Throws(CameraControlException::class)
    public suspend fun initiateStillCapture() {
        throw CameraControlException.UnsupportedSelection
    }

    /** One readiness poll while a still release is in flight. */
    public suspend fun pollStillRelease(): StillReleasePoll = StillReleasePoll.FAILED

    /**
     * Ends a bulb/time exposure or stops a running burst; frames captured so
     * far are kept. Refusals after a run already ended are expected.
     */
    @Throws(CameraControlException::class)
    public suspend fun terminateStillCapture() {
        throw CameraControlException.UnsupportedSelection
    }

    /**
     * Opens/closes the continuous-burst remote-mode bracket around a held
     * shutter press. The body's dials lock while it is open, so callers
     * bracket it as tightly as possible.
     */
    @Throws(CameraControlException::class)
    public suspend fun setStillBurstBracket(active: Boolean) {
        throw CameraControlException.UnsupportedSelection
    }

    /**
     * Moves the camera autofocus area to [point].
     *
     * Implementations serialize this with recording, property writes, media ownership, and
     * teardown. Rapid calls may be coalesced so only the newest waiting coordinate reaches the
     * camera. Protocol encoding must stay behind the shared Swift boundary.
     *
     * @return `true` only when the camera accepted this coordinate, or `false` when a newer call
     *   superseded it before native I/O.
     */
    @Throws(CameraFocusException::class)
    public suspend fun changeAfArea(point: CameraFocusPoint): Boolean {
        throw CameraFocusException.Unavailable
    }

    /**
     * Recentres the autofocus area using the latest camera-owned dimensions and focus state.
     *
     * A subject-tracking reset may release tracking, wait for authoritative live-view headers,
     * recenter, and restore unchanged camera modes. It never starts tracking.
     */
    @Throws(CameraFocusException::class)
    public suspend fun resetFocusPoint() {
        throw CameraFocusException.Unavailable
    }

    /**
     * Requests one immediate, coalesced property refresh.
     *
     * Production implementations preserve any last-known values when a body
     * rejects a mode-dependent property; observe [propertyRefreshStatus] for
     * that non-terminal outcome. Transport-only implementations do no I/O.
     */
    public suspend fun refreshProperties(): Unit = Unit

    /**
     * Asks the session to read the camera's exposure indicator at a fast
     * needle cadence between regular property polls (the EV meter tool is
     * visible). No-op for sessions without a property poll loop.
     */
    public fun setExposureIndicatorFastPolling(active: Boolean) {}

    /** Tears down the session and returns [state] to [CameraSessionState.Disconnected]. */
    public suspend fun disconnect()
}
