package com.opencapture.openzcine.wearrelay

import java.nio.ByteBuffer
import java.nio.charset.CharacterCodingException
import java.nio.charset.CodingErrorAction
import java.util.Base64
import java.util.Locale
import org.json.JSONException
import org.json.JSONObject
import org.json.JSONTokener

/**
 * Versioned Data Layer names for the phone-mediated Wear OS remote.
 *
 * This module intentionally contains no camera session, pairing, PTP, Swift
 * runtime, network, or credential API. It only mirrors the small canonical
 * `WatchRelayProtocol.swift` envelope so the Wear process can render a phone
 * snapshot and request one record toggle through the handheld.
 */
public object WearRelayTransport {
    /** Version of the Data Layer path and canonical one-byte envelope contract. */
    public const val PROTOCOL_VERSION: Int = 1

    /** Capability advertised by the Wear OS app. */
    public const val WEAR_CAPABILITY: String = "openzcine_wear_relay_v1"

    /** Capability advertised by the handheld app. */
    public const val PHONE_CAPABILITY: String = "openzcine_phone_relay_v1"

    /** Phone-to-watch state snapshot path. */
    public const val STATE_PATH: String = "/openzcine/wear/v1/state"

    /** Phone-to-watch latest-wins preview path. */
    public const val FRAME_PATH: String = "/openzcine/wear/v1/frame"

    /** Watch-to-phone acknowledgement for one received preview. */
    public const val FRAME_ACK_PATH: String = "/openzcine/wear/v1/frame-ack"

    /** Watch-to-phone record command path. */
    public const val COMMAND_PATH: String = "/openzcine/wear/v1/command"

    /** Phone-to-watch record command result path. */
    public const val RESULT_PATH: String = "/openzcine/wear/v1/result"

    /**
     * Correlates a record command with its one phone reply.
     *
     * The suffix is a Data Layer routing detail; [WatchRelayEnvelope] remains
     * the canonical Swift v1 one-byte-kind-plus-JSON payload.
     */
    public fun commandPath(requestID: Long): String {
        require(requestID > 0L)
        return "$COMMAND_PATH/$requestID"
    }

    /** Correlates a record result with its originating watch command. */
    public fun resultPath(requestID: Long): String {
        require(requestID > 0L)
        return "$RESULT_PATH/$requestID"
    }

    /** Correlates a preview with the acknowledgement sent at watch receipt. */
    public fun framePath(requestID: Long): String {
        require(requestID > 0L)
        return "$FRAME_PATH/$requestID"
    }

    /** Routes one preview-receipt acknowledgement back to the phone. */
    public fun frameAckPath(requestID: Long): String {
        require(requestID > 0L)
        return "$FRAME_ACK_PATH/$requestID"
    }

    /** Reads a command request identifier from a v1 command path. */
    public fun commandRequestID(path: String): Long? = requestID(path, COMMAND_PATH)

    /** Reads a result request identifier from a v1 result path. */
    public fun resultRequestID(path: String): Long? = requestID(path, RESULT_PATH)

    /** Reads a preview identifier from a v1 frame path. */
    public fun frameRequestID(path: String): Long? = requestID(path, FRAME_PATH)

    /** Reads a preview identifier from a v1 acknowledgement path. */
    public fun frameAckRequestID(path: String): Long? = requestID(path, FRAME_ACK_PATH)

    private fun requestID(path: String, base: String): Long? {
        val prefix = "$base/"
        if (!path.startsWith(prefix)) return null
        val value = path.removePrefix(prefix)
        if (value.isEmpty() || value.any { !it.isDigit() }) return null
        return value.toLongOrNull()?.takeIf { it > 0L }
    }
}

/** One-byte message tags owned by the portable Swift wire contract. */
public enum class WatchRelayKind(public val tag: Int) {
    /** Phone-to-watch state snapshot. */
    STATE(0x01),

    /** Phone-to-watch downscaled JPEG preview. */
    FRAME(0x02),

    /** Watch-to-phone command. */
    COMMAND(0x10),

