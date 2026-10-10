package com.opencapture.openzcine.wear

import com.opencapture.opencine.relay.RelayPreviewPacing
import com.opencapture.opencine.relay.RelayPreviewPacingPolicy
import com.opencapture.opencine.relay.RelayPreviewProfile

internal data class WearPreviewProfile(val maximumWidth: Int, val jpegQuality: Int)
/** Original selectors over the common acknowledged pacing owner and exact supplied budgets. */
internal class AdaptiveWearPreviewPacing {
    private val owner = RelayPreviewPacing(RelayPreviewPacingPolicy(
        profiles = listOf(RelayPreviewProfile(416, 32), RelayPreviewProfile(336, 28), RelayPreviewProfile(256, 24)),
        roundTripThresholds = listOf(0.2, 0.35), initialIndex = 1, sampleUnitsPerSecond = 1_000.0))
    fun currentProfile() = owner.currentProfile.legacy()
    fun acknowledge(roundTripMillis: Long) = owner.acknowledgeInSampleUnits(roundTripMillis.toDouble()).legacy()
    fun timedOut() = owner.timedOut().legacy()
    fun reset() = owner.reset()
    private fun RelayPreviewProfile.legacy() = WearPreviewProfile(maximumWidth, qualityPercent)
}
