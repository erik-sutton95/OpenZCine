package com.opencapture.openzcine

/**
 * Built-in monitor looks. [wireOrdinal] mirrors `FeedEffectsWire.look` in the
 * Swift facade — the core generates each look's cube, Kotlin only uploads it.
 */
enum class FeedLut(val id: String, val wireOrdinal: Int, val label: String) {
    LOG3G10_709("log3g10", 0, "LOG→709"),
    NLOG_709("nlog", 1, "N-LOG"),
    MONO("mono", 2, "MONO");

    companion object {
        fun fromId(id: String): FeedLut? = entries.firstOrNull { it.id == id }
    }
}

/** False-colour scales. [wireOrdinal] mirrors `FeedEffectsWire.bakedFalseColor`. */
enum class FeedFalseColorScale(val id: String, val wireOrdinal: Int, val label: String) {
    STOPS("stops", 0, "STOPS"),
    IRE("ire", 1, "IRE");

    companion object {
        fun fromId(id: String): FeedFalseColorScale? = entries.firstOrNull { it.id == id }
    }
}

/**
 * Which analysis effects the live feed bakes in, mirroring the iOS shell's
 * `LiveImageEffects`. False colour and the LUT are mutually exclusive — false
 * colour *is* the monitoring image, so it replaces the creative look.
 *
 * The shared [AssistState] owns this in normal operation. Debug intent extras
 * (see `DemoHarness`) still seed deterministic sessions: `--es zc.assist
 * lut,falsecolor,peaking,zebra`, plus `--es zc.lut <log3g10|nlog|mono>` and
 * `--es zc.fc.scale <stops|ire>`.
 */
data class FeedEffects(
    val lut: FeedLut? = null,
    val falseColor: FeedFalseColorScale? = null,
    val peaking: Boolean = false,
    val zebra: Boolean = false,
) {
    /** True when the feed renders untouched — the renderer skips the GPU chain. */
    val isIdentity: Boolean
        get() = lut == null && falseColor == null && !peaking && !zebra

    companion object {
        val NONE = FeedEffects()

        /**
         * Parses the debug intent extras. [assist] is a comma-separated token
         * list (`lut`, `falsecolor`, `peaking`, `zebra`; unknown tokens are
         * ignored); [lutId]/[falseColorScaleId] select variants, falling back
         * to the iOS defaults (Log3G10→709, Stops) when absent or unknown.
         */
        fun parse(assist: String?, lutId: String?, falseColorScaleId: String?): FeedEffects {
            val tokens =
                assist.orEmpty()
                    .split(',')
                    .map { it.trim().lowercase() }
                    .filter { it.isNotEmpty() }
                    .toSet()
            val falseColor =
                if ("falsecolor" in tokens) {
                    falseColorScaleId?.let(FeedFalseColorScale::fromId)
                        ?: FeedFalseColorScale.STOPS
                } else {
                    null
                }
            return FeedEffects(
                // False colour replaces the creative look, like iOS.
                lut =
                    if (falseColor == null && "lut" in tokens) {
                        lutId?.let(FeedLut::fromId) ?: FeedLut.LOG3G10_709
                    } else {
                        null
                    },
                falseColor = falseColor,
                peaking = "peaking" in tokens,
                zebra = "zebra" in tokens,
            )
        }
    }
}
