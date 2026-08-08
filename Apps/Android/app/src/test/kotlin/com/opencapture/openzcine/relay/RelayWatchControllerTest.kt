package com.opencapture.openzcine.relay

import java.net.ServerSocket
import java.net.Socket
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import kotlin.test.AfterTest
import kotlin.test.BeforeTest
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNull
import kotlin.test.assertTrue
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.runBlocking
import org.json.JSONObject

/**
 * The jpeg-only codec negotiation, over a real loopback socket against the wire encoder:
 * a seeded (persisted) latch must reach the FIRST hello of a fresh controller — not only a
 * rejoin after an in-process demote — and an HEVC stream nothing decodes must demote within
 * the bounded deadline instead of the decoder-exhaustion path's tens of seconds. Off-device
 * `MediaCodec` construction throws, which the frame source swallows into "fed, decoded
 * nothing" — exactly the black-feed shape the deadline exists to bound.
 */
class RelayWatchControllerTest {
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Default)

    @BeforeTest
    fun resetLatch() {
        RelayWatchController.resetJpegOnlyForTesting()
    }

    @AfterTest
    fun tearDown() {
        RelayWatchController.resetJpegOnlyForTesting()
        scope.cancel()
    }

    @Test
    fun `a seeded latch declares jpeg-only in the very first hello`() {
        LoopbackRelayHost().use { host ->
            RelayWatchController.seedJpegOnly()
            val controller = controller(host)
            controller.start()
            val (_, hello) = host.acceptHello()
            assertEquals(listOf("jpeg"), hello.codecs)
            runBlocking { controller.stop() }
        }
    }

    @Test
    fun `an unseeded first hello declares no codec cap`() {
        LoopbackRelayHost().use { host ->
            val controller = controller(host)
            controller.start()
            val (_, hello) = host.acceptHello()
            assertNull(hello.codecs)
            runBlocking { controller.stop() }
        }
    }

    @Test
    fun `undecodable hevc latches within the deadline and rejoins jpeg-only`() {
        LoopbackRelayHost().use { host ->
            val latched = CountDownLatch(1)
            val controller =
                controller(host, deadlineMillis = 300L, onLatched = latched::countDown)
            controller.start()
            val (socket, hello) = host.acceptHello()
            assertNull(hello.codecs)
            host.send(
                socket,
                MonitorRelayWire.Kind.HELLO,
                MonitorRelayWire.Hello(
                        version = MonitorRelayWire.VERSION,
                        hostName = "Host",
                        cameraName = null,
                    )
                    .toJson()
                    .toString()
                    .toByteArray(Charsets.UTF_8),
            )
            host.send(
                socket,
                MonitorRelayWire.Kind.FRAME,
                MonitorRelayWire.encodeFramePayload(
                    MonitorRelayWire.FrameMetadata(
                        timecode = null,
                        isRecording = false,
                        focus = null,
                        levelRoll = null,
                        levelPitch = null,
                        sound = null,
                        codec = MonitorRelayWire.FrameCodec.HEVC,
                        isKeyframe = true,
                        parameterSets = listOf(byteArrayOf(0x40, 0x01)),
                    ),
                    ByteArray(16),
                ),
            )
            assertTrue(
                // Bounds LIVENESS, not the deadline: what is under test is the 300 ms above, and
                // this only has to outlast it. Generous because the controller's work runs on
                // `Dispatchers.Default`, which on a CI runner is sized to cores and shared with
                // the other 880-odd tests and the lint pass in the same job — the old five
                // seconds was arbitrary, and it lost that race once in two runs of one commit.
                latched.await(30, TimeUnit.SECONDS),
                "the decode deadline never latched jpeg-only",
            )
            val (_, rejoinHello) = host.acceptHello()
            assertEquals(listOf("jpeg"), rejoinHello.codecs)
            runBlocking { controller.stop() }
        }
    }

    private fun controller(
        host: LoopbackRelayHost,
        deadlineMillis: Long = 6_000L,
        onLatched: (() -> Unit)? = null,
    ): RelayWatchController =
        RelayWatchController(
            scope = scope,
            deviceName = "Test watcher",
            broadcast =
                RelayBroadcast(
                    name = "Loopback host",
                    host = "127.0.0.1",
                    port = host.port,
                    servedCameraHost = null,
                ),
            onJpegOnlyLatched = onLatched,
            hevcDecodeDeadlineMillis = deadlineMillis,
            log = {},
        )
}

/** One-connection-at-a-time relay host stub speaking the real framing on a loopback socket. */
private class LoopbackRelayHost : AutoCloseable {
    private val server = ServerSocket(0).apply { soTimeout = 5_000 }
    private val sockets = mutableListOf<Socket>()

    val port: Int
        get() = server.localPort

    /** Accepts the next watcher connection and returns it with its decoded HELLO. */
    fun acceptHello(): Pair<Socket, MonitorRelayWire.Hello> {
        val socket =
            server.accept().also {
                it.soTimeout = 5_000
                sockets += it
            }
        val payload = readMessage(socket, MonitorRelayWire.Kind.HELLO)
        return socket to
            MonitorRelayWire.Hello.fromJson(JSONObject(String(payload, Charsets.UTF_8)))
    }

    fun send(socket: Socket, kind: Int, payload: ByteArray) {
        socket.getOutputStream().apply {
            write(MonitorRelayWire.encodeFrame(kind, payload))
            flush()
        }
    }

    private fun readMessage(socket: Socket, expectedKind: Int): ByteArray {
        val input = socket.getInputStream()
        val buffer = ByteArray(64 * 1024)
        var available = 0
        while (true) {
            MonitorRelayWire.decodeFrame(buffer, available)?.let { decoded ->
                check(decoded.kind == expectedKind) { "unexpected kind ${decoded.kind}" }
                return decoded.payload
            }
            val read = input.read(buffer, available, buffer.size - available)
            check(read >= 0) { "socket closed before a full message" }
            available += read
        }
    }

    override fun close() {
        sockets.forEach { runCatching { it.close() } }
        runCatching { server.close() }
    }
}
