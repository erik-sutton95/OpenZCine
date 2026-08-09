package com.opencapture.openzcine.settings

import com.opencapture.openzcine.R

/** Operator-facing live-view stream-size preference forwarded to Swift policy. */
public enum class LiveViewStreamPreset(
    /** Stable Swift-wire ordinal; Kotlin must not map this to a Nikon byte. */
    internal val wireValue: Int,
    /** Full label shown in Operator Setup. */
    public val label: String,
) {
    /** Smallest disposable preview stream. */
    FAST(0, "Fast"),
    /** Middle preview size. */
    BALANCED(1, "Balanced"),
    /** Largest requested preview stream. */
    QUALITY(2, "Quality"),
    ;

    public companion object {
        /**
         * What a setup with no chosen preset runs at. The smallest preset is ~320x240 - too
         * little for the focus and exposure detectors to read anything but compression
         * structure - so the shipped answer is the largest stream the body will send.
         */
        public val SHIPPED_DEFAULT: LiveViewStreamPreset = QUALITY

        internal fun fromStoredName(value: String?): LiveViewStreamPreset? =
            entries.firstOrNull { it.name == value }
    }
}

/** Operator-facing preview compression preference forwarded to Swift policy. */
public enum class LiveViewQualityBias(
    /** Stable Swift-wire ordinal; Kotlin must not map this to a Nikon byte. */
    internal val wireValue: Int,
    /** Full label shown in Operator Setup. */
    public val label: String,
) {
    /** Prefer a leaner, lower-latency preview JPEG. */
    LATENCY(0, "Latency"),
    /** Preserve the body-default middle ground. */
    BALANCED(1, "Balanced"),
    /** Prefer preview image detail. */
    DETAIL(2, "Detail"),
    ;

    /**
     * Operator-facing name, mirroring `OperatorPreferences.QualityBias.settingsLabel` in the
     * shared core so a label cannot mean one compression byte here and another on iOS — which is
     * what happened while the control had two positions and "Size" stood for both LATENCY and
     * BALANCED.
     */
    public val settingsLabelResource: Int
        get() =
            when (this) {
                LATENCY -> R.string.settings_quality_bias_fast
                BALANCED -> R.string.settings_quality_bias_balanced
                DETAIL -> R.string.settings_quality_bias_quality
            }

    public companion object {
        /** What a setup with no chosen bias runs at, unless its path says otherwise. */
        public val SHIPPED_DEFAULT: LiveViewQualityBias = BALANCED

        internal fun fromStoredName(value: String?): LiveViewQualityBias? =
            entries.firstOrNull { it.name == value }
    }
}