    /** Phone-to-watch command result. */
    RESULT(0x11),
    ;

    internal companion object {
        fun fromTag(tag: Int): WatchRelayKind? = entries.firstOrNull { it.tag == tag }
    }
}

/** Connection state rendered by the wearable; it never implies a direct camera path. */
public enum class WatchConnectionState(public val wireValue: String) {
    /** The foreground phone relay is unavailable. */
    DISCONNECTED("disconnected"),

    /** The foreground phone monitor has a connected camera and live feed. */
    CONNECTED("connected"),

    /** The foreground phone app has no camera session. */
    NO_CAMERA("noCamera"),
    ;

    internal companion object {
        fun fromWire(value: String): WatchConnectionState? =
            entries.firstOrNull { it.wireValue == value }
    }
}

/** Camera-owned record state exposed to the watch. */
public enum class WatchRecordState(public val wireValue: String) {
    /** The camera is not recording. */
    STANDBY("standby"),

    /** The camera is recording. */
    RECORDING("recording"),
    ;

    internal companion object {
        fun fromWire(value: String): WatchRecordState? = entries.firstOrNull { it.wireValue == value }
    }
}

/** Timecode fields as carried by the portable Swift watch relay model. */
public data class WatchTimecode(
    /** Whether the phone has an authoritative camera timecode readout. */
    public val on: Boolean,
    /** Hour component. */
    public val hour: Int,
    /** Minute component. */
    public val minute: Int,
    /** Second component. */
    public val second: Int,
    /** Frame component. */
    public val frame: Int,
) {
    /** Renders the fixed-width monitor readout. */
    public fun label(): String =
        String.format(Locale.ROOT, "%02d:%02d:%02d:%02d", hour, minute, second, frame)

    /** Explicit placeholder used before an authoritative camera frame arrives. */
    public companion object {
        /** Returns the non-fabricated unavailable timecode. */
        public fun unavailable(): WatchTimecode = WatchTimecode(false, 0, 0, 0, 0)
    }
}

/** Camera storage readout, present only when the handheld has real camera property data. */
public data class WatchMediaStatus(
    /** Free storage in whole GiB, supplied by the phone from camera readback. */
    public val gigabytesFree: Int,
    /** Free capacity percentage, supplied by the phone from camera readback. */
    public val percentFree: Int,
    /** Remaining record time when available; Android currently leaves this unavailable. */
    public val minutesRemaining: Int,
) {
    /** Capacity label matching the iOS watch's preferred compact presentation. */
    public fun capacityLabel(): String = "$gigabytesFree GB · $percentFree%"
}

/** Phone-to-watch monitor/camera snapshot. */
public data class WatchRelayState(
    /** Camera-owned record state. */
    public val recordState: WatchRecordState,
    /** Current authoritative timecode, or explicit unavailable placeholder. */
    public val timecode: WatchTimecode,
    /** Structured storage only when the camera has supplied it. */
    public val mediaStatus: WatchMediaStatus?,
    /** Honest fallback media label when no structured storage is available. */
    public val media: String,
    /** Camera battery percent only when read from the camera; otherwise zero. */
    public val cameraBatteryPercent: Int,
    /** Camera name only when a session is connected. */
    public val cameraName: String,
    /** Current record state after camera/session readback. */
    public val isRecording: Boolean,
    /** Foreground phone relay/camera availability. */
    public val connection: WatchConnectionState,
    /** Whether the phone monitor's live feed is currently active. */
    public val feedLive: Boolean,
    /** Measured camera live FPS when Android has it, otherwise an unavailable label. */
    public val liveFPS: String,
) : WatchRelayPayload {
    override val kind: WatchRelayKind = WatchRelayKind.STATE
}

/** Phone-to-watch preview image, bounded before it reaches this wire. */
public class WatchRelayFrame(
    /** Small re-encoded JPEG preview. */
    public val jpeg: ByteArray,
    /** Timecode paired with the preview. */
    public val timecode: WatchTimecode,
    /** Camera record state paired with the preview. */
    public val isRecording: Boolean,
) : WatchRelayPayload {
    override val kind: WatchRelayKind = WatchRelayKind.FRAME
}

