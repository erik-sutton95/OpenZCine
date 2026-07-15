package com.opencapture.openzcine.wear

/** One bounded JPEG tier selected from observed watch acknowledgements. */
internal data class WearPreviewProfile(
    val maximumWidth: Int,
    val jpegQuality: Int,
)

/**
 * Adapts the three-slot preview pump to measured watch receipt acknowledgements.
 * RTT is smoothed to avoid oscillating on individual Data Layer messages; a
 * missing acknowledgement immediately drops one tier. The three in-flight
 * slots plus one freshest replacement make throughput acknowledgement-paced.
 */
internal class AdaptiveWearPreviewPacing {
    private var profileIndex = BALANCED_INDEX
    private var smoothedRoundTripMillis: Double? = null

    /** Current immutable profile used when admitting the next source frame. */
    @Synchronized
    fun currentProfile(): WearPreviewProfile = PROFILES[profileIndex]

    /** Records one application-level acknowledgement and returns the next profile. */
    @Synchronized
    fun acknowledge(roundTripMillis: Long): WearPreviewProfile {
        if (roundTripMillis <= 0L) return PROFILES[profileIndex]
        val previous = smoothedRoundTripMillis
        val smoothed =
            if (previous == null) {
                roundTripMillis.toDouble()
            } else {
                previous * 0.8 + roundTripMillis * 0.2
            }
        smoothedRoundTripMillis = smoothed
        profileIndex =
            when {
                smoothed < 200.0 -> 0
                smoothed < 350.0 -> BALANCED_INDEX
                else -> PROFILES.lastIndex
            }
        return PROFILES[profileIndex]
    }

    /** Degrades one tier after a send that never reached watch receipt. */
    @Synchronized
    fun timedOut(): WearPreviewProfile {
        profileIndex = (profileIndex + 1).coerceAtMost(PROFILES.lastIndex)
        smoothedRoundTripMillis = null
        return PROFILES[profileIndex]
    }

    /** Returns to a conservative initial tier for a new foreground link. */
    @Synchronized
    fun reset() {
        profileIndex = BALANCED_INDEX
        smoothedRoundTripMillis = null
    }

    private companion object {
        const val BALANCED_INDEX = 1
        val PROFILES =
            listOf(
                WearPreviewProfile(maximumWidth = 416, jpegQuality = 32),
                WearPreviewProfile(maximumWidth = 336, jpegQuality = 28),
                WearPreviewProfile(maximumWidth = 256, jpegQuality = 24),
            )
    }
}
