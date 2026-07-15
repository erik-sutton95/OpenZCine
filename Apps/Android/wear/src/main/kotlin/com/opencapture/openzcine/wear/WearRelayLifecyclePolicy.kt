package com.opencapture.openzcine.wear

/**
 * Tracks whether a watch snapshot is fresh enough to represent the foreground
 * phone monitor. Capability reachability deliberately does not affect this
 * value: an installed/reachable phone app is not evidence of live camera UI.
 */
internal class WatchRelayFreshness(
    private val maximumAgeMillis: Long,
) {
    private var acceptedAtMillis: Long? = null

    init {
        require(maximumAgeMillis > 0L)
    }

    /** Records an authoritative state snapshot arrival. */
    fun accept(atMillis: Long) {
        acceptedAtMillis = atMillis
    }

    /** Clears any old snapshot during stop, resume, or explicit invalidation. */
    fun clear() {
        acceptedAtMillis = null
    }

    /** True only while a state snapshot remains within the required age. */
    fun isFresh(atMillis: Long): Boolean =
        acceptedAtMillis?.let { acceptedAt ->
            val ageMillis = atMillis - acceptedAt
            ageMillis >= 0L && ageMillis < maximumAgeMillis
        } == true

    /** Delay until the current snapshot expires, or null when none exists. */
    fun remainingMillis(atMillis: Long): Long? =
        acceptedAtMillis?.let { acceptedAt ->
            val ageMillis = (atMillis - acceptedAt).coerceAtLeast(0L)
            (maximumAgeMillis - ageMillis).coerceAtLeast(0L)
        }
}

/** Exact phone-node/request pair for the one outstanding record command. */
internal data class PendingWearCommand(
    val nodeID: String,
    val requestID: Long,
) {
    /** A result must originate from the same phone node and request path. */
    fun matches(nodeID: String, requestID: Long): Boolean =
        this.nodeID == nodeID && this.requestID == requestID
}

/** Drops an older in-flight preview that arrives after a newer relay token. */
internal class LatestWearFrameSequence {
    private var latestRequestID = 0L

    /** True only when [requestID] advances the current foreground sequence. */
    fun accept(requestID: Long): Boolean {
        if (requestID <= latestRequestID) return false
        latestRequestID = requestID
        return true
    }

    /** Starts a new foreground presentation with no retained ordering state. */
    fun clear() {
        latestRequestID = 0L
    }
}