/** The sole watch-to-phone camera command. */
public enum class WatchRelayCommand(public val wireValue: String) : WatchRelayPayload {
    /** Requests that the foreground phone relay toggle record. */
    TOGGLE_RECORD("toggleRecord"),
    ;

    override val kind: WatchRelayKind = WatchRelayKind.COMMAND

    internal companion object {
        fun fromWire(value: String): WatchRelayCommand? =
            entries.firstOrNull { it.wireValue == value }
    }
}

/** Phone-to-watch reply to a command. */
public data class WatchCommandResult(
    /** Whether the phone accepted and dispatched the camera command. */
    public val accepted: Boolean,
    /** Camera record state after the decision. */
    public val isRecording: Boolean,
    /** Concise rejection text when [accepted] is false. */
    public val error: String?,
) : WatchRelayPayload {
    override val kind: WatchRelayKind = WatchRelayKind.RESULT
}

/** Every payload that can be enclosed in the portable one-byte relay envelope. */
public sealed interface WatchRelayPayload {
    /** Canonical first-byte message kind. */
    public val kind: WatchRelayKind
}

/** Strict parse failure for an untrusted Data Layer payload. */
public sealed class WatchRelayWireException(message: String) : IllegalArgumentException(message) {
    /** The envelope did not contain a kind byte. */
    public data object EmptyEnvelope : WatchRelayWireException("Watch relay envelope is empty.")

    /** A peer supplied a kind byte the canonical protocol does not define. */
    public data class UnknownKind(public val tag: Int) :
        WatchRelayWireException("Watch relay kind $tag is unknown.")

    /** A peer exceeded the bounded message size. */
    public data object PayloadTooLarge : WatchRelayWireException("Watch relay payload exceeds its limit.")

    /** JSON was malformed, structurally wrong, or had trailing non-whitespace bytes. */
    public data class MalformedPayload(public val detail: String) :
        WatchRelayWireException("Watch relay payload is malformed: $detail")
}

/**
 * Thin Android implementation of the canonical Swift `[kind byte] + JSON`
 * envelope. It is transport-only: values are presented or relayed, never used
 * to discover, pair, authenticate, or speak to a camera.
 */
public object WatchRelayEnvelope {
    /** Upper bound below Data Layer's 100 KiB message limit. */
    public const val MAX_ENVELOPE_BYTES: Int = 90 * 1024

    /** The largest allowed decoded preview JPEG. */
    public const val MAX_PREVIEW_JPEG_BYTES: Int = 64 * 1024

    /** Encodes [payload] as the canonical one-byte tag plus UTF-8 JSON. */
    public fun encode(payload: WatchRelayPayload): ByteArray {
        val encodedPayload = encodePayload(payload).toByteArray(Charsets.UTF_8)
        val envelope = ByteArray(encodedPayload.size + 1)
        envelope[0] = payload.kind.tag.toByte()
        encodedPayload.copyInto(envelope, destinationOffset = 1)
        check(envelope.size <= MAX_ENVELOPE_BYTES) { "Watch relay envelope exceeds its limit." }
        return envelope
    }

    /** Reads only the canonical kind byte. */
    @Throws(WatchRelayWireException::class)
    public fun kindOf(envelope: ByteArray): WatchRelayKind {
        if (envelope.isEmpty()) throw WatchRelayWireException.EmptyEnvelope
        return WatchRelayKind.fromTag(envelope[0].toInt() and 0xFF)
            ?: throw WatchRelayWireException.UnknownKind(envelope[0].toInt() and 0xFF)
    }

    /** Strictly decodes a known relay envelope. */
    @Throws(WatchRelayWireException::class)
    public fun decode(envelope: ByteArray): WatchRelayPayload {
        if (envelope.size > MAX_ENVELOPE_BYTES) throw WatchRelayWireException.PayloadTooLarge
        val kind = kindOf(envelope)
        val value = decodeJSON(envelope.copyOfRange(1, envelope.size))
        return when (kind) {
            WatchRelayKind.STATE -> decodeState(value.requireObject())
            WatchRelayKind.FRAME -> decodeFrame(value.requireObject())
            WatchRelayKind.COMMAND -> decodeCommand(value.requireString())
            WatchRelayKind.RESULT -> decodeResult(value.requireObject())
        }
    }

