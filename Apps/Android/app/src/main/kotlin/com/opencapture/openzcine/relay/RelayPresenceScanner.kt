package com.opencapture.openzcine.relay

import java.io.IOException
import java.net.ConnectException
import java.net.Inet4Address
import java.net.InetSocketAddress
import java.net.NetworkInterface
import java.net.Socket
import java.net.SocketException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.async
import kotlinx.coroutines.awaitAll
import kotlinx.coroutines.withContext
import org.json.JSONException
import org.json.JSONObject

/**
 * One parsed unicast presence answer ([MonitorRelayWire.relayPresenceLine]) — the Kotlin twin
 * of the core's `RelayPresence`.
 */
data class RelayPresence(
    val name: String,
    val watchable: Boolean,
    val servedCameraHost: String?,
    val relayPort: Int?,
)

/**
 * Parses one presence line. Null for garbage, a version this build does not speak, or a blank
 * name — only a genuine OpenZCine presence answer counts (iOS `RelayPresence.decode`).
 */
fun parseRelayPresenceLine(line: String): RelayPresence? {
    val json =
        try {
            JSONObject(line.trim())
        } catch (_: JSONException) {
            return null
        }
    if (json.optInt("v", 0) != 1) return null
    val name = json.optString("n")
    if (name.isBlank()) return null
    return RelayPresence(
        name = name,
        watchable = json.optInt("w", 1) != 0,
        servedCameraHost = json.optString("ch").takeIf(String::isNotBlank),
        relayPort = json.optInt("p", 0).takeIf { it in 1..65535 },
    )
}

/**
 * NSD rows plus presence-only rows: a watchable presence with a relay port whose NAME the NSD
 * browse never delivered becomes a joinable row on the answering host — on a multicast-filtered
 * network it is the only way that broadcast is joinable (iOS `visibleRelayBroadcasts`). NSD
 * wins name collisions, and this device's own presence never lists itself.
 *
 * [refutedNames] hides NSD rows the latest completed sweep proved stale: a stopped
 * broadcaster's mDNS *goodbye* is multicast too, so on a filtered network its record lingers
 * in the browse until TTL while the whole-subnet unicast sweep hears nothing from it
 * (iOS `presenceRefutedRelayNames`).
 */
fun mergedNearbyBroadcasts(
    nsdRows: List<RelayBroadcast>,
    presences: Map<String, RelayPresence>,
    selfName: String,
    refutedNames: Set<String> = emptySet(),
): List<RelayBroadcast> {
    val visibleNsdRows = nsdRows.filterNot { it.name in refutedNames }
    val nsdNames = visibleNsdRows.mapTo(mutableSetOf(), RelayBroadcast::name)
    val presenceRows =
        presences
            .mapNotNull { (host, presence) ->
                val port = presence.relayPort ?: return@mapNotNull null
                if (!presence.watchable) return@mapNotNull null
                if (presence.name == selfName || presence.name in nsdNames) {
                    return@mapNotNull null
                }
                RelayBroadcast(
                    name = presence.name,
                    host = host,
                    port = port,
                    servedCameraHost = presence.servedCameraHost,
                    isWatchable = true,
                )
            }
            .sortedBy(RelayBroadcast::name)
    return visibleNsdRows + presenceRows
}

/**
 * Per-name first-hidden timestamps: when each currently-answering presence FIRST went missing
 * from the NSD rows. A name NSD can see (or this device's own) resets its stamp; a name that
 * stopped answering drops out with the sweep that stopped seeing it — each sweep dialed the
 * whole subnet, so the presence set is authoritative (iOS `applyRelayPresences`).
 */
fun updatedPresenceHiddenSince(
    presences: Map<String, RelayPresence>,
    nsdNames: Set<String>,
    selfName: String,
    previous: Map<String, Long>,
    nowMillis: Long,
): Map<String, Long> =
    presences.values
        .asSequence()
        .map(RelayPresence::name)
        .filter { it != selfName && it !in nsdNames }
        .associateWith { previous[it] ?: nowMillis }

/**
 * The filtered-network verdict: proven once any presence has answered the direct check for
 * [thresholdMillis] continuously while NSD stayed blind to it — a sweep racing the browse never
 * flashes the warning — and cleared as soon as no presence is hidden.
 */
fun presenceProvesFiltering(
    hiddenSince: Map<String, Long>,
    nowMillis: Long,
    thresholdMillis: Long = 10_000,
): Boolean = hiddenSince.values.any { nowMillis - it >= thresholdMillis }

