package com.opencapture.openzcine.relay

import kotlin.test.Test
import kotlin.test.assertContentEquals
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import kotlin.test.assertNull
import org.json.JSONObject

/**
 * Contract vectors shared with the core's `MonitorRelayWireVectorsTests` (Swift). JSON payload
 * vectors are DECODE-side (key order is not part of the contract on either platform); the
 * framing and frame-payload prefixes are byte-exact. If either side edits the protocol, the twin
 * test on the other side fails.
 */
class MonitorRelayWireTest {
    @Test
    fun `bonjour advertisement constants match the shared contract`() {
        // The service type and TXT keys must match the Swift core byte-for-byte, or the probe
        // shield (`ch`) and the in-use beacon flag (`w`) silently stop crossing platforms.
        assertEquals("_openzcine-mon._tcp", MonitorRelayWire.SERVICE_TYPE)
        assertEquals("ch", MonitorRelayWire.SERVED_CAMERA_TXT_KEY)
        assertEquals("w", MonitorRelayWire.WATCHABLE_TXT_KEY)
    }

    @Test
    fun `framing bytes match the shared vector`() {
        val encoded = MonitorRelayWire.encodeFrame(MonitorRelayWire.Kind.HELLO, "{}".toByteArray())
        assertContentEquals(
            byteArrayOf(0x00, 0x00, 0x00, 0x03, 0x01, 0x7B, 0x7D),
            encoded,
        )
        val decoded = MonitorRelayWire.decodeFrame(encoded, encoded.size)!!
        assertEquals(MonitorRelayWire.Kind.HELLO, decoded.kind)
        assertContentEquals("{}".toByteArray(), decoded.payload)
        assertEquals(7, decoded.consumedBytes)
    }

    @Test
    fun `framing waits for whole messages and rejects desynchronised streams`() {
        val encoded =
            MonitorRelayWire.encodeFrame(MonitorRelayWire.Kind.STATE, ByteArray(10) { it.toByte() })
        assertNull(MonitorRelayWire.decodeFrame(encoded, 4))
        assertNull(MonitorRelayWire.decodeFrame(encoded, encoded.size - 1))
        assertFailsWith<MonitorRelayWire.DesynchronizedStreamException> {
            // Declared length far beyond the cap: drop the connection, never resynchronise.
            MonitorRelayWire.decodeFrame(
                byteArrayOf(0x7F, 0x00, 0x00, 0x00, 0x01),
                5,
            )
        }
        assertFailsWith<MonitorRelayWire.DesynchronizedStreamException> {
            MonitorRelayWire.decodeFrame(byteArrayOf(0x00, 0x00, 0x00, 0x02, 0x6F, 0x00), 6)
        }
    }

    @Test
    fun `hello decodes the shared vector both with and without a passcode`() {
        val hello =
            MonitorRelayWire.Hello.fromJson(
                JSONObject(
                    """{"version":2,"hostName":"iPhone","cameraName":"ZR_6002199","passcode":"4321"}"""
                )
            )
        assertEquals(MonitorRelayWire.Hello(2, "iPhone", "ZR_6002199", "4321"), hello)
        val bare = MonitorRelayWire.Hello.fromJson(JSONObject("""{"version":2,"hostName":"iPad"}"""))
        assertEquals(MonitorRelayWire.Hello(2, "iPad", null, null), bare)
        // Round trip through this side's encoder.
        assertEquals(hello, MonitorRelayWire.Hello.fromJson(hello.toJson()))
        // Twin of the Swift `helloCarriesCodecs` pin: the codec declaration a watcher sends when
        // its hardware cannot decode the HEVC stream; absent means everything (legacy watchers
        // keep HEVC).
        val jpegOnly =
            MonitorRelayWire.Hello.fromJson(
                JSONObject("""{"version":2,"hostName":"Galaxy","codecs":["jpeg"]}""")
            )
        assertEquals(listOf("jpeg"), jpegOnly.codecs)
        assertEquals(null, bare.codecs)
        assertEquals(jpegOnly, MonitorRelayWire.Hello.fromJson(jpegOnly.toJson()))
    }

    @Test
    fun `join denied and control token decode the shared vectors`() {
        assertEquals(
            MonitorRelayWire.JoinDenied("This broadcast asks for a passcode.", true),
            MonitorRelayWire.JoinDenied.fromJson(
                JSONObject(
                    """{"reason":"This broadcast asks for a passcode.","passcodeRequired":true}"""
                )
            ),
        )
        assertEquals(
            MonitorRelayWire.ControlToken("iPhone 17 Pro Max", false),
            MonitorRelayWire.ControlToken.fromJson(
                JSONObject("""{"holderName":"iPhone 17 Pro Max","holderIsRecipient":false}""")
            ),
        )
    }

