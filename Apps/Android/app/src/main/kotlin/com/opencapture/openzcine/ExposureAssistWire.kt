package com.opencapture.openzcine

import com.opencapture.openzcine.bridge.SwiftCore

/**
 * Camera-aware signal mapping resolved by the shared Swift exposure core.
 * Kotlin carries this opaque record between the renderer, clean scope sampler,
 * and settings editor; it does not infer a curve, black point, or clip point.
 */
data class ExposureAssistMapping(
    val curveOrdinal: Int,
    val blackNative: Float,
    val middleGrayNative: Float,
    val clipNative: Float,
) {
    companion object {
        private const val FIELD_COUNT = 4

        /** Validates the versionless fixed-size payload returned by Swift. */
        fun parse(values: FloatArray): ExposureAssistMapping {
            require(values.size == FIELD_COUNT) { "exposure mapping length ${values.size}" }
            require(values.all(Float::isFinite)) { "non-finite exposure mapping" }
            val curve = values[0].toInt()
            require(values[0] == curve.toFloat() && curve in 0..1) { "invalid exposure curve ${values[0]}" }
            require(values[1] in 0f..255f) { "invalid exposure black ${values[1]}" }
            require(values[2] in 0f..255f) { "invalid exposure middle gray ${values[2]}" }
            require(values[3] in values[1]..255f) { "invalid exposure clip ${values[3]}" }
            return ExposureAssistMapping(curve, values[1], values[2], values[3])
        }
    }
}

/**
 * Stable Swift shader record for peaking and the two independently configured
 * zebra zones. The fields deliberately contain only renderer-ready values;
 * all exposure/colour policy was resolved before this reaches Kotlin.
 */
data class FeedEffectsRenderConfiguration(
    val curveOrdinal: Int,
    val clipNative: Float,
    val deLogBlack: Float,
    val deLogClip: Float,
    val peakingThreshold: Float,
    val peakingRamp: Float,
    val peakingColor: FloatArray,
    val highlightEnabled: Boolean,
    val highlightCode: Float,
    val highlightColor: FloatArray,
    val midtoneEnabled: Boolean,
    val midtoneCode: Float,
    val midtoneColor: FloatArray,
) {
    companion object {
        /** Mirrors `FeedEffectsWire.renderConfigurationFieldCount`. */
        const val FIELD_COUNT = 19

        /** Decodes one strict Swift record and refuses malformed uniform data. */
        fun parse(values: FloatArray): FeedEffectsRenderConfiguration {
            require(values.size == FIELD_COUNT) { "feed effects configuration length ${values.size}" }
            require(values.all(Float::isFinite)) { "non-finite feed effects configuration" }
            val curveOrdinal = values[0].toInt()
            require(values[0] == curveOrdinal.toFloat() && curveOrdinal in 0..1) {
                "invalid feed effects curve ${values[0]}"
            }
            require(values[1] in 0f..255f) { "invalid feed effects clip ${values[1]}" }
            require(values[2] in 0f..1f && values[3] in 0f..1f && values[3] > values[2]) {
                "invalid de-log range"
            }
            require(values[4] >= 0f && values[5] >= 0f) { "invalid peaking controls" }
            requireFlag(values[9], "highlight enabled")
            requireFlag(values[14], "midtone enabled")
            requireCode(values[10], "highlight")
            requireCode(values[15], "midtone")
            requireRgb(values, 6, "peaking")
            requireRgb(values, 11, "highlight")
            requireRgb(values, 16, "midtone")
            return FeedEffectsRenderConfiguration(
                curveOrdinal = curveOrdinal,
                clipNative = values[1],
                deLogBlack = values[2],
                deLogClip = values[3],
                peakingThreshold = values[4],
                peakingRamp = values[5],
                peakingColor = values.copyOfRange(6, 9),
                highlightEnabled = values[9] == 1f,
                highlightCode = values[10],
                highlightColor = values.copyOfRange(11, 14),
                midtoneEnabled = values[14] == 1f,
                midtoneCode = values[15],
                midtoneColor = values.copyOfRange(16, FIELD_COUNT),
            )
        }

        private fun requireFlag(value: Float, name: String) {
            require(value == 0f || value == 1f) { "invalid $name $value" }
        }

        private fun requireCode(value: Float, name: String) {
            require(value in 0f..1f) { "invalid $name code $value" }
        }

        private fun requireRgb(values: FloatArray, start: Int, name: String) {
            require(values.sliceArray(start until start + 3).all { it in 0f..1f }) {
                "invalid $name colour"
            }
        }
    }
}

/** Compact core-derived palette used only for the optional false-colour key. */
data class FeedFalseColorReference(val colors: List<FloatArray>) {
    companion object {
        /** Decodes `[count, r, g, b × count]` and rejects incomplete data. */
        fun parse(values: FloatArray): FeedFalseColorReference {
            require(values.isNotEmpty() && values[0].isFinite()) { "invalid false-color reference" }
            val count = values[0].toInt()
            require(values[0] == count.toFloat() && count >= 0 && values.size == 1 + count * 3) {
                "invalid false-color reference length ${values.size}"
            }
            val colors =
                (0 until count).map { index ->
                    val start = 1 + index * 3
                    values.copyOfRange(start, start + 3).also { color ->
                        require(color.all { it.isFinite() && it in 0f..1f }) {
                            "invalid false-color reference colour"
                        }
                    }
                }
            return FeedFalseColorReference(colors)
        }
    }
}

/** Calls the Swift core exactly once for the current camera metadata. */
fun resolveExposureAssistMapping(input: ExposureAssistCameraInput): ExposureAssistMapping? {
    if (!SwiftCore.isAvailable) return null
    return runCatching {
        ExposureAssistMapping.parse(
            SwiftCore.exposureAssistMapping(input.codec, input.isoWireValue, input.baseIso),
        )
    }.getOrNull()
}

/** Resolves the optional colour key from the same Swift mapping as the GPU cube. */
fun resolveFalseColorReference(
    scale: FeedFalseColorScale,
    input: ExposureAssistCameraInput,
): FeedFalseColorReference? {
    val mapping = resolveExposureAssistMapping(input) ?: return null
    return runCatching {
        val payload =
            requireNotNull(
                SwiftCore.falseColorReference(scale.wireOrdinal, mapping.curveOrdinal, mapping.clipNative),
            ) { "missing false-color reference" }
        FeedFalseColorReference.parse(payload)
    }.getOrNull()
}

/** Returns a camera-aware editor value; `null` preserves a valid saved setting on bridge failure. */
fun zebraEditorValue(
    input: ExposureAssistCameraInput,
    unit: FeedZebraUnit,
    monitorPercent: Float,
): Float? {
    if (!SwiftCore.isAvailable) return null
    return SwiftCore.zebraEditorValue(
        input.codec,
        input.isoWireValue,
        input.baseIso,
        unit.wireOrdinal,
        monitorPercent,
    ).takeIf(Float::isFinite)
}

/** Converts a user editor value through Swift without locally duplicating its mapping policy. */
fun zebraMonitorPercent(
    input: ExposureAssistCameraInput,
    unit: FeedZebraUnit,
    editorValue: Float,
): Float? {
    if (!SwiftCore.isAvailable) return null
    return SwiftCore.zebraMonitorPercent(
        input.codec,
        input.isoWireValue,
        input.baseIso,
        unit.wireOrdinal,
        editorValue,
    ).takeIf { it.isFinite() && it in 0f..100f }
}
