package com.opencapture.openzcine.transport

import java.io.EOFException
import java.io.IOException
import java.net.InetSocketAddress
import java.net.Socket
import kotlin.random.Random
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withContext

/** Connection lifecycle of a [PtpIpSocketTransport] (naming matches the core-api seam). */
sealed interface TransportState {
    /** No sockets open and no attempt in flight. */
    data object Disconnected : TransportState

    /** A connect attempt is in progress. */
    data object Connecting : TransportState

    /** The command socket is open. */
    data object Connected : TransportState
}

/**
 * Raw duplex byte channel over one TCP socket (PTP-IP command or event).
 *
 * The PTP-IP framing/protocol layer that consumes these bytes arrives later
 * with the Swift-core JNI facade; this boundary is deliberately bytes-only.
 * Sends and receives are each internally serialized; interleaving distinct
 * logical messages across concurrent callers is the protocol layer's job.
 */
interface TransportChannel {
    /** Sends all of [bytes]. Throws [IOException] when the channel is down. */
    suspend fun send(bytes: ByteArray)

    /**
     * Receives between 1 and [maxBytes] bytes, suspending until data arrives.
     * Throws [EOFException] when the peer closed the connection and
     * [java.net.SocketTimeoutException] when no data arrives within the
     * configured read timeout.
     */
    suspend fun receive(maxBytes: Int = DEFAULT_RECEIVE_LIMIT): ByteArray

    companion object {
        /** Default per-receive cap; bounds transient allocations like the iOS socket's recv cap. */
        const val DEFAULT_RECEIVE_LIMIT: Int = 256 * 1024
    }
}

/**
 * TCP socket lifecycle for one PTP-IP camera connection — the Android twin of
 * `ios/Runner/PTPIPTransport.swift`'s socket layer, minus the protocol.
 *
 * Owns the two-socket PTP-IP shape: [connect] opens the **command** socket;
 * [openEventChannel] opens the **event** socket on demand, because CIPA
 * DC-005 sequences it *after* the Init handshake on the command channel and
 * that handshake belongs to the future protocol layer.
 *
 * Teardown is graceful: sockets are half-closed (FIN) before closing, so the
 * camera observes an orderly shutdown instead of a reset — mirroring the iOS
 * `shutdown(SHUT_RDWR)`-before-close fix from the connection-wedge work.
 * [reconnect] additionally waits [Config.reconnectSettleMillis] before the
 * fresh connect, because the ZR briefly holds its PTP slot after a close and
 * a same-instant reconnect can wedge it.
 *
 * @property host Camera IPv4 address.
 * @property port PTP-IP TCP port.
 */
