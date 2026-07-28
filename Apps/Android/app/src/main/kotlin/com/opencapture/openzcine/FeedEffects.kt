package com.opencapture.openzcine

import androidx.compose.runtime.Immutable
import com.opencapture.openzcine.lut.StoredLutSelection

/**
 * Built-in monitor looks. [wireOrdinal] mirrors `FeedEffectsWire.look` in the
 * Swift facade — the core generates each look's cube, Kotlin only uploads it.
 */
enum class FeedLut(val id: String, val wireOrdinal: Int, val label: String) {
    LOG3G10_709("log3g10", 0, "Log3G10→709"),
    NLOG_709("nlog", 1, "N-Log→709"),
    MONO("mono", 2, "Mono");

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
    /**
     * Non-null while the body's photo selector is active: the camera-reported
     * stills tone mode (`SDR`/`HLG`), or empty when it has not been read yet.
     * Swift then anchors the assists on the display-referred stills preview
     * instead of the movie codec's log curve (iOS `exposureSignalMapping`).
     */
    val stillsToneMode: String? = null,
) {
    /** JNI sentinel for a camera that has not reported ISO yet. */
    val isoWireValue: Long
        get() = iso ?: -1L
}

/** Signal-curve wire ordinals owned by the Swift facade (`FeedEffectsWire.curve`). */
internal object ExposureCurveOrdinals {
    const val RED_LOG3G10 = 0
    const val NIKON_NLOG = 1
    const val SRGB = 2
    const val HLG = 3

    /** Every ordinal the Swift facade can emit; parsers refuse anything else. */
    val range = RED_LOG3G10..HLG
}

/**
 * How the 50/50 Log-vs-LUT comparison divides the monitor image — the Kotlin mirror of the shared
 * core's `SplitComparisonOrientation`.
 *
 * The boundary is the centre of the **visible image rectangle**, never of the surface: every
 * backend already sets its viewport to the fitted content rect (`liveFeedContentRect` on GLES,
 * the letterbox clamp in `live_feed_vk_renderer.cpp`), so splitting at the halfway line of feed
 * space excludes pillarbox, letterbox and monitor chrome by construction.
 */
enum class FeedSplitOrientation(val label: String) {
    /** Vertical boundary — Log on the left, LUT on the right. */
    VERTICAL("Left / Right"),

    /** Horizontal boundary — Log on the top, LUT on the bottom. */
    HORIZONTAL("Top / Bottom"),
    ;

    internal companion object {
        /** Edge label for the ungraded half — `SplitComparison.logLabel` in shared core. */
        const val LOG_LABEL: String = "LOG"

        /** Edge label for the graded half — `SplitComparison.lutLabel` in shared core. */
        const val LUT_LABEL: String = "LUT"

        fun fromStoredName(value: String?): FeedSplitOrientation? =
            entries.firstOrNull { it.name == value }
    }
}

/** iOS `Peaking.Sensitivity`, with ordinals owned by the Swift facade. */
enum class FeedPeakingSensitivity(val wireOrdinal: Int, val label: String) {
    LOW(0, "Low"),
    MEDIUM(1, "Med"),
    HIGH(2, "High"),
}

/** iOS `Peaking.Color`, with the actual RGB resolved only by Swift. */
enum class FeedPeakingColor(val wireOrdinal: Int, val label: String) {
    WHITE(0, "White"),
    BLUE(1, "Blue"),
    RED(2, "Red"),
    GREEN(3, "Green"),
}

/** Editor units for the shared-core zebra thresholds. */
enum class FeedZebraUnit(val wireOrdinal: Int, val label: String) {
    NATIVE(0, "0-255"),
    IRE(1, "IRE"),
}

/** iOS `AssistConfiguration.Zebra.StripeColor`; Swift resolves its RGB value. */
enum class FeedZebraStripeColor(val wireOrdinal: Int, val label: String) {
    WHITE(0, "White"),
    AMBER(1, "Amber"),
    RED(2, "Red"),
    CYAN(3, "Cyan"),
    GREEN(4, "Green"),
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
    /** The operator's 50/50 comparison choice, carried even while there is no LUT to apply it to. */
    val splitComparison: FeedSplitOrientation? = null,
) {
    /**
     * The comparison actually rendered. Derived rather than stored so it can never outlive the
     * grade: a mode filter that drops [lut] (clean view without a LUT pin) drops the split with
     * it, exactly as `LUTResolution.splitComparison` does on iOS.
     */
    val activeSplitComparison: FeedSplitOrientation?
        get() = splitComparison?.takeIf { lut != null }

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
