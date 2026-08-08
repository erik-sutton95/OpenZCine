package com.opencapture.openzcine.relay

import com.opencapture.openzcine.core.RelayEncoderProfile
import java.net.ServerSocket
import java.net.Socket
import java.util.concurrent.atomic.AtomicLong
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.channels.BufferOverflow
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.launch
import kotlinx.coroutines.selects.select
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withContext
import org.json.JSONObject

/**
 * Serves this device's feed to watchers — the Android twin of iOS `MonitorRelayHost`. One
 * listener, per-peer send discipline, and the same protocol rules:
 *
 * - An unauthorized peer (broadcast passcoded, wrong/missing code) receives the hello and a
 *   `joinDenied`, then nothing — no state, no frames.
 * - A monitor shows the newest frame or it is not a monitor: each peer's frame lane holds ONE
 *   pending frame, newest wins, and a slow watcher is skipped rather than queued for. Frames
 *   are JPEG on this host (every frame standalone), so a skip needs no keyframe recovery.
 * - Control is proxied, never transferred: commands are honoured only from the holder, and a
 *   vanished holder returns control to the host.
 */
class MonitorRelayHost(
    private val scope: CoroutineScope,
    private val hostName: String,
    private val cameraName: String?,
) {
    var watcherPasscode: String = ""
    var allowsControlRequests: Boolean = true

    /**
     * The operator's latency-vs-quality stance. Only its in-flight depth applies here — this host
     * serves standalone JPEGs, so there is no keyframe cadence to lengthen.
     *
     * A peer's lane depth is fixed when the peer joins, because a [Channel]'s capacity cannot be
     * changed once created. Changing the stance therefore reaches watchers as they (re)join rather
     * than mid-stream.
     */
    var encoderProfile: RelayEncoderProfile = RelayEncoderProfile.LOW_LATENCY

    var onPeerCountChanged: ((Int) -> Unit)? = null
    var onControlChanged: ((pendingName: String?, holderName: String?) -> Unit)? = null
    var onCommand: ((MonitorRelayWire.Command) -> Unit)? = null
    var onFailure: ((String) -> Unit)? = null

    private class Peer(val id: Long, val socket: Socket, laneDepth: Int) {
        var name: String = "A device"
        var authorized: Boolean = false
        val control = Channel<ByteArray>(Channel.UNLIMITED)
        // Newest-wins either way; the depth only decides how much link jitter is ridden out
        // before a frame is skipped rather than waited for.
        val frames =
            Channel<ByteArray>(capacity = laneDepth, onBufferOverflow = BufferOverflow.DROP_OLDEST)
        var writer: Job? = null
        var reader: Job? = null
    }

    private val mutex = Mutex()
    private val peers = LinkedHashMap<Long, Peer>()
    private val nextPeerID = AtomicLong(1)
    private var serverSocket: ServerSocket? = null
    private var acceptJob: Job? = null
    private var latestStateJson: String? = null
    private var controlHolderID: Long? = null
    private var pendingRequestID: Long? = null

    /** The bound listener port, available after [start] returns successfully. */
    var boundPort: Int = 0
        private set

    /**
     * Binds [preferredPort] when it is still free, so NSD records that outlive a listener —
     * including across an app relaunch, where a killed process never withdrew its record and
     * the new registration renames itself under the conflict rules — still dial into a LIVE
     * listener (iOS twin: `relayListenerPreferredPort`, persisted). Falls back to an ephemeral
     * port rather than failing the broadcast over a squatter.
     */
    fun start(preferredPort: Int = 0): Boolean {
        return try {
            val server =
                if (preferredPort > 0) {
                    try {
                        ServerSocket(preferredPort)
                    } catch (_: Exception) {
                        ServerSocket(0)
                    }
                } else {
                    ServerSocket(0)
                }
            serverSocket = server
            boundPort = server.localPort
            acceptJob =
                scope.launch(Dispatchers.IO) {
                    while (true) {
                        val socket =
                            try {
                                server.accept()
                            } catch (_: Exception) {
                                return@launch
                            }
                        socket.tcpNoDelay = true
                        attach(socket)
                    }
                }
            true
        } catch (error: Exception) {
            onFailure?.invoke("Couldn't start sharing: ${error.message}")
            false
        }
    }

    private suspend fun attach(socket: Socket) {
        val peer =
            Peer(
                nextPeerID.getAndIncrement(),
                socket,
                laneDepth = encoderProfile.maxInFlightFramesPerPeer,
            )
        mutex.withLock { peers[peer.id] = peer }
        notifyPeerCount()
        peer.writer =
            scope.launch(Dispatchers.IO) {
                val output = socket.getOutputStream()
                try {
                    while (true) {
                        // Control/state drain ahead of frames; both lanes stay live.
                        val message =
                            select<ByteArray?> {
                                peer.control.onReceiveCatching { it.getOrNull() }
                                peer.frames.onReceiveCatching { it.getOrNull() }
                            } ?: break
                        output.write(message)
                        output.flush()
                    }
                } catch (_: Exception) {
                    // Reader teardown owns the drop.
                }
            }
        peer.reader = scope.launch(Dispatchers.IO) { readLoop(peer) }
        // Greet immediately; state follows once (and only once) the peer authorizes.
        peer.control.trySend(
            MonitorRelayWire.encodeFrame(
                MonitorRelayWire.Kind.HELLO,
                MonitorRelayWire.Hello(
                        version = MonitorRelayWire.VERSION,
                        hostName = hostName,
                        cameraName = cameraName,
                    )
                    .toJson()
                    .toString()
                    .toByteArray(Charsets.UTF_8),
            )
        )
    }

    private suspend fun readLoop(peer: Peer) {
        val input =
            try {
                peer.socket.getInputStream()
            } catch (_: Exception) {
                drop(peer)
                return
            }
        var buffer = ByteArray(64 * 1024)
        var available = 0
        try {
            while (true) {
                if (available == buffer.size) buffer = buffer.copyOf(buffer.size * 2)
                val read = input.read(buffer, available, buffer.size - available)
                if (read < 0) break
                available += read
                while (true) {
                    val decoded = MonitorRelayWire.decodeFrame(buffer, available) ?: break
                    buffer.copyInto(buffer, 0, decoded.consumedBytes, available)
                    available -= decoded.consumedBytes
                    handle(peer, decoded)
                }
            }
        } catch (_: Exception) {
            // Fall through to the drop below.
        }
        drop(peer)
    }

    private suspend fun handle(peer: Peer, decoded: MonitorRelayWire.Decoded) {
        when (decoded.kind) {
            MonitorRelayWire.Kind.HELLO -> {
                val hello =
                    MonitorRelayWire.Hello.fromJson(
                        JSONObject(String(decoded.payload, Charsets.UTF_8))
                    )
                peer.name = hello.hostName
                val required = watcherPasscode
                if (required.isEmpty() || hello.passcode == required) {
                    peer.authorized = true
                    latestStateJson?.let { state ->
                        peer.control.trySend(
                            MonitorRelayWire.encodeFrame(
                                MonitorRelayWire.Kind.STATE,
                                state.toByteArray(Charsets.UTF_8),
                            )
                        )
                    }
                } else {
                    peer.control.trySend(
                        MonitorRelayWire.encodeFrame(
                            MonitorRelayWire.Kind.JOIN_DENIED,
                            MonitorRelayWire.JoinDenied(
                                    reason =
                                        if (hello.passcode == null) {
                                            "This broadcast asks for a passcode."
                                        } else {
                                            "That passcode doesn't match this broadcast."
                                        },
                                    passcodeRequired = true,
                                )
                                .toJson()
                                .toString()
                                .toByteArray(Charsets.UTF_8),
                        )
                    )
                }
            }
            MonitorRelayWire.Kind.REQUEST_CONTROL -> {
                if (!peer.authorized || !allowsControlRequests) return
                mutex.withLock { pendingRequestID = peer.id }
                notifyControl()
            }
            MonitorRelayWire.Kind.RELEASE_CONTROL -> {
                val released = mutex.withLock {
                    if (controlHolderID == peer.id) {
                        controlHolderID = null
                        true
                    } else {
                        false
                    }
                }
                if (released) {
                    broadcastControlToken()
                    notifyControl()
                }
            }
            MonitorRelayWire.Kind.COMMAND -> {
                if (!peer.authorized) return
                if (mutex.withLock { controlHolderID } != peer.id) return
                MonitorRelayWire.Command.fromJson(
                        JSONObject(String(decoded.payload, Charsets.UTF_8))
                    )
                    ?.let { command -> onCommand?.invoke(command) }
            }
            else -> Unit
        }
    }

    private suspend fun drop(peer: Peer) {
        val wasHolder = mutex.withLock {
            peers.remove(peer.id)
            peer.control.close()
            peer.frames.close()
            val held = controlHolderID == peer.id
            if (held) controlHolderID = null
            if (pendingRequestID == peer.id) pendingRequestID = null
            held
        }
        withContext(Dispatchers.IO) { runCatching { peer.socket.close() } }
        peer.writer?.cancel()
        notifyPeerCount()
        if (wasHolder) broadcastControlToken()
        notifyControl()
    }

    // MARK: App-side surface

    suspend fun broadcastState(state: MonitorRelayWire.State) {
        val json = state.toJson().toString()
        latestStateJson = json
        val message =
            MonitorRelayWire.encodeFrame(
                MonitorRelayWire.Kind.STATE,
                json.toByteArray(Charsets.UTF_8),
            )
        forEachAuthorized { it.control.trySend(message) }
    }

    suspend fun broadcastFrame(metadata: MonitorRelayWire.FrameMetadata, image: ByteArray) {
        val message =
            MonitorRelayWire.encodeFrame(
                MonitorRelayWire.Kind.FRAME,
                MonitorRelayWire.encodeFramePayload(metadata, image),
            )
        forEachAuthorized { it.frames.trySend(message) }
    }

    suspend fun grantPendingControl() {
        val granted = mutex.withLock {
            val pending = pendingRequestID ?: return@withLock false
            controlHolderID = pending
            pendingRequestID = null
            true
        }
        if (granted) {
            broadcastControlToken()
            notifyControl()
        }
    }

    suspend fun declinePendingControl() {
        mutex.withLock { pendingRequestID = null }
        notifyControl()
    }

    /** Takes the camera back — always available, this device owns the session. */
    suspend fun reclaimControl() {
        mutex.withLock { controlHolderID = null }
        broadcastControlToken()
        notifyControl()
    }

    suspend fun stop() = stop(notifyingViewers = null)

    /**
     * Ends the broadcast. With a reason, every viewer is told the broadcast ended (the same
     * JOIN_DENIED frame a refused join gets, passcodeRequired=false) before its socket closes,
     * so a watcher can leave to the camera list instead of retry-looping on a dead socket.
     * The notice rides the ordered control lane and the writers get a short bounded window
     * to flush it — a courtesy race the watcher's dead-socket path still backstops.
     */
    suspend fun stop(notifyingViewers: String?) {
        acceptJob?.cancel()
        withContext(Dispatchers.IO) { runCatching { serverSocket?.close() } }
        val all = mutex.withLock { peers.values.toList() }
        if (notifyingViewers != null) {
            val notice =
                MonitorRelayWire.encodeFrame(
                    MonitorRelayWire.Kind.JOIN_DENIED,
                    MonitorRelayWire.JoinDenied(
                            reason = notifyingViewers,
                            passcodeRequired = false,
                        )
                        .toJson()
                        .toString()
                        .toByteArray(Charsets.UTF_8),
                )
            all.forEach { peer -> peer.control.trySend(notice) }
            if (all.isNotEmpty()) delay(150)
        }
        all.forEach { drop(it) }
        mutex.withLock {
            controlHolderID = null
            pendingRequestID = null
        }
        notifyControl()
    }

    private suspend fun broadcastControlToken() {
        val (holderID, holderName) = mutex.withLock {
            val holder = controlHolderID?.let(peers::get)
            controlHolderID to (holder?.name ?: hostName)
        }
        forEachAuthorized { peer ->
            peer.control.trySend(
                MonitorRelayWire.encodeFrame(
                    MonitorRelayWire.Kind.CONTROL_TOKEN,
                    MonitorRelayWire.ControlToken(
                            holderName = holderName,
                            holderIsRecipient = holderID != null && peer.id == holderID,
                        )
                        .toJson()
                        .toString()
                        .toByteArray(Charsets.UTF_8),
                )
            )
        }
    }

    private suspend fun forEachAuthorized(action: (Peer) -> Unit) {
        val snapshot = mutex.withLock { peers.values.filter(Peer::authorized) }
        snapshot.forEach(action)
    }

    private fun notifyPeerCount() {
        val count = peers.size
        onPeerCountChanged?.invoke(count)
    }

    private fun notifyControl() {
        val pendingName = pendingRequestID?.let { peers[it]?.name }
        val holderName = controlHolderID?.let { peers[it]?.name }
        onControlChanged?.invoke(pendingName, holderName)
    }
}
