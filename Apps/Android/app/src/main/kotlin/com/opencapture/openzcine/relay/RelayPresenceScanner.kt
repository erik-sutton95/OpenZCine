package com.opencapture.openzcine.relay

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
        // Only a BROADCAST can prove the network hides broadcasts. An in-use shield advertises
        // under a distinct "<name> in-use" service name (see [CameraInUseBeacon]) while its
        // presence line carries the plain one, so it can never match an NSD row by name — and
        // counting it here would flag every network where somebody holds a camera without
        // sharing.
        .filter(RelayPresence::watchable)
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