class PtpIpSocketTransport(
    private val host: String,
    private val port: Int = CameraDiscovery.PTP_IP_PORT,
    private val config: Config = Config(),
    private val backoff: ReconnectBackoff = ReconnectBackoff(),
    private val jitter: () -> Double = { Random.nextDouble() },
) {
    /**
     * Transport tuning. Defaults mirror the iOS transport: 10s socket
     * timeouts, a 1.2s reconnect settle (ZR slot-release time, verify on
     * hardware), and a small bounded retry budget.
     */
    data class Config(
        val connectTimeoutMillis: Int = 10_000,
        val readTimeoutMillis: Int = 10_000,
        val reconnectSettleMillis: Long = 1_200,
        val maxReconnectAttempts: Int = 3,
    )

    private val mutableState = MutableStateFlow<TransportState>(TransportState.Disconnected)

    /** Current transport lifecycle state. */
    val state: StateFlow<TransportState> = mutableState.asStateFlow()

    private val lifecycle = Mutex()
    private var commandSocket: Socket? = null
    private var eventSocket: Socket? = null

    /**
     * Opens the command socket and returns its byte channel. Throws
     * [IOException] (including [java.net.SocketTimeoutException]) on failure,
     * leaving [state] at [TransportState.Disconnected].
     */
    suspend fun connect(): TransportChannel =
        lifecycle.withLock {
            check(commandSocket == null) { "Transport already connected; disconnect() first." }
            mutableState.value = TransportState.Connecting
            try {
                val socket = openSocket()
                commandSocket = socket
                mutableState.value = TransportState.Connected
                SocketChannel(socket)
            } catch (error: Exception) {
                mutableState.value = TransportState.Disconnected
                throw error
            }
        }

    /**
     * Opens the event socket and returns its byte channel. Requires a
     * connected command socket first (the protocol layer calls this after the
     * camera acknowledges the Init handshake).
     */
    suspend fun openEventChannel(): TransportChannel =
        lifecycle.withLock {
            check(commandSocket != null) { "Connect the command channel before the event channel." }
            check(eventSocket == null) { "Event channel already open." }
            val socket = openSocket()
            eventSocket = socket
            SocketChannel(socket)
        }

    /** Gracefully tears down both sockets and returns [state] to [TransportState.Disconnected]. */
    suspend fun disconnect() {
        lifecycle.withLock { teardown() }
    }

    /**
     * Tears down any existing sockets, waits the reconnect settle, then
     * retries [connect] up to [Config.maxReconnectAttempts] times with
     * [backoff] between attempts. Returns the fresh command channel or throws
     * the last [IOException] once the budget is exhausted.
     */
    suspend fun reconnect(): TransportChannel {
        lifecycle.withLock { teardown() }
        delay(config.reconnectSettleMillis)
        var attempt = 0
        while (true) {
            try {
                return connect()
            } catch (error: IOException) {
                if (attempt + 1 >= config.maxReconnectAttempts) throw error
                delay(backoff.delayMillis(attempt, jitter()))
                attempt += 1
            }
        }
    }

    /** Must be called with [lifecycle] held. */
    private suspend fun teardown() {
        val sockets = listOfNotNull(commandSocket, eventSocket)
        commandSocket = null
        eventSocket = null
        mutableState.value = TransportState.Disconnected
        if (sockets.isEmpty()) return
        withContext(Dispatchers.IO) {
            for (socket in sockets) {
                // Half-close first so the peer sees FIN, not RST — the iOS
                // shutdown()-before-close teardown that unwedged ZR reconnects.
                runCatching { socket.shutdownOutput() }
                runCatching { socket.shutdownInput() }
                runCatching { socket.close() }
            }
        }
    }

    private suspend fun openSocket(): Socket =
        withContext(Dispatchers.IO) {
            val socket = Socket()
            try {
                socket.tcpNoDelay = true
                // ponytail: plain SO_KEEPALIVE only — java.net cannot tune the
                // probe timers the iOS transport sets; revisit with
                // ExtendedSocketOptions if half-open links surface on hardware.
                socket.keepAlive = true
                socket.soTimeout = config.readTimeoutMillis
                socket.connect(InetSocketAddress(host, port), config.connectTimeoutMillis)
                socket
            } catch (error: Exception) {
                runCatching { socket.close() }
                throw error
            }
        }
}

/** [TransportChannel] over a connected [Socket]; I/O runs on [Dispatchers.IO]. */
private class SocketChannel(private val socket: Socket) : TransportChannel {
    private val sendMutex = Mutex()
    private val receiveMutex = Mutex()

    override suspend fun send(bytes: ByteArray) {
        sendMutex.withLock {
            withContext(Dispatchers.IO) {
                val output = socket.getOutputStream()
                output.write(bytes)
                output.flush()
            }
        }
    }

    override suspend fun receive(maxBytes: Int): ByteArray {
        require(maxBytes > 0) { "maxBytes must be positive." }
        return receiveMutex.withLock {
            withContext(Dispatchers.IO) {
                val buffer = ByteArray(maxBytes)
                val count = socket.getInputStream().read(buffer)
                if (count < 0) throw EOFException("PTP-IP peer closed the connection.")
                buffer.copyOf(count)
            }
        }
    }
}
