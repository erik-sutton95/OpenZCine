package com.opencapture.openzcine.relay

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNull
import kotlin.test.assertTrue

/**
 * The sweep's pure pieces: presence-line parsing (pinned against the exact
 * [MonitorRelayWire.relayPresenceLine] wire form), the NSD/presence merge decision, and the
 * hidden-presence bookkeeping behind the filtered-network warning.
 */
class RelayPresenceScannerTest {
    @Test
    fun `presence lines from the wire encoder parse field-for-field`() {
        // A joinable broadcast serving a camera — every field populated.
        assertEquals(
            RelayPresence("A-cam iPhone", true, "192.168.1.246", 51234),
            parseRelayPresenceLine(
                MonitorRelayWire.relayPresenceLine("A-cam iPhone", true, "192.168.1.246", 51234)
            ),
        )
        // An in-use beacon: not joinable, no relay port.
        assertEquals(
            RelayPresence("Galaxy S25", false, "192.168.1.9", null),
            parseRelayPresenceLine(
                MonitorRelayWire.relayPresenceLine("Galaxy S25", false, "192.168.1.9", null)
            ),
        )
        // The literal wire shape, trailing newline included (the responder always sends one).
        assertEquals(
            RelayPresence("iPhone 17 Pro", true, null, 50000),
            parseRelayPresenceLine("""{"v":1,"n":"iPhone 17 Pro","w":1,"p":50000}""" + "\n"),
        )
    }

    @Test
    fun `presence parsing rejects garbage, foreign versions, and blank names`() {
        assertNull(parseRelayPresenceLine("not json"))
        assertNull(parseRelayPresenceLine("""{"n":"x","w":1}""")) // no version
        assertNull(parseRelayPresenceLine("""{"v":2,"n":"x","w":1}""")) // future version
        assertNull(parseRelayPresenceLine("""{"v":1,"n":"","w":1}""")) // blank name
        assertNull(parseRelayPresenceLine("""{"v":1,"w":1}""")) // missing name
        // A nonsense port is dropped, not clamped into a joinable endpoint.
        assertEquals(
            RelayPresence("x", true, null, null),
            parseRelayPresenceLine("""{"v":1,"n":"x","w":1,"p":0}"""),
        )
    }

    @Test
    fun `presence-only watchable rows join the list and NSD wins name collisions`() {
        val nsd =
            listOf(
                RelayBroadcast("A-cam iPhone", "192.168.1.20", 50100, null),
                RelayBroadcast(
                    "Held iPad", "192.168.1.30", 50200, "192.168.1.5", isWatchable = false),
            )
        val presences =
            mapOf(
                // Name NSD already delivers: suppressed, the NSD row is authoritative.
                "192.168.1.20" to RelayPresence("A-cam iPhone", true, null, 50100),
                // NSD-blind broadcast: joinable row on the answering host.
                "192.168.1.40" to RelayPresence("B-cam Galaxy", true, "192.168.1.6", 50300),
                // In-use beacon: nothing to join.
                "192.168.1.50" to RelayPresence("C-cam iPhone", false, "192.168.1.7", null),
                // Watchable but portless: no endpoint to join.
                "192.168.1.60" to RelayPresence("Portless", true, null, null),
                // This device's own answer never lists itself.
                "192.168.1.2" to RelayPresence("My Galaxy", true, null, 50400),
            )
        assertEquals(
            nsd + RelayBroadcast("B-cam Galaxy", "192.168.1.40", 50300, "192.168.1.6"),
            mergedNearbyBroadcasts(nsd, presences, selfName = "My Galaxy"),
        )
    }

    @Test
    fun `each sweep is authoritative so a stopped broadcast leaves no ghost row`() {
        val first = mapOf("192.168.1.40" to RelayPresence("B-cam Galaxy", true, null, 50300))
        assertEquals(1, mergedNearbyBroadcasts(emptyList(), first, "self").size)
        // The next sweep REPLACES the set; the host that stopped answering is simply gone.
        assertEquals(
            emptyList(),
            mergedNearbyBroadcasts(emptyList(), emptyMap(), "self"),
        )
    }

    @Test
    fun `sweep-refuted NSD rows hide, and a confirmed name survives refutation of others`() {
        val nsd =
            listOf(
                RelayBroadcast("Live iPhone", "192.168.1.20", 50100, null),
                // Stale record: the broadcaster quit but its multicast goodbye was eaten.
                RelayBroadcast("Gone iPad", "192.168.1.30", 50200, null),
            )
        val presences = mapOf("192.168.1.20" to RelayPresence("Live iPhone", true, null, 50100))
        assertEquals(
            listOf(nsd[0]),
            mergedNearbyBroadcasts(nsd, presences, "self", refutedNames = setOf("Gone iPad")),
        )
        // A refuted name that answers again lists via its presence row until NSD un-refutes.
        assertEquals(
            listOf(RelayBroadcast("Gone iPad", "192.168.1.30", 50200, null)),
            mergedNearbyBroadcasts(
                nsd.filter { it.name == "Gone iPad" },
                mapOf("192.168.1.30" to RelayPresence("Gone iPad", true, null, 50200)),
                "self",
                refutedNames = setOf("Gone iPad"),
            ),
        )
    }

    @Test
    fun `filtering verdict needs ten continuous hidden seconds and clears on reappearance`() {
        val presences = mapOf("192.168.1.40" to RelayPresence("B-cam Galaxy", true, null, 50300))
        var hidden =
            updatedPresenceHiddenSince(presences, emptySet(), "self", emptyMap(), 1_000)
        assertFalse(presenceProvesFiltering(hidden, 1_000))
        // Still hidden 10 s later — the carried first-hidden stamp trips the verdict.
        hidden = updatedPresenceHiddenSince(presences, emptySet(), "self", hidden, 11_000)
        assertTrue(presenceProvesFiltering(hidden, 11_000))
        // NSD catches up: the stamp resets and the verdict clears.
        hidden =
            updatedPresenceHiddenSince(
                presences, setOf("B-cam Galaxy"), "self", hidden, 12_000)
        assertFalse(presenceProvesFiltering(hidden, 12_000))
        // Hidden again afterwards: the clock restarts — continuous, not cumulative.
        hidden = updatedPresenceHiddenSince(presences, emptySet(), "self", hidden, 13_000)
        assertFalse(presenceProvesFiltering(hidden, 13_000))
        assertEquals(mapOf("B-cam Galaxy" to 13_000L), hidden)
    }

    @Test
    fun `hidden bookkeeping ignores this device and forgets silent hosts`() {
        // The device's own presence answer is never "hidden" evidence.
        assertEquals(
            emptyMap(),
            updatedPresenceHiddenSince(
                mapOf("192.168.1.2" to RelayPresence("self", true, null, 50400)),
                emptySet(),
                "self",
                emptyMap(),
                0,
            ),
        )
        // A presence that stopped answering drops its stamp with the sweep that lost it.
        assertEquals(
            emptyMap(),
            updatedPresenceHiddenSince(
                emptyMap(), emptySet(), "self", mapOf("B-cam Galaxy" to 1_000L), 20_000),
        )
    }
}
