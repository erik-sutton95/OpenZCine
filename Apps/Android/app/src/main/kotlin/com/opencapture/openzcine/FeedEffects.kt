package com.opencapture.openzcine

import androidx.compose.runtime.Immutable
import com.opencapture.openzcine.lut.StoredLutSelection

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

/**
 * The LUT selected for monitoring. Built-ins retain their existing stable JNI ordinal; stored
 * selections carry only the generated app-private category/file identity. The latter is resolved
 * and packed by the shared Swift parser through [com.opencapture.openzcine.lut.AndroidLutLibrary],
 * never by Kotlin colour code or a duplicated cache-key format.
 */
sealed interface FeedLutSelection {
    /** One of the procedural shared-core looks already available in every build. */
    data class BuiltIn(val value: FeedLut) : FeedLutSelection

    /** An operator-selected file retained only in app-private LUT storage. */
    data class Stored(val value: StoredLutSelection) : FeedLutSelection
}

/** False-colour scales. [wireOrdinal] mirrors `FeedEffectsWire.bakedFalseColor`. */
enum class FeedFalseColorScale(val id: String, val wireOrdinal: Int, val label: String) {
    STOPS("stops", 0, "ZC Stops"),
    IRE("ire", 1, "IRE"),
    /**
     * Crush/clip-only false colour. Unlike STOPS/IRE it composites over the
     * selected monitor look, matching iOS `FalseColorScale.limits`.
     */
    LIMITS("limits", 2, "Limits");

    companion object {
        fun fromId(id: String): FeedFalseColorScale? = entries.firstOrNull { it.id == id }
    }
}

/**
 * Camera-owned values forwarded untouched into the Swift exposure-assist
 * facade. Kotlin never selects a tone curve or derives a clip endpoint from
 * these fields; the shared core resolves that camera policy.
 */
@Immutable
data class ExposureAssistCameraInput(
    val codec: String? = null,
    val iso: Long? = null,
    val baseIso: String? = null,
) {
    /** JNI sentinel for a camera that has not reported ISO yet. */
    val isoWireValue: Long
        get() = iso ?: -1L
}

/** iOS `Peaking.Sensitivity`, with ordinals owned by the Swift facade. */
enum class FeedPeakingSensitivity(val wireOrdinal: Int, val label: String) {
    LOW(0, "LOW"),
    MEDIUM(1, "MED"),
    HIGH(2, "HIGH"),
}

/** iOS `Peaking.Color`, with the actual RGB resolved only by Swift. */
enum class FeedPeakingColor(val wireOrdinal: Int, val label: String) {
    WHITE(0, "WHITE"),
    BLUE(1, "BLUE"),
    RED(2, "RED"),
    GREEN(3, "GREEN"),
}

/** Editor units for the shared-core zebra thresholds. */
enum class FeedZebraUnit(val wireOrdinal: Int, val label: String) {
    NATIVE(0, "0–255"),
    IRE(1, "IRE"),
}

/** iOS `AssistConfiguration.Zebra.StripeColor`; Swift resolves its RGB value. */
enum class FeedZebraStripeColor(val wireOrdinal: Int, val label: String) {
    WHITE(0, "WHITE"),
    AMBER(1, "AMBER"),
    RED(2, "RED"),
    CYAN(3, "CYAN"),
    GREEN(4, "GREEN"),
}

/**
 * Persistable operator configuration for image assists. Thresholds remain on
 * the shared core's normalized 0…100 monitor axis even while the UI edits
 * them in native code values; the conversion lives at the Swift wire.
 */
@Immutable
data class FeedEffectsConfiguration(
    val falseColorReferenceEnabled: Boolean = true,
    val peakingSensitivity: FeedPeakingSensitivity = FeedPeakingSensitivity.MEDIUM,
    val peakingColor: FeedPeakingColor = FeedPeakingColor.RED,
    val zebraUnit: FeedZebraUnit = FeedZebraUnit.IRE,
    val zebraHighlightEnabled: Boolean = true,
    val zebraHighlightIre: Float = 100f,
    val zebraHighlightColor: FeedZebraStripeColor = FeedZebraStripeColor.WHITE,
    val zebraMidtoneEnabled: Boolean = true,
    val zebraMidtoneIre: Float = 55f,
    val zebraMidtoneColor: FeedZebraStripeColor = FeedZebraStripeColor.AMBER,
) {
    /** Keeps corruption or a stale preference from producing an invalid core request. */
    fun normalized(): FeedEffectsConfiguration =
        copy(
            zebraHighlightIre =
                zebraHighlightIre.takeIf(Float::isFinite)?.coerceIn(0f, 100f) ?: 100f,
            zebraMidtoneIre =
                zebraMidtoneIre.takeIf(Float::isFinite)?.coerceIn(0f, 100f) ?: 55f,
        )
}

/**
 * Which analysis effects the live feed bakes in, mirroring the iOS shell's
 * `LiveImageEffects`. LUT and false-colour activation are independent, just
 * like iOS. The renderer gives STOPS/IRE false colour visual precedence while
 * preserving the active look so disabling False resumes it; LIMITS composites
 * only crush/clip zones over that look.
 *
 * The shared [AssistState] owns this in normal operation. Debug intent extras
 * (see `DemoHarness`) still seed deterministic sessions: `--es zc.assist
 * lut,falsecolor,peaking,zebra`, plus `--es zc.lut <log3g10|nlog|mono>` and
 * `--es zc.fc.scale <stops|ire|limits>`.
 */
data class FeedEffects(
    val lut: FeedLutSelection? = null,
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
                // Toolbar activation is independent: STOPS/IRE render before
                // the look, but turning False off must reveal the same active
                // selection without a second tap. Limits paints over it.
                lut =
                    if ("lut" in tokens) {
                        FeedLutSelection.BuiltIn(
                            lutId?.let(FeedLut::fromId) ?: FeedLut.LOG3G10_709,
                        )
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
