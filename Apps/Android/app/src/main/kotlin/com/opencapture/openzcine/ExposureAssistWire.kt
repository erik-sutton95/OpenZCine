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
            require(values[0] == curve.toFloat() && curve in ExposureCurveOrdinals.range) {
                "invalid exposure curve ${values[0]}"
            }
            require(values[1] in 0f..255f) { "invalid exposure black ${values[1]}" }
            require(values[3] in values[1]..255f) { "invalid exposure clip ${values[3]}" }
            require(values[2] in values[1]..values[3]) {
                "invalid exposure middle gray ${values[2]}"
            }
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
    val deLogCurve: FloatArray,
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
        const val FIELD_COUNT = 22

        /** Decodes one strict Swift record and refuses malformed uniform data. */
        fun parse(values: FloatArray): FeedEffectsRenderConfiguration {
            require(values.size == FIELD_COUNT) { "feed effects configuration length ${values.size}" }
            require(values.all(Float::isFinite)) { "non-finite feed effects configuration" }
            val curveOrdinal = values[0].toInt()
            require(values[0] == curveOrdinal.toFloat() && curveOrdinal in ExposureCurveOrdinals.range) {
                "invalid feed effects curve ${values[0]}"
            }
            require(values[1] in 0f..255f) { "invalid feed effects clip ${values[1]}" }
            val deLogCurve = values.copyOfRange(2, 7)
            require(
                deLogCurve.all { it in 0f..1f } &&
                    deLogCurve.indices.drop(1).all { index ->
                        deLogCurve[index] >= deLogCurve[index - 1]
                    } &&
                    deLogCurve.first() < deLogCurve.last(),
            ) {
                "invalid de-log curve"
            }
            require(values[7] in 0f..1f && values[8] > 0f && values[8] <= 10_000f) {
                "invalid peaking controls"
            }
            requireFlag(values[12], "highlight enabled")
            requireFlag(values[17], "midtone enabled")
            requireCode(values[13], "highlight")
            requireCode(values[18], "midtone")
            requireRgb(values, 9, "peaking")
            requireRgb(values, 14, "highlight")
            requireRgb(values, 19, "midtone")
            return FeedEffectsRenderConfiguration(
                curveOrdinal = curveOrdinal,
                clipNative = values[1],
                deLogCurve = deLogCurve,
                peakingThreshold = values[7],
                peakingRamp = values[8],
                peakingColor = values.copyOfRange(9, 12),
                highlightEnabled = values[12] == 1f,
                highlightCode = values[13],
                highlightColor = values.copyOfRange(14, 17),
                midtoneEnabled = values[17] == 1f,
                midtoneCode = values[18],
                midtoneColor = values.copyOfRange(19, FIELD_COUNT),
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

/** One core-derived colored interval in the optional false-colour key. */
data class FeedFalseColorReferenceSegment(
    val lowerFraction: Float,
    val upperFraction: Float,
    val color: FloatArray,
)

/** Camera-aware palette geometry used only for the optional false-colour key. */
data class FeedFalseColorReference(
    val curveOrdinal: Int,
    val segments: List<FeedFalseColorReferenceSegment>,
    val stopMarkerFractions: FloatArray,
) {
    companion object {
        private const val VERSION = 1
        private const val HEADER_COUNT = 4
        private const val SEGMENT_STRIDE = 5

        /** Decodes the strict renderer-ready geometry returned by Swift. */
        fun parse(
            values: FloatArray,
            scale: FeedFalseColorScale,
            expectedCurveOrdinal: Int,
        ): FeedFalseColorReference {
            require(values.size >= HEADER_COUNT && values.all(Float::isFinite)) {
                "invalid false-color reference"
            }
            val version = values[0].toInt()
            val curve = values[1].toInt()
            val segmentCount = values[2].toInt()
            val markerCount = values[3].toInt()
            require(values[0] == version.toFloat() && version == VERSION) { "invalid false-color version" }
            require(values[1] == curve.toFloat() && curve in ExposureCurveOrdinals.range) {
                "invalid false-color curve"
            }
            require(curve == expectedCurveOrdinal) { "mismatched false-color curve" }
            val expectedSegmentCount =
                when (scale) {
                    FeedFalseColorScale.STOPS -> 8
                    FeedFalseColorScale.IRE -> 9
                    FeedFalseColorScale.LIMITS -> 4
                }
            val expectedMarkerCount = if (scale == FeedFalseColorScale.STOPS) 6 else 0
            require(values[2] == segmentCount.toFloat() && segmentCount == expectedSegmentCount) {
                "invalid false-color segment count"
            }
            require(values[3] == markerCount.toFloat() && markerCount == expectedMarkerCount) {
                "invalid false-color marker count"
            }
            require(values.size == HEADER_COUNT + segmentCount * SEGMENT_STRIDE + markerCount) {
                "invalid false-color reference length ${values.size}"
            }
            var previousUpper = 0f
            val segments =
                (0 until segmentCount).map { index ->
                    val start = HEADER_COUNT + index * SEGMENT_STRIDE
                    val lower = values[start]
                    val upper = values[start + 1]
                    require(lower in 0f..1f && upper in lower..1f) {
                        "invalid false-color segment geometry"
                    }
                    require(index == 0 || lower >= previousUpper) {
                        "non-monotonic false-color segments"
                    }
                    previousUpper = upper
                    val color = values.copyOfRange(start + 2, start + SEGMENT_STRIDE)
                    require(color.all { it in 0f..1f }) { "invalid false-color reference colour" }
                    FeedFalseColorReferenceSegment(lower, upper, color)
                }
            val markerStart = HEADER_COUNT + segmentCount * SEGMENT_STRIDE
            val markers = values.copyOfRange(markerStart, values.size)
            require(markers.all { it in 0f..1f }) { "invalid false-color marker geometry" }
            require(markers.asList().zipWithNext().all { (lower, upper) -> lower <= upper }) {
                "non-monotonic false-color markers"
            }
            return FeedFalseColorReference(curve, segments, markers)
        }
    }
}

/** Calls the Swift core exactly once for the current camera metadata. */
fun resolveExposureAssistMapping(input: ExposureAssistCameraInput): ExposureAssistMapping? {
    if (!SwiftCore.isAvailable) return null
    return runCatching {
        ExposureAssistMapping.parse(
            SwiftCore.exposureAssistMapping(
                input.codec,
                input.isoWireValue,
                input.baseIso,
                input.stillsToneMode,
            ),
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
        FeedFalseColorReference.parse(payload, scale, mapping.curveOrdinal)
    }.getOrNull()
}

/** Returns a camera-aware editor value; `null` preserves a valid saved setting on bridge failure. */
fun zebraEditorValue(
    input: ExposureAssistCameraInput,
    unit: FeedZebraUnit,
    monitorPercent: Float,
): Float? {
    if (!SwiftCore.isAvailable) return null
    val value = SwiftCore.zebraEditorValue(
        input.codec,
        input.isoWireValue,
        input.baseIso,
        input.stillsToneMode,
        unit.wireOrdinal,
        monitorPercent,
    )
    val maximum = if (unit == FeedZebraUnit.NATIVE) 255f else 100f
    return value.takeIf { it.isFinite() && it in 0f..maximum }
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
        input.stillsToneMode,
        unit.wireOrdinal,
        editorValue,
    ).takeIf { it.isFinite() && it in 0f..100f }
}
