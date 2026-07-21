package com.opencapture.openzcine

import android.util.Log
import com.opencapture.openzcine.bridge.SwiftCore
import com.opencapture.openzcine.lut.AndroidLutLibrary
import java.util.LinkedHashMap

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
    val baseCube: FeedEffectsCube?,
    val limitsPaintCube: FeedEffectsCube?,
    val limitsWeightCube: FeedEffectsCube?,
) {
    val limitsReady: Boolean
        get() = limitsPaintCube != null && limitsWeightCube != null

    val falseColorReady: Boolean
        get() =
            when (effects.falseColor) {
                FeedFalseColorScale.STOPS, FeedFalseColorScale.IRE -> baseCube != null
                FeedFalseColorScale.LIMITS -> limitsReady
                null -> false
            }
}

/** One validated packed-2D RGBA8 cube from the shared core. */
internal class FeedEffectsCube(
    val size: Int,
    val rgba: ByteArray,
) {
    init {
        require(size in 2..64) { "unsupported feed-effects cube size $size" }
        require(rgba.size == size * size * size * 4) {
            "bad feed-effects cube payload for size $size"
        }
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
        val limitsPaint =
            if (limitsActive) {
                cachedCube(
                    key =
                        "limits-paint:${renderConfiguration.curveOrdinal}:" +
                            renderConfiguration.clipNative.toBits(),
                    size = 64,
                ) {
                    SwiftCore.bakeFalseColorLimitsPaint(
                        renderConfiguration.curveOrdinal,
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
                        "limits-weight:${renderConfiguration.curveOrdinal}:" +
                            renderConfiguration.clipNative.toBits(),
                    size = 64,
                ) {
                    SwiftCore.bakeFalseColorLimitsWeight(
                        renderConfiguration.curveOrdinal,
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
                configuration.peakingSensitivity.wireOrdinal,
                configuration.peakingColor.wireOrdinal,
                configuration.zebraHighlightEnabled,
                configuration.zebraHighlightIre,
                configuration.zebraHighlightColor.wireOrdinal,
                configuration.zebraMidtoneEnabled,
                configuration.zebraMidtoneIre,
                configuration.zebraMidtoneColor.wireOrdinal,
            ),
        ) { "core rejected the effect configuration" }
            .let(FeedEffectsRenderConfiguration::parse)

    private fun baseCube(
        effects: FeedEffects,
        configuration: FeedEffectsRenderConfiguration,
        lutLibrary: AndroidLutLibrary?,
    ): FeedEffectsCube? {
        val selection = effects.lut
        val cube =
            when {
                effects.falseColor != null && effects.falseColor != FeedFalseColorScale.LIMITS ->
                    cachedCube(
                        key =
                            "false:${effects.falseColor.wireOrdinal}:${configuration.curveOrdinal}:" +
                                configuration.clipNative.toBits(),
                        size = 64,
                    ) {
                        SwiftCore.bakeFalseColorCube(
                            effects.falseColor.wireOrdinal,
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
                        FeedEffectsCube(packed.cubeSize, packed.rgba)
                    }
                else -> null
            }
        if (cube == null && (effects.falseColor != null || selection != null)) {
            Log.w(TAG, "core returned no base cube for $effects; base look disabled")
        }
        return cube
    }

    private fun cachedCube(key: String, size: Int, bake: () -> ByteArray?): FeedEffectsCube? =
        FeedEffectsCubeCache.value(key, bake)?.let { FeedEffectsCube(size, it) }
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
