package com.opencapture.openzcine.relay

import java.util.Base64
import org.json.JSONArray
import org.json.JSONObject

/**
 * The monitor-relay wire protocol, TRANSCRIBED from the shared core
 * (`Sources/OpenZCineCore/MonitorRelayProtocol.swift`) and pinned to the same byte/JSON vectors
 * in `MonitorRelayWireTest` (the Swift side pins them in `MonitorRelayWireVectorsTests`), so the
 * two implementations cannot quietly disagree. iOS broadcasters and watchers speak exactly this.
 *
 * Framing: `[4-byte big-endian (payload length + 1)][1-byte kind][payload]`.
 * Frame payload: `[4-byte big-endian metadata-JSON length][metadata JSON][image bytes]`.
 * All other payloads are JSON. `Data` fields ride as base64 strings (Swift `Codable`'s wire
 * form); enum-with-associated-values commands ride as single-key objects.
 */
object MonitorRelayWire {
    const val SERVICE_TYPE: String = "_openzcine-mon._tcp"

    /** Wire version. A watcher refuses a host it cannot speak to rather than rendering nonsense. */
    const val VERSION: Int = 2

    /** Bonjour TXT key naming the camera host this broadcast serves. */
    const val SERVED_CAMERA_TXT_KEY: String = "ch"

    /**
     * TXT key distinguishing a joinable broadcast from a "camera in use" beacon. Absent or any
     * value other than "0" means watchable (older builds advertise no key). The beacon exists
     * so the `ch=` probe shield protects a held camera even when the operator is not sharing.
     */
    const val WATCHABLE_TXT_KEY: String = "w"

    const val MAXIMUM_PAYLOAD_BYTES: Int = 8 * 1024 * 1024

    object Kind {
        const val HELLO: Int = 0x01
        const val STATE: Int = 0x02
        const val FRAME: Int = 0x03
        const val CONTROL_TOKEN: Int = 0x04
        const val JOIN_DENIED: Int = 0x05
        const val REQUEST_CONTROL: Int = 0x10
        const val RELEASE_CONTROL: Int = 0x11
        const val COMMAND: Int = 0x12

        val all: Set<Int> =
            setOf(
                HELLO,
                STATE,
                FRAME,
                CONTROL_TOKEN,
                JOIN_DENIED,
                REQUEST_CONTROL,
                RELEASE_CONTROL,
                COMMAND,
            )
    }

    object FrameCodec {
        const val JPEG: Int = 0
        const val HEVC: Int = 1
    }

    fun encodeFrame(kind: Int, payload: ByteArray): ByteArray {
        val out = ByteArray(5 + payload.size)
        writeUInt32BE(out, 0, payload.size + 1)
        out[4] = kind.toByte()
        payload.copyInto(out, 5)
        return out
    }

    /** One decoded message plus how many bytes it consumed. */
    data class Decoded(val kind: Int, val payload: ByteArray, val consumedBytes: Int)

    class DesynchronizedStreamException(message: String) : Exception(message)

    /**
     * Decodes the first whole message in `buffer[0 until available]`, or null when more bytes
     * are needed. Throws on an oversized declaration or unknown kind — the caller must drop the
     * connection rather than try to resynchronise (the iOS rule).
     */
    fun decodeFrame(buffer: ByteArray, available: Int): Decoded? {
        if (available < 5) return null
        val declared = readUInt32BE(buffer, 0)
        if (declared < 1) throw DesynchronizedStreamException("declared length $declared")
        if (declared - 1 > MAXIMUM_PAYLOAD_BYTES) {
            throw DesynchronizedStreamException("payload too large (${declared - 1})")
        }
        val total = 4 + declared
        if (available < total) return null
        val kind = buffer[4].toInt() and 0xFF
        if (kind !in Kind.all) throw DesynchronizedStreamException("unknown kind $kind")
        return Decoded(kind, buffer.copyOfRange(5, total), total)
    }

    // MARK: Frame payload

    data class FramePayload(val metadata: FrameMetadata, val image: ByteArray)

    fun encodeFramePayload(metadata: FrameMetadata, image: ByteArray): ByteArray {
        val json = metadata.toJson().toString().toByteArray(Charsets.UTF_8)
        val out = ByteArray(4 + json.size + image.size)
        writeUInt32BE(out, 0, json.size)
        json.copyInto(out, 4)
        image.copyInto(out, 4 + json.size)
        return out
    }