    @Test
    fun `state decodes the shared vector and defaults absent control policy to null`() {
        val state =
            MonitorRelayWire.State.fromJson(
                JSONObject(
                    """
                    {"recordState":"recording","resolutionFrameRate":"6K · 25p","codec":"R3D NE",
                     "media":"CFexpress","liveFPS":"25.0","cameraBatteryPercent":76,
                     "cameraName":"ZR_6002199","lens":"NIKKOR Z 24-70","temperature":"OK",
                     "values":[{"label":"ISO","value":"800"}],
                     "mediaStatus":{"gigabytesFree":412,"percentFree":81,"minutesRemaining":96},
                     "isRecording":true,"allowsControlRequests":false}
                    """
                )
            )
        assertEquals(MonitorRelayWire.State.RECORD_STATE_RECORDING, state.recordState)
        assertEquals("6K · 25p", state.resolutionFrameRate)
        assertEquals(76, state.cameraBatteryPercent)
        assertEquals(listOf(MonitorRelayWire.StateValue("ISO", "800")), state.values)
        assertEquals(MonitorRelayWire.MediaStatus(412, 81, 96), state.mediaStatus)
        assertEquals(false, state.allowsControlRequests)
        val bare =
            MonitorRelayWire.State.fromJson(
                JSONObject(
                    """
                    {"recordState":"standby","resolutionFrameRate":"","codec":"","media":"",
                     "liveFPS":"","cameraBatteryPercent":0,"cameraName":"","lens":"",
                     "temperature":"","values":[],"isRecording":false}
                    """
                )
            )
        assertNull(bare.allowsControlRequests)
        assertNull(bare.mediaStatus)
        assertEquals(state, MonitorRelayWire.State.fromJson(state.toJson()))
    }

    @Test
    fun `frame payload round-trips metadata and passes image bytes through untouched`() {
        val metadata =
            MonitorRelayWire.FrameMetadata(
                timecode = MonitorRelayWire.Timecode(true, 1, 2, 3, 4),
                isRecording = true,
                focus =
                    MonitorRelayWire.Focus(
                        coordinateWidth = 8192,
                        coordinateHeight = 5464,
                        focusResult = 2,
                        subjectDetectionActive = true,
                        trackingAFActive = false,
                        selectedBoxIndex = 0,
                        boxes = listOf(MonitorRelayWire.FocusBox(4096, 2732, 600, 400)),
                    ),
                levelRoll = -1.5,
                levelPitch = 0.25,
                sound = MonitorRelayWire.Sound(12, 14, 3, 5),
                codec = MonitorRelayWire.FrameCodec.HEVC,
                isKeyframe = true,
                parameterSets = listOf(byteArrayOf(0x40, 0x01), byteArrayOf(0x42, 0x01)),
            )
        val image = byteArrayOf(0xAB.toByte(), 0xCD.toByte(), 0xEF.toByte())
        val payload = MonitorRelayWire.encodeFramePayload(metadata, image)
        // Byte-exact prefix: 4-byte big-endian metadata length.
        val declaredJsonLength = MonitorRelayWire.readUInt32BE(payload, 0)
        assertEquals(payload.size - 4 - image.size, declaredJsonLength)
        val decoded = MonitorRelayWire.decodeFramePayload(payload)
        assertEquals(metadata.copy(parameterSets = null), decoded.metadata.copy(parameterSets = null))
        assertEquals(2, decoded.metadata.parameterSets!!.size)
        assertContentEquals(byteArrayOf(0x40, 0x01), decoded.metadata.parameterSets!![0])
        assertContentEquals(image, decoded.image)
    }

    @Test
    fun `frame metadata decodes the shared iOS-emitted vector`() {
        // As an iOS broadcaster emits it (base64 Data, numeric codec, no level/sound).
        val metadata =
            MonitorRelayWire.FrameMetadata.fromJson(
                JSONObject(
                    """
                    {"isRecording":false,"codec":1,"isKeyframe":true,
                     "parameterSets":["QAE=","QgE="],
                     "timecode":{"on":true,"hour":0,"minute":0,"second":1,"frame":12}}
                    """
                )
            )
        assertEquals(MonitorRelayWire.FrameCodec.HEVC, metadata.codec)
        assertEquals(true, metadata.isKeyframe)
        assertContentEquals(byteArrayOf(0x40, 0x01), metadata.parameterSets!![0])
        assertContentEquals(byteArrayOf(0x42, 0x01), metadata.parameterSets!![1])
        assertEquals(MonitorRelayWire.Timecode(true, 0, 0, 1, 12), metadata.timecode)
        assertNull(metadata.focus)
        assertNull(metadata.levelRoll)
    }

    @Test
    fun `commands use the single-key object form the core's Codable emits`() {
        assertEquals(
            MonitorRelayWire.Command.ToggleRecording,
            MonitorRelayWire.Command.fromJson(JSONObject("""{"toggleRecording":{}}""")),
        )
        assertEquals(
            MonitorRelayWire.Command.FocusPoint(100, 200, 8192, 5464),
            MonitorRelayWire.Command.fromJson(
                JSONObject(
                    """{"focusPoint":{"cameraX":100,"cameraY":200,"coordinateWidth":8192,"coordinateHeight":5464}}"""
                )
            ),
        )
        assertEquals(
            MonitorRelayWire.Command.PickerValue("iso", "800"),
            MonitorRelayWire.Command.fromJson(
                JSONObject("""{"pickerValue":{"picker":"iso","value":"800"}}""")
            ),
        )
        assertNull(MonitorRelayWire.Command.fromJson(JSONObject("""{"somethingNew":{}}""")))
        // Round trips through this side's encoder.
        val focus = MonitorRelayWire.Command.FocusPoint(1, 2, 3, 4)
        assertEquals(focus, MonitorRelayWire.Command.fromJson(focus.toJson()))
    }
}
