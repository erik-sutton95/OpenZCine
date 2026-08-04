package com.opencapture.openzcine.relay

import java.io.IOException
import java.net.InetSocketAddress
import java.net.Socket
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.flow.MutableSharedFlow
import kotlinx.coroutines.flow.SharedFlow
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import org.json.JSONObject

/**
 * Watches one broadcast — the Android twin of iOS `MonitorRelayClient`. Connects, introduces
 * itself (with the watcher passcode when the broadcast asks), then surfaces everything the host
 * sends as [Event]s. Sends are fire-and-forget through a writer coroutine so a slow socket never
 * blocks the caller.
 */
class MonitorRelayClient(private val scope: CoroutineScope) {
    sealed interface Event {
        data class Connected(val hostName: String, val cameraName: String?) : Event

        data class StateReceived(val state: MonitorRelayWire.State) : Event

        data class FrameReceived(
            val metadata: MonitorRelayWire.FrameMetadata,
            val image: ByteArray,
        ) : Event

        data class ControlChanged(val token: MonitorRelayWire.ControlToken) : Event

        data class JoinDenied(val denied: MonitorRelayWire.JoinDenied) : Event

        data class Closed(val reason: String?) : Event
    }

    private val mutableEvents =
        MutableSharedFlow<Event>(extraBufferCapacity = 16, replay = 0)
    val events: SharedFlow<Event> = mutableEvents

    private var socket: Socket? = null
    private var readerJob: Job? = null
    private var writerJob: Job? = null
    private val outbound = Channel<ByteArray>(Channel.UNLIMITED)

    /** Opens the connection and introduces this device. Safe to call once per instance. */
    fun connect(
        host: String,
        port: Int,
        deviceName: String,
        passcode: String?,
        codecs: List<String>? = null,
    ) {
        readerJob =
            scope.launch(Dispatchers.IO) {
                val socket = Socket()
                try {
                    socket.tcpNoDelay = true
                    // A vanished host must not pin this watcher for the TCP retransmission
                    // eternity (iOS relay keepalive parity).
                    socket.keepAlive = true
                    socket.connect(InetSocketAddress(host, port), CONNECT_TIMEOUT_MILLIS)
                    this@MonitorRelayClient.socket = socket
                    writerJob =
                        scope.launch(Dispatchers.IO) {
                            val output = socket.getOutputStream()
                            for (message in outbound) {
                                output.write(message)
                                output.flush()
                            }
                        }
                    send(
                        MonitorRelayWire.Kind.HELLO,
                        MonitorRelayWire.Hello(
                                version = MonitorRelayWire.VERSION,
                                hostName = deviceName,
                                cameraName = null,
                                passcode = passcode,
                                codecs = codecs,
                            )
                            .toJson()
                            .toString()
                            .toByteArray(Charsets.UTF_8),
                    )
                    readLoop(socket)
                } catch (error: Exception) {
                    mutableEvents.emit(Event.Closed(error.message))
                } finally {
                    runCatching { socket.close() }
                }
            }
    }

    private suspend fun readLoop(socket: Socket) {
        val input = socket.getInputStream()
        var buffer = ByteArray(256 * 1024)
        var available = 0
        while (true) {
            if (available == buffer.size) buffer = buffer.copyOf(buffer.size * 2)
            val read = input.read(buffer, available, buffer.size - available)
            if (read < 0) {
                mutableEvents.emit(Event.Closed(null))
                return
            }
            available += read
            while (true) {
                val decoded =
                    try {
                        MonitorRelayWire.decodeFrame(buffer, available) ?: break
                    } catch (error: MonitorRelayWire.DesynchronizedStreamException) {
                        mutableEvents.emit(Event.Closed(error.message))
                        return
                    }
                buffer.copyInto(buffer, 0, decoded.consumedBytes, available)
                available -= decoded.consumedBytes
                handle(decoded)
            }
        }
    }

    private suspend fun handle(decoded: MonitorRelayWire.Decoded) {
        when (decoded.kind) {
            MonitorRelayWire.Kind.HELLO -> {
                val hello =
                    MonitorRelayWire.Hello.fromJson(
                        JSONObject(String(decoded.payload, Charsets.UTF_8))
                    )
                if (hello.version != MonitorRelayWire.VERSION) {
                    mutableEvents.emit(
                        Event.Closed("This broadcast uses an app version this device can't watch.")
                    )
                } else {
                    mutableEvents.emit(Event.Connected(hello.hostName, hello.cameraName))
                }
            }
            MonitorRelayWire.Kind.STATE ->
                mutableEvents.emit(
                    Event.StateReceived(
                        MonitorRelayWire.State.fromJson(
                            JSONObject(String(decoded.payload, Charsets.UTF_8))
                        )
                    )
                )
            MonitorRelayWire.Kind.FRAME -> {
                val frame = MonitorRelayWire.decodeFramePayload(decoded.payload)
                mutableEvents.emit(Event.FrameReceived(frame.metadata, frame.image))
            }
            MonitorRelayWire.Kind.CONTROL_TOKEN ->
                mutableEvents.emit(
                    Event.ControlChanged(
                        MonitorRelayWire.ControlToken.fromJson(
                            JSONObject(String(decoded.payload, Charsets.UTF_8))
                        )
                    )
                )
            MonitorRelayWire.Kind.JOIN_DENIED ->
                mutableEvents.emit(
                    Event.JoinDenied(
                        MonitorRelayWire.JoinDenied.fromJson(
                            JSONObject(String(decoded.payload, Charsets.UTF_8))
                        )
                    )
                )
            else -> Unit
        }
    }

    fun requestControl() = send(MonitorRelayWire.Kind.REQUEST_CONTROL, ByteArray(0))

    fun releaseControl() = send(MonitorRelayWire.Kind.RELEASE_CONTROL, ByteArray(0))

    fun sendCommand(command: MonitorRelayWire.Command) =
        send(
            MonitorRelayWire.Kind.COMMAND,
            command.toJson().toString().toByteArray(Charsets.UTF_8),
        )

    private fun send(kind: Int, payload: ByteArray) {
        outbound.trySend(MonitorRelayWire.encodeFrame(kind, payload))
    }

    suspend fun stop() {
        readerJob?.cancel()
        writerJob?.cancel()
        outbound.close()
        withContext(Dispatchers.IO) { runCatching { socket?.close() } }
        socket = null
    }

    private companion object {
        const val CONNECT_TIMEOUT_MILLIS = 8_000
    }
}
