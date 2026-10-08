package com.opencapture.openzcine.relay

import com.opencapture.opencine.nikonwire.MonitorRelayWire
import com.opencapture.opencine.relay.RelayNearbyPolicy

typealias RelayPresence = com.opencapture.opencine.relay.RelayPresence

/** Exact integration-owned wire decoding; policy sees only neutral passive facts. */
fun parseRelayPresenceLine(line: String): RelayPresence? = MonitorRelayWire.parsePresenceLine(line)?.let {
    RelayPresence(it.name, it.watchable, it.servedCameraHost, it.relayPort)
}
fun mergedNearbyBroadcasts(nsdRows: List<RelayBroadcast>, presences: Map<String, RelayPresence>, selfName: String,
    refutedNames: Set<String> = emptySet()): List<RelayBroadcast> = RelayNearbyPolicy.merge(nsdRows, presences, selfName, refutedNames)
fun updatedPresenceHiddenSince(presences: Map<String, RelayPresence>, nsdNames: Set<String>, selfName: String,
    previous: Map<String, Long>, nowMillis: Long): Map<String, Long> = RelayNearbyPolicy.hiddenSince(presences, nsdNames, selfName, previous, nowMillis)
fun presenceProvesFiltering(hiddenSince: Map<String, Long>, nowMillis: Long, thresholdMillis: Long = 10_000): Boolean =
    RelayNearbyPolicy.provesFiltering(hiddenSince, nowMillis, thresholdMillis)

/** Existing Android continuity/refutation facts and bounded endpoint projection only. */
fun monitorRelayNearbyOwner(): com.opencapture.opencine.relay.RelayNearbyOwner<RelayBroadcast, RelayPresence> =
    com.opencapture.opencine.relay.RelayNearbyOwner(
        policy = com.opencapture.opencine.relay.RelayNearbyLedgerPolicy(
            hiddenIdentity = com.opencapture.opencine.relay.RelayNearbyLedgerPolicy.HiddenIdentity.NAME,
            duplicateIdentity = com.opencapture.opencine.relay.RelayNearbyLedgerPolicy.DuplicateIdentity.UNREFUTED_LISTINGS,
            removesPresenceOnListingRemoval = false,
            confirmation = com.opencapture.opencine.relay.RelayNearbyLedgerPolicy.Confirmation.ALL_ANSWERS),
        listingFacts = { com.opencapture.opencine.relay.RelayNearbyListingFacts(it.name, it.isWatchable) },
        presenceFacts = { com.opencapture.opencine.relay.RelayNearbyPresenceFacts(it.name, it.watchable, it.relayPort) },
        presenceListing = { host, port, presence -> RelayBroadcast(presence.name, host, port, presence.servedCameraHost) })