/**
 * Sweeps the local /24 subnet(s) for unicast presence answers
 * (TCP [MonitorRelayWire.PRESENCE_TCP_PORT]) — the Android twin of the iOS discovery-ride
 * presence sweep. On networks whose routers filter multicast, these answers are the only
 * sighting this device gets of broadcasters and in-use shields, and an answer NSD cannot see
 * is the proof the network filters discovery.
 */
class RelayPresenceScanner(
    private val connectTimeoutMillis: Int = 500,
    private val minimumSweepGapMillis: Long = 30_000,
) {
    private var lastSweepAtNanos: Long? = null

    /**
     * One full sweep, or null inside the internal 30 s rate window ("no new sweep"): ~253 SYNs
     * per pass is airtime taken from the very camera link this feature protects, so callers may
     * tick fast and let this limiter decide.
     */
    suspend fun sweep(): Map<String, RelayPresence>? {
        val now = System.nanoTime()
        synchronized(this) {
            val last = lastSweepAtNanos
            if (last != null && now - last < minimumSweepGapMillis * 1_000_000) return null
            lastSweepAtNanos = now
        }
        return withContext(Dispatchers.IO) {
            val hosts = candidateHosts()
            // No interface = nothing was asked: null ("no verdict"), never an authoritative
            // empty that would wrongly refute live rows.
            if (hosts.isEmpty()) return@withContext null
            val found = LinkedHashMap<String, RelayPresence>()
            // Chunks of 64 = the iOS sweep's bounded parallelism (and Dispatchers.IO's floor).
            hosts.chunked(64).forEach { chunk ->
                chunk
                    .map { host -> async { host to checkPresence(host) } }
                    .awaitAll()
                    .forEach { (host, presence) ->
                        if (presence != null) found[host] = presence
                    }
            }
            found
        }
    }

    /** Every /24 neighbour of every up, non-loopback, site-local IPv4 interface address. */
    private fun candidateHosts(): List<String> {
        val interfaces =
            try {
                NetworkInterface.getNetworkInterfaces()?.toList().orEmpty()
            } catch (_: SocketException) {
                return emptyList()
            }
        val locals =
            interfaces
                .asSequence()
                .filter {
                    try {
                        it.isUp && !it.isLoopback
                    } catch (_: SocketException) {
                        false
                    }
                }
                .flatMap { it.inetAddresses.asSequence() }
                .filterIsInstance<Inet4Address>()
                .filter(Inet4Address::isSiteLocalAddress)
                .mapNotNull { it.hostAddress }
                .toList()
        val self = locals.toSet()
        return locals
            .map { it.substringBeforeLast('.') }
            .distinct()
            .flatMap { prefix -> (1..254).map { "$prefix.$it" } }
            .filterNot(self::contains)
    }

    /** One presence read: connect, one line, parse. Null for refused, timed out, or garbage. */
    private fun checkPresence(host: String): RelayPresence? =
        try {
            Socket().use { socket ->
                socket.connect(
                    InetSocketAddress(host, MonitorRelayWire.PRESENCE_TCP_PORT),
                    connectTimeoutMillis,
                )
                socket.soTimeout = connectTimeoutMillis
                socket
                    .getInputStream()
                    .bufferedReader(Charsets.UTF_8)
                    .readLine()
                    ?.let(::parseRelayPresenceLine)
            }
        } catch (_: IOException) {
            null
        }
}

/**
 * Whether SOMETHING lives at [host], without one byte reaching any application service: a
 * dial to the presence port that a non-OpenZCine host answers with a kernel RST ("refused")
 * proves the address is occupied (iOS `checkHostAlive`). This is the camera list's ONLY
 * wireless readiness signal — an idle device's PTP Init drops another device's live session,
 * so the list never sends one. HW-measured 2026-08-04: the body RSTs in ~1.0–1.2 s (Wi-Fi
 * power-save cadence), hence the longer deadline than the /24 sweep's 500 ms.
 */
suspend fun probeHostAlive(host: String, timeoutMillis: Int = 1_500): Boolean =
    withContext(Dispatchers.IO) {
        try {
            Socket().use { socket ->
                socket.connect(
                    InetSocketAddress(host, MonitorRelayWire.PRESENCE_TCP_PORT),
                    timeoutMillis,
                )
            }
            true
        } catch (_: ConnectException) {
            // Refused: only a live host's kernel sends the RST.
            true
        } catch (_: IOException) {
            false
        }
    }
