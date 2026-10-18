package com.opencapture.openzcine.relay

import com.opencapture.opencine.cameracontrols.WatcherJoinStatus
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNull
import kotlin.test.assertSame
import kotlin.test.assertTrue

/** SIMULATED discovery reports exercise the exact host adapter MainActivity composes. */
class RelayWatcherBrowseHostTest {
    @Test
    fun `join resolves the current deployed discovery identity and ignores a retired row`() {
        val first = RelayBroadcast("SIMULATED first", "127.0.0.1", 65001, null)
        val second = RelayBroadcast("SIMULATED second", "127.0.0.1", 65002, null)
        var broadcasts = listOf(first, second)
        val joined = mutableListOf<RelayBroadcast>()
        val host = RelayWatcherBrowseHost({ broadcasts }, { null }, { null }, {}, joined::add, {}, {})
        assertEquals(listOf("SIMULATED first", "SIMULATED second"), host.watcherFeeds.map { it.id })
        assertTrue(host.watcherFeeds.all { it.cameraName == null })
        val replacement = first.copy(host = "127.0.0.2", port = 65003)
        broadcasts = listOf(replacement)
        host.joinWatcherFeed(second.name)
        assertTrue(joined.isEmpty())
        host.joinWatcherFeed(first.name)
        assertSame(replacement, joined.single())
    }

    @Test
    fun `existing owner phases retain connecting locked failure and empty facts`() {
        var state: RelayWatchUiState? = null
        var error: String? = null
        val host = RelayWatcherBrowseHost({ emptyList() }, { state }, { error }, {}, {}, {}, {})
        assertEquals(WatcherJoinStatus.Idle, host.watcherJoinStatus)
        assertNull(host.watcherBrowseError)
        assertTrue(host.watcherFeeds.isEmpty())
        error = "SIMULATED discovery unavailable"
        assertEquals(error, host.watcherBrowseError)
        state = RelayWatchUiState(phase = RelayWatchUiState.Phase.CONNECTING)
        assertEquals(WatcherJoinStatus.Connecting, host.watcherJoinStatus)
        state = RelayWatchUiState(phase = RelayWatchUiState.Phase.DENIED, needsPasscode = true,
            failureReason = "SIMULATED wrong passcode")
        assertEquals(WatcherJoinStatus.NeedsPasscode, host.watcherJoinStatus)
        assertEquals("SIMULATED wrong passcode", host.watcherPasscodeError)
        state = RelayWatchUiState(phase = RelayWatchUiState.Phase.FAILED, failureReason = "SIMULATED dropped")
        assertEquals(WatcherJoinStatus.Failed("SIMULATED dropped"), host.watcherJoinStatus)
        assertNull(host.watcherPasscodeError)
        state = RelayWatchUiState(phase = RelayWatchUiState.Phase.WATCHING)
        assertEquals(WatcherJoinStatus.Live, host.watcherJoinStatus)
    }
}
