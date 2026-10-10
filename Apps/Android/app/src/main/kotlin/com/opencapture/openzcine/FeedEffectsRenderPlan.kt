package com.opencapture.openzcine

import android.util.Log
import com.opencapture.openzcine.bridge.SwiftCore
import com.opencapture.openzcine.lut.AndroidLutLibrary
import java.util.LinkedHashMap
import com.opencapture.opencine.media.MonitorLUTCube

private const val TAG = "ZCFeedEffects"
private const val BUILT_IN_LUT_SIZE = 33

/**
 * Immutable renderer input produced entirely from shared Swift policy.
 *
 * Android's AGSL and GLES adapters consume this same record. The byte arrays are process-owned,
 * cached payloads and are never exposed to UI state or mutated after construction.
 */
internal class FeedEffectsRenderPlan(
    val effects: FeedEffects,
    val configuration: FeedEffectsRenderConfiguration,
    val baseCube: MonitorLUTCube?,
    val limitsPaintCube: MonitorLUTCube?,
    val limitsWeightCube: MonitorLUTCube?,
) {
    internal val nativePlan: com.opencapture.opencine.media.FeedEffectsRenderPlan by lazy {
        com.opencapture.opencine.media.FeedEffectsRenderPlan(
            lutCube = baseCube, falseColorPaint = limitsPaintCube, falseColorWeight = limitsWeightCube,
            peaking = effects.peaking, peakingColor = configuration.peakingColor,
            peakingRatioThreshold = configuration.peakingRatioThreshold,
            peakingNoiseGate = configuration.peakingNoiseGate,
            zebraHighlightOn = effects.zebra && configuration.highlightEnabled,
            zebraHighlightCode = configuration.highlightCode,
            zebraHighlightColor = configuration.highlightColor,
            zebraMidtoneOn = effects.zebra && configuration.midtoneEnabled,
            zebraMidtoneCode = configuration.midtoneCode, zebraMidtoneHalf = 5f / 255f,
            zebraMidtoneColor = configuration.midtoneColor,
            splitComparison = splitComparison != null,
            splitVertical = splitComparison == FeedSplitOrientation.VERTICAL,
            zebraMaskPolicy = com.opencapture.opencine.media.MonitorZebraMaskPolicy(
                highlightMeasure = com.opencapture.opencine.media.MonitorZebraMaskPolicy.HighlightMeasure.REC709_LUMA,
                rampBias = 0.0,
            ),
        )
    }

    /**
     * The 50/50 Log-vs-LUT comparison to render, or `null`.
     *
     * Only when [baseCube] is the operator's LUT: STOPS/IRE false colour replaces the base with
     * exposure zones, which IS the monitoring image and has no ungraded half to compare against.
     * LIMITS keeps the LUT as its base and paints over it, so it splits — matching the iOS
     * `resolve` branches exactly.
     */
    val splitComparison: FeedSplitOrientation?
        get() =
            effects.activeSplitComparison?.takeIf {
                baseCube != null &&
                    (effects.falseColor == null || effects.falseColor == FeedFalseColorScale.LIMITS)
            }

    val limitsReady: Boolean
        get() = limitsPaintCube != null && limitsWeightCube != null

    val falseColorReady: Boolean
        get() =
            when (effects.falseColor) {
                FeedFalseColorScale.STOPS, FeedFalseColorScale.VIDEO, FeedFalseColorScale.IRE -> baseCube != null
                FeedFalseColorScale.LIMITS -> limitsReady
                null -> false
            }
}

/** Builds the single shared plan used by every Android GPU backend. */
internal object FeedEffectsRenderPlanFactory {
    fun create(
        effects: FeedEffects,
        configuration: FeedEffectsConfiguration,
        cameraInput: ExposureAssistCameraInput,
        lutLibrary: AndroidLutLibrary? = null,
    ): FeedEffectsRenderPlan? {
        if (!SwiftCore.isAvailable) {
            Log.w(TAG, "feed effects need the Swift core (just android-core); rendering plain")
            return null
        }
        return try {
            build(effects, configuration.normalized(), cameraInput, lutLibrary)
        } catch (error: RuntimeException) {
            Log.e(TAG, "feed-effects plan setup failed; rendering the plain feed", error)
            null
        }
    }

