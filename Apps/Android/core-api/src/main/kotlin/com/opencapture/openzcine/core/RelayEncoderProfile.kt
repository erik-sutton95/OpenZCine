package com.opencapture.openzcine.core

/**
 * Kotlin mirror of the shared core's `RelayEncoderProfile` — the broadcaster's
 * latency-vs-quality stance, chosen by the operator in Sharing settings.
 *
 * The numbers are the Swift definition's, transcribed rather than re-derived, and
 * `RelayEncoderProfileTest` pins them so the two shells cannot drift into offering
 * the same words for different behaviour.
 *
 * **Only one of the two knobs applies on this host.** An Android broadcast serves the
 * camera's own JPEGs untouched (`MonitorRelayHost`), so there is no encoder and no
 * keyframe cadence to lengthen — [maxKeyframeInterval] is carried for contract parity
 * and is inert here. [maxInFlightFramesPerPeer] is the live knob: it sets how deep a
 * watcher's frame lane runs before new frames are skipped, which is the half of the
 * trade that survives on a still-image stream — a deeper lane rides out link jitter
 * instead of dropping, at the cost of the frames it holds.
 */
public enum class RelayEncoderProfile(
    /** Stored form, matching the Swift enum's `rawValue` so a profile is portable. */
    public val wireValue: String,
    public val title: String,
    public val maxKeyframeInterval: Int,
    public val maxInFlightFramesPerPeer: Int,
) {
    LOW_LATENCY("lowLatency", "Low latency", 50, 2),
    QUALITY("quality", "Quality", 120, 4);

    public companion object {
        /** Falls back to the tightest path for an unknown or missing stored value. */
        public fun fromWireValue(value: String?): RelayEncoderProfile =
            entries.firstOrNull { it.wireValue == value } ?: LOW_LATENCY
    }
}
