package com.opencapture.openzcine.transport

import java.io.EOFException
import java.io.IOException
import java.net.ServerSocket
import java.net.Socket
import java.net.SocketTimeoutException
import kotlin.test.Test
import kotlin.test.assertContentEquals
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.async
import kotlinx.coroutines.test.runTest

/** Exercises the transport state machine against a local [ServerSocket] fixture. */
class PtpIpSocketTransportTest {
    private fun transport(
        port: Int,
        config: PtpIpSocketTransport.Config = PtpIpSocketTransport.Config(),
        jitter: () -> Double = { 0.5 },
    ) = PtpIpSocketTransport("127.0.0.1", port, config, jitter = jitter)

    @Test
    fun `connect opens the command socket and reaches connected`() = runTest {
        ServerSocket(0).use { server ->
            val subject = transport(server.localPort)
            val accepted = async(Dispatchers.IO) { server.accept() }

            val command = subject.connect()

            accepted.await().use { peer ->
                assertEquals(TransportState.Connected, subject.state.value)
                command.send(byteArrayOf(1, 2, 3))
                assertContentEquals(byteArrayOf(1, 2, 3), peer.readExactly(3))
            }
            subject.disconnect()
        }
    }

    @Test
    fun `receive returns bytes the camera sends`() = runTest {
        ServerSocket(0).use { server ->
            val subject = transport(server.localPort)
            val accepted = async(Dispatchers.IO) { server.accept() }
            val command = subject.connect()

            accepted.await().use { peer ->
                peer.getOutputStream().apply {
                    write(byteArrayOf(9, 8, 7, 6))
                    flush()
                }
                val received = command.receive()
                assertContentEquals(byteArrayOf(9, 8, 7, 6), received)
            }
            subject.disconnect()
        }
    }

    @Test
    fun `event channel opens a second connection after the command channel`() = runTest {
        ServerSocket(0).use { server ->
            val subject = transport(server.localPort)
            val firstAccept = async(Dispatchers.IO) { server.accept() }
            subject.connect()
            firstAccept.await().use {
                val secondAccept = async(Dispatchers.IO) { server.accept() }
                val event = subject.openEventChannel()

                secondAccept.await().use { peer ->
                    event.send(byteArrayOf(42))
                    assertContentEquals(byteArrayOf(42), peer.readExactly(1))
                }
            }
            subject.disconnect()
        }
    }

    @Test
    fun `event channel before connect is rejected`() = runTest {
        assertFailsWith<IllegalStateException> { transport(port = 1).openEventChannel() }
    }

    @Test
    fun `refused connection throws and returns state to disconnected`() = runTest {
        val deadPort = ServerSocket(0).use { it.localPort }
        val subject = transport(deadPort)

        assertFailsWith<IOException> { subject.connect() }

        assertEquals(TransportState.Disconnected, subject.state.value)
    }

    @Test
    fun `receive times out when the camera goes silent`() = runTest {
        ServerSocket(0).use { server ->
            val subject =
                transport(server.localPort, PtpIpSocketTransport.Config(readTimeoutMillis = 100))
            val accepted = async(Dispatchers.IO) { server.accept() }
            val command = subject.connect()

            accepted.await().use {
                assertFailsWith<SocketTimeoutException> { command.receive() }
            }
            subject.disconnect()
        }
    }

    @Test
    fun `receive throws EOF when the peer closes`() = runTest {
        ServerSocket(0).use { server ->
            val subject = transport(server.localPort)
            val accepted = async(Dispatchers.IO) { server.accept() }
            val command = subject.connect()

            accepted.await().close()

            assertFailsWith<EOFException> { command.receive() }
            subject.disconnect()
        }
    }

    @Test
    fun `disconnect tears down gracefully with an orderly EOF at the peer`() = runTest {
        ServerSocket(0).use { server ->
            val subject = transport(server.localPort)
            val accepted = async(Dispatchers.IO) { server.accept() }
            subject.connect()

            accepted.await().use { peer ->
                subject.disconnect()

                assertEquals(TransportState.Disconnected, subject.state.value)
                // FIN, not RST: the peer's read observes a clean end of stream.
                assertEquals(-1, peer.getInputStream().read())
            }
        }
    }

    @Test
    fun `transport can connect again after disconnect`() = runTest {
        ServerSocket(0).use { server ->
            val subject = transport(server.localPort)
            val firstAccept = async(Dispatchers.IO) { server.accept() }
            subject.connect()
            firstAccept.await().use { subject.disconnect() }

            val secondAccept = async(Dispatchers.IO) { server.accept() }
            subject.connect()

            secondAccept.await().use {
                assertEquals(TransportState.Connected, subject.state.value)
            }
            subject.disconnect()
        }
    }

    @Test
    fun `reconnect tears down the old connection and establishes a fresh one`() = runTest {
        ServerSocket(0).use { server ->
            val subject = transport(server.localPort)
            val firstAccept = async(Dispatchers.IO) { server.accept() }
            subject.connect()
            firstAccept.await().use {
                val secondAccept = async(Dispatchers.IO) { server.accept() }

                val command = subject.reconnect()

                secondAccept.await().use { peer ->
                    assertEquals(TransportState.Connected, subject.state.value)
                    command.send(byteArrayOf(5))
                    assertContentEquals(byteArrayOf(5), peer.readExactly(1))
                }
            }
            subject.disconnect()
        }
    }

    @Test
    fun `reconnect exhausts its retry budget with backoff between attempts`() = runTest {
        val deadPort = ServerSocket(0).use { it.localPort }
        var jitterSamples = 0
        val subject =
            transport(
                deadPort,
                PtpIpSocketTransport.Config(maxReconnectAttempts = 3),
                jitter = {
                    jitterSamples += 1
                    0.5
                },
            )

        assertFailsWith<IOException> { subject.reconnect() }

        // Backoff (and its jitter sample) sits between attempts: attempts - 1.
        assertEquals(2, jitterSamples)
        assertEquals(TransportState.Disconnected, subject.state.value)
    }

    private fun Socket.readExactly(count: Int): ByteArray {
        val bytes = ByteArray(count)
        var offset = 0
        while (offset < count) {
            val read = getInputStream().read(bytes, offset, count - offset)
            check(read >= 0) { "Peer stream ended after $offset bytes." }
            offset += read
        }
        return bytes
    }
}
