package com.opencapture.openzcine.wear

import com.opencapture.opencine.relay.RelayWatchFrameSequence
import com.opencapture.opencine.relay.RelayWatchFreshness
import com.opencapture.opencine.relay.RelayWatchPendingCommand
import java.util.UUID
import kotlin.math.ceil

/** Original pure selectors over the shared lifetime values; actual receiver supplies real source. */
internal class WatchRelayFreshness(maximumAgeMillis: Long) {
    private val owner = RelayWatchFreshness(maximumAgeMillis / 1_000.0)
    fun accept(atMillis: Long) = owner.accept(atMillis / 1_000.0)
    fun clear() = owner.clear()
    fun isFresh(atMillis: Long) = owner.isFresh(atMillis / 1_000.0)
    fun remainingMillis(atMillis: Long) = owner.remainingSeconds(atMillis / 1_000.0)?.let { ceil(it * 1_000).toLong() }
}
internal data class PendingWearCommand(val nodeID: String, val requestID: Long) {
    private val owner = RelayWatchPendingCommand(nodeID, requestID, UUID.randomUUID())
    fun matches(nodeID: String, requestID: Long) = owner.matches(nodeID, requestID, owner.source)
}
internal class LatestWearFrameSequence {
    private val owner = RelayWatchFrameSequence()
    fun accept(requestID: Long) = owner.accept(requestID)
    fun clear() = owner.clear()
}