    fun decodeFramePayload(payload: ByteArray): FramePayload {
        require(payload.size >= 4) { "truncated frame payload" }
        val jsonLength = readUInt32BE(payload, 0)
        require(payload.size >= 4 + jsonLength) { "truncated frame payload" }
        val json = JSONObject(String(payload, 4, jsonLength, Charsets.UTF_8))
        return FramePayload(
            metadata = FrameMetadata.fromJson(json),
            image = payload.copyOfRange(4 + jsonLength, payload.size),
        )
    }

    // MARK: Payload models (wire twins of the core's Codable structs)

    data class Hello(
        val version: Int,
        val hostName: String,
        val cameraName: String?,
        val passcode: String? = null,
    ) {
        fun toJson(): JSONObject =
            JSONObject().apply {
                put("version", version)
                put("hostName", hostName)
                cameraName?.let { put("cameraName", it) }
                passcode?.let { put("passcode", it) }
            }

        companion object {
            fun fromJson(json: JSONObject): Hello =
                Hello(
                    version = json.getInt("version"),
                    hostName = json.getString("hostName"),
                    cameraName = json.optStringOrNull("cameraName"),
                    passcode = json.optStringOrNull("passcode"),
                )
        }
    }

    data class JoinDenied(val reason: String, val passcodeRequired: Boolean) {
        fun toJson(): JSONObject =
            JSONObject().apply {
                put("reason", reason)
                put("passcodeRequired", passcodeRequired)
            }

        companion object {
            fun fromJson(json: JSONObject): JoinDenied =
                JoinDenied(
                    reason = json.getString("reason"),
                    passcodeRequired = json.getBoolean("passcodeRequired"),
                )
        }
    }

    data class ControlToken(val holderName: String, val holderIsRecipient: Boolean) {
        fun toJson(): JSONObject =
            JSONObject().apply {
                put("holderName", holderName)
                put("holderIsRecipient", holderIsRecipient)
            }

        companion object {
            fun fromJson(json: JSONObject): ControlToken =
                ControlToken(
                    holderName = json.getString("holderName"),
                    holderIsRecipient = json.getBoolean("holderIsRecipient"),
                )
        }
    }

    data class StateValue(val label: String, val value: String)

    data class MediaStatus(
        val gigabytesFree: Int,
        val percentFree: Int,
        val minutesRemaining: Int,
    )

    /** Host → viewer camera readouts; field-for-field the core's `MonitorRelayState`. */
    data class State(
        val recordState: String,
        val resolutionFrameRate: String,
        val codec: String,
        val media: String,
        val liveFPS: String,
        val cameraBatteryPercent: Int,
        val cameraName: String,
        val lens: String,
        val temperature: String,
        val values: List<StateValue>,
        val mediaStatus: MediaStatus?,
        val isRecording: Boolean,
        val allowsControlRequests: Boolean? = null,
    ) {
        fun toJson(): JSONObject =
            JSONObject().apply {
                put("recordState", recordState)
                put("resolutionFrameRate", resolutionFrameRate)
                put("codec", codec)
                put("media", media)
                put("liveFPS", liveFPS)
                put("cameraBatteryPercent", cameraBatteryPercent)
                put("cameraName", cameraName)
                put("lens", lens)
                put("temperature", temperature)
                put(
                    "values",
                    JSONArray().apply {
                        values.forEach {
                            put(
                                JSONObject()
                                    .put("label", it.label)
                                    .put("value", it.value)
                            )
                        }
                    },
                )
                mediaStatus?.let {
                    put(
                        "mediaStatus",
                        JSONObject()
                            .put("gigabytesFree", it.gigabytesFree)
                            .put("percentFree", it.percentFree)
                            .put("minutesRemaining", it.minutesRemaining),
                    )
                }
                put("isRecording", isRecording)
                allowsControlRequests?.let { put("allowsControlRequests", it) }
            }

        companion object {
            const val RECORD_STATE_STANDBY = "standby"
            const val RECORD_STATE_RECORDING = "recording"

            fun fromJson(json: JSONObject): State =
                State(
                    recordState = json.getString("recordState"),
                    resolutionFrameRate = json.getString("resolutionFrameRate"),
                    codec = json.getString("codec"),
                    media = json.getString("media"),
                    liveFPS = json.getString("liveFPS"),
                    cameraBatteryPercent = json.getInt("cameraBatteryPercent"),
                    cameraName = json.getString("cameraName"),
                    lens = json.getString("lens"),
                    temperature = json.getString("temperature"),
                    values =
                        json.getJSONArray("values").let { array ->
                            buildList {
                                for (index in 0 until array.length()) {
                                    val entry = array.getJSONObject(index)
                                    add(
                                        StateValue(
                                            entry.getString("label"),
                                            entry.getString("value"),
                                        )
                                    )
                                }
                            }
                        },
                    mediaStatus =
                        json.optJSONObject("mediaStatus")?.let {
                            MediaStatus(
                                gigabytesFree = it.getInt("gigabytesFree"),
                                percentFree = it.getInt("percentFree"),
                                minutesRemaining = it.getInt("minutesRemaining"),
                            )
                        },
                    isRecording = json.getBoolean("isRecording"),
                    allowsControlRequests =
                        if (json.has("allowsControlRequests")) {
                            json.getBoolean("allowsControlRequests")
                        } else {
                            null
                        },
                )
        }
    }