    private fun encodePayload(payload: WatchRelayPayload): String =
        when (payload) {
            is WatchRelayState -> encodeState(payload).toString()
            is WatchRelayFrame -> encodeFrame(payload).toString()
            is WatchRelayCommand -> JSONObject.quote(payload.wireValue)
            is WatchCommandResult -> encodeResult(payload).toString()
        }

    private fun encodeState(state: WatchRelayState): JSONObject =
        JSONObject()
            .put("recordState", state.recordState.wireValue)
            .put("timecode", encodeTimecode(state.timecode))
            .apply { state.mediaStatus?.let { put("mediaStatus", encodeMediaStatus(it)) } }
            .put("media", state.media)
            .put("cameraBatteryPercent", state.cameraBatteryPercent)
            .put("cameraName", state.cameraName)
            .put("isRecording", state.isRecording)
            .put("connection", state.connection.wireValue)
            .put("feedLive", state.feedLive)
            .put("liveFPS", state.liveFPS)

    private fun encodeFrame(frame: WatchRelayFrame): JSONObject {
        require(frame.jpeg.size <= MAX_PREVIEW_JPEG_BYTES) { "Watch preview is too large." }
        return JSONObject()
            .put("jpeg", Base64.getEncoder().encodeToString(frame.jpeg))
            .put("timecode", encodeTimecode(frame.timecode))
            .put("isRecording", frame.isRecording)
    }

    private fun encodeResult(result: WatchCommandResult): JSONObject =
        JSONObject()
            .put("accepted", result.accepted)
            .put("isRecording", result.isRecording)
            .apply { result.error?.let { put("error", it) } }

    private fun encodeTimecode(timecode: WatchTimecode): JSONObject =
        JSONObject()
            .put("on", timecode.on)
            .put("hour", timecode.hour)
            .put("minute", timecode.minute)
            .put("second", timecode.second)
            .put("frame", timecode.frame)

    private fun encodeMediaStatus(status: WatchMediaStatus): JSONObject =
        JSONObject()
            .put("gigabytesFree", status.gigabytesFree)
            .put("percentFree", status.percentFree)
            .put("minutesRemaining", status.minutesRemaining)

    private fun decodeState(value: JSONObject): WatchRelayState =
        WatchRelayState(
            recordState = enumValue(value.requireString("recordState"), WatchRecordState::fromWire),
            timecode = decodeTimecode(value.requireObject("timecode")),
            mediaStatus = value.optionalObject("mediaStatus")?.let(::decodeMediaStatus),
            media = value.requireString("media"),
            cameraBatteryPercent = value.requireInt("cameraBatteryPercent"),
            cameraName = value.requireString("cameraName"),
            isRecording = value.requireBoolean("isRecording"),
            connection = enumValue(value.requireString("connection"), WatchConnectionState::fromWire),
            feedLive = value.requireBoolean("feedLive"),
            liveFPS = value.requireString("liveFPS"),
        )

    private fun decodeFrame(value: JSONObject): WatchRelayFrame {
        val jpeg =
            try {
                Base64.getDecoder().decode(value.requireString("jpeg"))
            } catch (_: IllegalArgumentException) {
                throw WatchRelayWireException.MalformedPayload("jpeg is not base64")
            }
        if (jpeg.size > MAX_PREVIEW_JPEG_BYTES) throw WatchRelayWireException.PayloadTooLarge
        return WatchRelayFrame(
            jpeg = jpeg,
            timecode = decodeTimecode(value.requireObject("timecode")),
            isRecording = value.requireBoolean("isRecording"),
        )
    }

    private fun decodeCommand(value: String): WatchRelayCommand =
        enumValue(value, WatchRelayCommand::fromWire)