    private fun build(
        effects: FeedEffects,
        configuration: FeedEffectsConfiguration,
        cameraInput: ExposureAssistCameraInput,
        lutLibrary: AndroidLutLibrary?,
    ): FeedEffectsRenderPlan {
        val renderConfiguration = renderConfiguration(configuration, cameraInput)
        // Identity is still a real plan (all effect flags off) so the GPU present
        // path can stay mounted and swap peaking/LUT/zebra without a black frame.
        if (effects.isIdentity) {
            return FeedEffectsRenderPlan(
                effects = effects,
                configuration = renderConfiguration,
                baseCube = null,
                limitsPaintCube = null,
                limitsWeightCube = null,
            )
        }
        val baseCube = baseCube(effects, renderConfiguration, lutLibrary)
        val limitsActive = effects.falseColor == FeedFalseColorScale.LIMITS
        val readingCurveOrdinal = renderConfiguration.curveOrdinal + if (effects.falseColorRec709) 4 else 0
        val limitsPaint =
            if (limitsActive) {
                cachedCube(
                    key =
                        "limits-paint:$readingCurveOrdinal:" +
                            renderConfiguration.clipNative.toBits(),
                    size = 64,
                ) {
                    SwiftCore.bakeFalseColorLimitsPaint(
                        readingCurveOrdinal,
                        renderConfiguration.clipNative,
                    )
                }
            } else {
                null
            }
        val limitsWeight =
            if (limitsActive) {
                cachedCube(
                    key =
                        "limits-weight:$readingCurveOrdinal:" +
                            renderConfiguration.clipNative.toBits(),
                    size = 64,
                ) {
                    SwiftCore.bakeFalseColorLimitsWeight(
                        readingCurveOrdinal,
                        renderConfiguration.clipNative,
                    )
                }
            } else {
                null
            }
        val plan =
            FeedEffectsRenderPlan(
                effects = effects,
                configuration = renderConfiguration,
                baseCube = baseCube,
                limitsPaintCube = limitsPaint,
                limitsWeightCube = limitsWeight,
            )
        if (BuildConfig.DEBUG) {
            Log.d(
                TAG,
                "plan up: $effects cube=${baseCube?.rgba?.size ?: 0}B " +
                    "curve=${renderConfiguration.curveOrdinal} " +
                    "clip=${renderConfiguration.clipNative} limits=${plan.limitsReady}",
            )
        }
        return plan
    }

    private fun renderConfiguration(
        configuration: FeedEffectsConfiguration,
        cameraInput: ExposureAssistCameraInput,
    ): FeedEffectsRenderConfiguration =
        requireNotNull(
            SwiftCore.feedEffectsConfiguration(
                cameraInput.codec,
                cameraInput.isoWireValue,
                cameraInput.baseIso,
                cameraInput.stillsToneMode,
                configuration.peakingSensitivity.ordinal,
                configuration.peakingColor.ordinal,
                configuration.zebraHighlightEnabled,
                configuration.zebraHighlightIre,
                configuration.zebraHighlightColor.ordinal,
                configuration.zebraMidtoneEnabled,
                configuration.zebraMidtoneIre,
                configuration.zebraMidtoneColor.ordinal,
            ),
        ) { "core rejected the effect configuration" }
            .let(FeedEffectsRenderConfiguration::parse)

    private fun baseCube(
        effects: FeedEffects,
        configuration: FeedEffectsRenderConfiguration,
        lutLibrary: AndroidLutLibrary?,
    ): MonitorLUTCube? {
        val selection = effects.lut
        val cube =
            when {
                effects.falseColor != null && effects.falseColor != FeedFalseColorScale.LIMITS ->
                    cachedCube(
                        key =
                            "false:${effects.falseColor.wireOrdinal}:${effects.falseColorRec709}:${configuration.curveOrdinal}:" +
                                configuration.clipNative.toBits(),
                        size = 64,
                    ) {
                        SwiftCore.bakeFalseColorCube(
                            effects.falseColor.wireOrdinal + if (effects.falseColorRec709) 4 else 0,
                            configuration.curveOrdinal,
                            configuration.clipNative,
                        )
                    }
                selection is FeedLutSelection.BuiltIn ->
                    cachedCube(
                        key = "lut:${selection.value.wireOrdinal}:$BUILT_IN_LUT_SIZE",
                        size = BUILT_IN_LUT_SIZE,
                    ) {
                        SwiftCore.bakeLut(selection.value.wireOrdinal, BUILT_IN_LUT_SIZE)
                    }
                selection is FeedLutSelection.Stored ->
                    lutLibrary?.packedCube(selection.value)?.let { packed ->
                        MonitorLUTCube(packed.cubeSize, packed.rgba)
                    }
                else -> null
            }
        if (cube == null && (effects.falseColor != null || selection != null)) {
            Log.w(TAG, "core returned no base cube for $effects; base look disabled")
        }
        return cube
    }

    private fun cachedCube(key: String, size: Int, bake: () -> ByteArray?): MonitorLUTCube? =
        FeedEffectsCubeCache.value(key, bake)?.let { MonitorLUTCube(size, it) }
}

/** Bounded cache for immutable Swift-baked cube bytes. */
private object FeedEffectsCubeCache {
    private const val MAX_ENTRIES = 8
    private val cubes =
        object : LinkedHashMap<String, ByteArray>(MAX_ENTRIES, 0.75f, true) {
            override fun removeEldestEntry(eldest: MutableMap.MutableEntry<String, ByteArray>?): Boolean =
                size > MAX_ENTRIES
        }

    fun value(key: String, bake: () -> ByteArray?): ByteArray? =
        synchronized(cubes) {
            cubes[key] ?: bake()?.also { cubes[key] = it }
        }
}
