package com.opencapture.openzcine.wearrelay

import java.util.Base64
import kotlin.test.Test
import kotlin.test.assertContains
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertIs
import kotlin.test.assertNotNull
import kotlin.test.assertTrue
import kotlin.test.assertFailsWith
import org.json.JSONObject

class WatchRelayWireTest {
    private fun fixture(): JSONObject {
        val stream =
            checkNotNull(javaClass.classLoader?.getResourceAsStream("WatchRelayProtocolV1.json")) {
                "The canonical Swift watch-relay fixture was not available to this test."
            }
        return stream.bufferedReader().use { JSONObject(it.readText()) }
    }

    private fun envelope(kind: WatchRelayKind, payload: Any): ByteArray {
        val json = if (payload is String) JSONObject.quote(payload) else payload.toString()
        return byteArrayOf(kind.tag.toByte()) + json.toByteArray(Charsets.UTF_8)
    }

    @Test
    fun `v1 golden state and frame match the canonical Swift fixture`() {
        val fixture = fixture()
        assertEquals(1, fixture.getInt("protocolVersion"))

        val state =
            assertIs<WatchRelayState>(
                WatchRelayEnvelope.decode(envelope(WatchRelayKind.STATE, fixture.getJSONObject("state"))),
            )
        assertEquals(WatchRecordState.RECORDING, state.recordState)
        assertEquals("Nikon ZR", state.cameraName)
        assertEquals(80, state.cameraBatteryPercent)
        assertEquals(WatchConnectionState.CONNECTED, state.connection)
        assertEquals("01:02:03:04", state.timecode.label())
        assertEquals("521 GB · 47%", assertNotNull(state.mediaStatus).capacityLabel())

        val withoutMedia =
            assertIs<WatchRelayState>(
                WatchRelayEnvelope.decode(
                    envelope(WatchRelayKind.STATE, fixture.getJSONObject("stateWithoutMediaStatus")),
                ),
            )
        assertEquals(null, withoutMedia.mediaStatus)
        val reencodedEnvelope = WatchRelayEnvelope.encode(withoutMedia)
        val reencodedWithoutMedia =
            String(reencodedEnvelope.copyOfRange(1, reencodedEnvelope.size), Charsets.UTF_8)
        assertFalse(reencodedWithoutMedia.contains("mediaStatus"))

        val frame =
            assertIs<WatchRelayFrame>(
                WatchRelayEnvelope.decode(envelope(WatchRelayKind.FRAME, fixture.getJSONObject("frame"))),
            )
        assertTrue(
            frame.jpeg.contentEquals(Base64.getDecoder().decode("/9j/4AAQ")),
            "The preview bytes must remain the Swift Codable Data base64 representation.",
        )
        assertEquals("12:34:56:07", frame.timecode.label())
    }

    @Test
    fun `v1 command and result retain their explicit kind correlation`() {
        val fixture = fixture()
        val command =
            WatchRelayEnvelope.decode(envelope(WatchRelayKind.COMMAND, fixture.getString("command")))
        assertEquals(WatchRelayCommand.TOGGLE_RECORD, command)

        val resultEnvelope =
            WatchRelayEnvelope.encode(
                WatchCommandResult(accepted = false, isRecording = true, error = "not reachable"),
            )
        assertEquals(WatchRelayKind.RESULT, WatchRelayEnvelope.kindOf(resultEnvelope))
        val result = assertIs<WatchCommandResult>(WatchRelayEnvelope.decode(resultEnvelope))
        assertFalse(result.accepted)
        assertTrue(result.isRecording)
        assertEquals("not reachable", result.error)

        val mismatchedKind = resultEnvelope.copyOf().also { it[0] = WatchRelayKind.COMMAND.tag.toByte() }
        assertFailsWith<WatchRelayWireException.MalformedPayload> {
            WatchRelayEnvelope.decode(mismatchedKind)
        }

        val commandPath = WearRelayTransport.commandPath(42)
        assertEquals(42, WearRelayTransport.commandRequestID(commandPath))
        assertEquals(42, WearRelayTransport.resultRequestID(WearRelayTransport.resultPath(42)))
        assertEquals(null, WearRelayTransport.commandRequestID("${WearRelayTransport.COMMAND_PATH}/0"))
        assertEquals(null, WearRelayTransport.resultRequestID("${WearRelayTransport.RESULT_PATH}/42/late"))
    }

    @Test
    fun `strict decoder rejects malformed utf8 unknown kinds and trailing content`() {
        assertFailsWith<WatchRelayWireException.EmptyEnvelope> {
            WatchRelayEnvelope.decode(byteArrayOf())
        }
        assertFailsWith<WatchRelayWireException.UnknownKind> {
            WatchRelayEnvelope.decode(byteArrayOf(0x7F, '{'.code.toByte(), '}'.code.toByte()))
        }
        assertFailsWith<WatchRelayWireException.MalformedPayload> {
            WatchRelayEnvelope.decode(
                byteArrayOf(WatchRelayKind.COMMAND.tag.toByte()) + "\"toggleRecord\" trailing".toByteArray(),
            )
        }
        assertFailsWith<WatchRelayWireException.MalformedPayload> {
            WatchRelayEnvelope.decode(byteArrayOf(WatchRelayKind.COMMAND.tag.toByte(), 0xC3.toByte()))
        }
        val malformedState =
            byteArrayOf(WatchRelayKind.STATE.tag.toByte()) + "{\"recordState\":\"recording\"}".toByteArray()
        val error =
            assertFailsWith<WatchRelayWireException.MalformedPayload> {
                WatchRelayEnvelope.decode(malformedState)
            }
        assertContains(error.message.orEmpty(), "timecode")
    }
}
