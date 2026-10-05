package com.opencapture.openzcine.transport

import com.opencapture.opencine.nikon.HostProbeVerdict
import com.opencapture.opencine.nikon.NikonDialer
import com.opencapture.opencine.nikon.NikonDiscovery
import com.opencapture.opencine.nikon.NikonLocalInterface
import com.opencapture.opencine.nikon.NikonPresence
import com.opencapture.openzcine.relay.MonitorRelayWire
import com.opencapture.openzcine.relay.RelayPresence
import com.opencapture.openzcine.relay.parseRelayPresenceLine
import java.io.IOException
import java.net.ConnectException
import java.net.InetSocketAddress
import java.net.NoRouteToHostException
import java.net.PortUnreachableException
import java.net.Socket
import java.net.SocketException
import java.net.SocketTimeoutException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext

/**
 * This phone's sockets behind OpenCine's `NikonDiscovery`: the presence port (presence reads and
 * liveness) and the mute dial at the PTP/IP port. The presence answer is this app's relay
 * protocol, so it is decoded here and kept whole in [NikonPresence.line].
 */
internal object SocketNikonDialer : NikonDialer {
    /** The /24 sweep's per-host deadline. */
    private const val PRESENCE_TIMEOUT_MILLIS = 500

    /**
     * HW-measured 2026-08-04: an idle body RSTs in ~1.0-1.2 s (Wi-Fi power-save cadence), hence
     * the longer deadline than the sweep's.
     */
    private const val LIVENESS_TIMEOUT_MILLIS = 1_500

    override suspend fun presence(host: String): NikonPresence? =
        withContext(Dispatchers.IO) {
            try {
                Socket().use { socket ->
                    socket.connect(
                        InetSocketAddress(host, MonitorRelayWire.PRESENCE_TCP_PORT),
                        PRESENCE_TIMEOUT_MILLIS,
                    )
                    socket.soTimeout = PRESENCE_TIMEOUT_MILLIS
                    val line = socket.getInputStream().bufferedReader(Charsets.UTF_8).readLine()
                    line?.let(::parseRelayPresenceLine)?.let {
                        NikonPresence(it.name, it.servedCameraHost, line)
                    }
                }
            } catch (_: IOException) {
                null
            }
        }

    /** A dial a non-OpenZCine host refuses (kernel RST) still proves the address is occupied. */
    override suspend fun isAlive(host: String): Boolean =
        withContext(Dispatchers.IO) {
            try {
                Socket().use { socket ->
                    socket.connect(
                        InetSocketAddress(host, MonitorRelayWire.PRESENCE_TCP_PORT),
                        LIVENESS_TIMEOUT_MILLIS,
                    )
                }
                true
            } catch (_: ConnectException) {
                true
            } catch (_: IOException) {
                false
            }
        }

    /**
     * Connect and hang up on the PTP/IP port, keeping why it failed. Mute on purpose: an `Init`
     * aimed at a body in its pairing wait knocks it out of pairing; a bare connect cannot.
     */
    override suspend fun scanControlPort(host: String, timeoutMillis: Int): HostProbeVerdict =
        withContext(Dispatchers.IO) {
            try {
                Socket().use { socket ->
                    socket.connect(InetSocketAddress(host, CameraDiscovery.PTP_IP_PORT), timeoutMillis)
                }
                HostProbeVerdict.OPEN
            } catch (_: SocketTimeoutException) {
                HostProbeVerdict.TIMEOUT
            } catch (_: NoRouteToHostException) {
                HostProbeVerdict.NO_ROUTE
            } catch (_: PortUnreachableException) {
                HostProbeVerdict.REFUSED
            } catch (_: ConnectException) {
                // Refused: only a live host's kernel sends the RST.
                HostProbeVerdict.REFUSED
            } catch (_: SocketException) {
                HostProbeVerdict.NO_NETWORK
            } catch (_: IOException) {
                // Never evidence about the host: this is something about THIS device.
                HostProbeVerdict.UNREACHABLE_OTHER
            }
        }
}

/**
 * The cameras list's discovery: PASSIVE only. Presence sweeps and liveness dials of saved hosts
 * reach the presence port, never a camera's control service; this class has no way to ask for
 * more (the control-port search belongs to pairing and setup watches, [InfrastructureCameraFinder]).
 */
internal class CameraListDiscovery(
    dialer: NikonDialer = SocketNikonDialer,
    interfaces: () -> List<NikonLocalInterface> = ::localIPv4Interfaces,
    log: (String) -> Unit = {},
) {
    private val discovery = NikonDiscovery(dialer, interfaces, log)

    /** One presence sweep (at most every 30 s; `null` inside the window or with no interface). */
    suspend fun presences(): Map<String, RelayPresence>? =
        discovery.presenceSweep()?.mapNotNull { (host, presence) ->
            presence.line?.let(::parseRelayPresenceLine)?.let { host to it }
        }?.toMap()

    /** The saved hosts something occupies (the list's only wireless readiness signal). */
    suspend fun alive(hosts: Collection<String>): Set<String> = discovery.liveness(hosts)
}