    private fun decodeResult(value: JSONObject): WatchCommandResult =
        WatchCommandResult(
            accepted = value.requireBoolean("accepted"),
            isRecording = value.requireBoolean("isRecording"),
            error = value.optionalString("error"),
        )

    private fun decodeTimecode(value: JSONObject): WatchTimecode =
        WatchTimecode(
            on = value.requireBoolean("on"),
            hour = value.requireInt("hour"),
            minute = value.requireInt("minute"),
            second = value.requireInt("second"),
            frame = value.requireInt("frame"),
        )

    private fun decodeMediaStatus(value: JSONObject): WatchMediaStatus =
        WatchMediaStatus(
            gigabytesFree = value.requireInt("gigabytesFree"),
            percentFree = value.requireInt("percentFree"),
            minutesRemaining = value.requireInt("minutesRemaining"),
        )

    private fun decodeJSON(payload: ByteArray): Any {
        val text = strictUTF8(payload)
        try {
            val tokenizer = JSONTokener(text)
            val value = tokenizer.nextValue()
            if (tokenizer.nextClean().code != 0) {
                throw WatchRelayWireException.MalformedPayload("trailing content")
            }
            return value
        } catch (error: WatchRelayWireException) {
            throw error
        } catch (error: JSONException) {
            throw WatchRelayWireException.MalformedPayload(error.message ?: "invalid JSON")
        }
    }

    private fun strictUTF8(payload: ByteArray): String =
        try {
            Charsets.UTF_8
                .newDecoder()
                .onMalformedInput(CodingErrorAction.REPORT)
                .onUnmappableCharacter(CodingErrorAction.REPORT)
                .decode(ByteBuffer.wrap(payload))
                .toString()
        } catch (_: CharacterCodingException) {
            throw WatchRelayWireException.MalformedPayload("invalid UTF-8")
        }

    private fun <T> enumValue(value: String, finder: (String) -> T?): T =
        finder(value)
            ?: throw WatchRelayWireException.MalformedPayload("unsupported enum value '$value'")

    private fun Any?.requireObject(): JSONObject =
        this as? JSONObject
            ?: throw WatchRelayWireException.MalformedPayload("expected an object")

    private fun Any?.requireString(): String =
        this as? String
            ?: throw WatchRelayWireException.MalformedPayload("expected a string")

    private fun JSONObject.requireObject(key: String): JSONObject =
        requireValue(key) as? JSONObject
            ?: throw WatchRelayWireException.MalformedPayload("$key is not an object")

    private fun JSONObject.optionalObject(key: String): JSONObject? =
        optionalValue(key)?.let {
            it as? JSONObject
                ?: throw WatchRelayWireException.MalformedPayload("$key is not an object")
        }

    private fun JSONObject.requireString(key: String): String =
        requireValue(key) as? String
            ?: throw WatchRelayWireException.MalformedPayload("$key is not a string")

    private fun JSONObject.optionalString(key: String): String? =
        optionalValue(key)?.let {
            it as? String
                ?: throw WatchRelayWireException.MalformedPayload("$key is not a string")
        }

    private fun JSONObject.requireBoolean(key: String): Boolean =
        requireValue(key) as? Boolean
            ?: throw WatchRelayWireException.MalformedPayload("$key is not a boolean")

    private fun JSONObject.requireInt(key: String): Int {
        val number =
            requireValue(key) as? Number
                ?: throw WatchRelayWireException.MalformedPayload("$key is not a number")
        val double = number.toDouble()
        val long = number.toLong()
        if (!double.isFinite() || double != long.toDouble() || long !in Int.MIN_VALUE..Int.MAX_VALUE) {
            throw WatchRelayWireException.MalformedPayload("$key is not an integer")
        }
        return long.toInt()
    }

    private fun JSONObject.requireValue(key: String): Any =
        optionalValue(key)
            ?: throw WatchRelayWireException.MalformedPayload("$key is missing")

    private fun JSONObject.optionalValue(key: String): Any? {
        if (!has(key)) return null
        val value = opt(key)
        return if (value == JSONObject.NULL) null else value
    }
}