    data class Timecode(
        val on: Boolean,
        val hour: Int,
        val minute: Int,
        val second: Int,
        val frame: Int,
    )

    data class FocusBox(val centerX: Int, val centerY: Int, val width: Int, val height: Int)

    data class Focus(
        val coordinateWidth: Int,
        val coordinateHeight: Int,
        val focusResult: Int,
        val subjectDetectionActive: Boolean,
        val trackingAFActive: Boolean,
        val selectedBoxIndex: Int?,
        val boxes: List<FocusBox>,
    )

    data class Sound(
        val peakLeft: Int,
        val peakRight: Int,
        val currentLeft: Int,
        val currentRight: Int,
    )

    /** Per-frame readings; field-for-field the core's `MonitorRelayFrameMetadata`. */
    data class FrameMetadata(
        val timecode: Timecode?,
        val isRecording: Boolean,
        val focus: Focus?,
        val levelRoll: Double?,
        val levelPitch: Double?,
        val sound: Sound?,
        val codec: Int = FrameCodec.JPEG,
        val isKeyframe: Boolean = true,
        val parameterSets: List<ByteArray>? = null,
    ) {
        fun toJson(): JSONObject =
            JSONObject().apply {
                timecode?.let {
                    put(
                        "timecode",
                        JSONObject()
                            .put("on", it.on)
                            .put("hour", it.hour)
                            .put("minute", it.minute)
                            .put("second", it.second)
                            .put("frame", it.frame),
                    )
                }
                put("isRecording", isRecording)
                focus?.let { value ->
                    put(
                        "focus",
                        JSONObject().apply {
                            put("coordinateWidth", value.coordinateWidth)
                            put("coordinateHeight", value.coordinateHeight)
                            put("focusResult", value.focusResult)
                            put("subjectDetectionActive", value.subjectDetectionActive)
                            put("trackingAFActive", value.trackingAFActive)
                            value.selectedBoxIndex?.let { put("selectedBoxIndex", it) }
                            put(
                                "boxes",
                                JSONArray().apply {
                                    value.boxes.forEach {
                                        put(
                                            JSONObject()
                                                .put("centerX", it.centerX)
                                                .put("centerY", it.centerY)
                                                .put("width", it.width)
                                                .put("height", it.height)
                                        )
                                    }
                                },
                            )
                        },
                    )
                }
                levelRoll?.let { put("levelRoll", it) }
                levelPitch?.let { put("levelPitch", it) }
                sound?.let {
                    put(
                        "sound",
                        JSONObject()
                            .put("peakLeft", it.peakLeft)
                            .put("peakRight", it.peakRight)
                            .put("currentLeft", it.currentLeft)
                            .put("currentRight", it.currentRight),
                    )
                }
                put("codec", codec)
                put("isKeyframe", isKeyframe)
                parameterSets?.let { sets ->
                    put(
                        "parameterSets",
                        JSONArray().apply {
                            sets.forEach { put(Base64.getEncoder().encodeToString(it)) }
                        },
                    )
                }
            }

        companion object {
            fun fromJson(json: JSONObject): FrameMetadata =
                FrameMetadata(
                    timecode =
                        json.optJSONObject("timecode")?.let {
                            Timecode(
                                on = it.getBoolean("on"),
                                hour = it.getInt("hour"),
                                minute = it.getInt("minute"),
                                second = it.getInt("second"),
                                frame = it.getInt("frame"),
                            )
                        },
                    isRecording = json.getBoolean("isRecording"),
                    focus =
                        json.optJSONObject("focus")?.let { value ->
                            Focus(
                                coordinateWidth = value.getInt("coordinateWidth"),
                                coordinateHeight = value.getInt("coordinateHeight"),
                                focusResult = value.getInt("focusResult"),
                                subjectDetectionActive =
                                    value.getBoolean("subjectDetectionActive"),
                                trackingAFActive = value.getBoolean("trackingAFActive"),
                                selectedBoxIndex =
                                    if (value.has("selectedBoxIndex")) {
                                        value.getInt("selectedBoxIndex")
                                    } else {
                                        null
                                    },
                                boxes =
                                    value.getJSONArray("boxes").let { array ->
                                        buildList {
                                            for (index in 0 until array.length()) {
                                                val box = array.getJSONObject(index)
                                                add(
                                                    FocusBox(
                                                        centerX = box.getInt("centerX"),
                                                        centerY = box.getInt("centerY"),
                                                        width = box.getInt("width"),
                                                        height = box.getInt("height"),
                                                    )
                                                )
                                            }
                                        }
                                    },
                            )
                        },
                    levelRoll = json.optDoubleOrNull("levelRoll"),
                    levelPitch = json.optDoubleOrNull("levelPitch"),
                    sound =
                        json.optJSONObject("sound")?.let {
                            Sound(
                                peakLeft = it.getInt("peakLeft"),
                                peakRight = it.getInt("peakRight"),
                                currentLeft = it.getInt("currentLeft"),
                                currentRight = it.getInt("currentRight"),
                            )
                        },
                    codec = json.optInt("codec", FrameCodec.JPEG),
                    isKeyframe = json.optBoolean("isKeyframe", true),
                    parameterSets =
                        json.optJSONArray("parameterSets")?.let { array ->
                            buildList {
                                for (index in 0 until array.length()) {
                                    add(Base64.getDecoder().decode(array.getString(index)))
                                }
                            }
                        },
                )
        }
    }

