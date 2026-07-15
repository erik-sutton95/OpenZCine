package com.opencapture.openzcine.settings

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

    internal companion object {
        fun fromStoredName(value: String?): LiveViewStreamPreset? =
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

    internal companion object {
        fun fromStoredName(value: String?): LiveViewQualityBias? =
            entries.firstOrNull { it.name == value }
    }
}