    /**
     * A viewer camera command — the core's enum-with-associated-values, whose Swift Codable wire
     * form is a single-key object: `{"toggleRecording":{}}`,
     * `{"focusPoint":{"cameraX":…,"cameraY":…,"coordinateWidth":…,"coordinateHeight":…}}`,
     * `{"pickerValue":{"picker":…,"value":…}}`.
     */
    sealed interface Command {
        data object ToggleRecording : Command

        data class FocusPoint(
            val cameraX: Int,
            val cameraY: Int,
            val coordinateWidth: Int,
            val coordinateHeight: Int,
        ) : Command

        data class PickerValue(val picker: String, val value: String) : Command

        fun toJson(): JSONObject =
            when (this) {
                is ToggleRecording -> JSONObject().put("toggleRecording", JSONObject())
                is FocusPoint ->
                    JSONObject()
                        .put(
                            "focusPoint",
                            JSONObject()
                                .put("cameraX", cameraX)
                                .put("cameraY", cameraY)
                                .put("coordinateWidth", coordinateWidth)
                                .put("coordinateHeight", coordinateHeight),
                        )
                is PickerValue ->
                    JSONObject()
                        .put(
                            "pickerValue",
                            JSONObject().put("picker", picker).put("value", value),
                        )
            }

        companion object {
            fun fromJson(json: JSONObject): Command? =
                when {
                    json.has("toggleRecording") -> ToggleRecording
                    json.has("focusPoint") ->
                        json.getJSONObject("focusPoint").let {
                            FocusPoint(
                                cameraX = it.getInt("cameraX"),
                                cameraY = it.getInt("cameraY"),
                                coordinateWidth = it.getInt("coordinateWidth"),
                                coordinateHeight = it.getInt("coordinateHeight"),
                            )
                        }
                    json.has("pickerValue") ->
                        json.getJSONObject("pickerValue").let {
                            PickerValue(it.getString("picker"), it.getString("value"))
                        }
                    else -> null
                }
        }
    }

    internal fun writeUInt32BE(target: ByteArray, offset: Int, value: Int) {
        target[offset] = (value ushr 24).toByte()
        target[offset + 1] = (value ushr 16).toByte()
        target[offset + 2] = (value ushr 8).toByte()
        target[offset + 3] = value.toByte()
    }

    internal fun readUInt32BE(source: ByteArray, offset: Int): Int =
        ((source[offset].toInt() and 0xFF) shl 24) or
            ((source[offset + 1].toInt() and 0xFF) shl 16) or
            ((source[offset + 2].toInt() and 0xFF) shl 8) or
            (source[offset + 3].toInt() and 0xFF)
}

private fun JSONObject.optStringOrNull(key: String): String? =
    if (has(key) && !isNull(key)) getString(key) else null

private fun JSONObject.optDoubleOrNull(key: String): Double? =
    if (has(key) && !isNull(key)) getDouble(key) else null
