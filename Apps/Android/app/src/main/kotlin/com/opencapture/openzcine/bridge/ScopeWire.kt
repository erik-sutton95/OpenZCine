package com.opencapture.openzcine.bridge

/**
 * Fixed scope-axis anchors decoded from [SwiftCore.scopeAnchors] — the Kotlin
 * view of the Swift `ScopeFrameWire.anchors` payload. Levels are display
 * fractions 0…1 from the plot bottom; the mid-grey anchor is per-curve and
 * NEVER moves with ISO/exposure (the core pins it — Erik's hard rule).
 */
data class ScopeAnchors(
    val crushLine: Float,
    val midGray: Float,
    val clipLine: Float,
    /** Six 75% colour-bar targets as `(cb, cr)` pairs, each in −0.5…+0.5. */
    val vectorTargets: List<Pair<Float, Float>>,
) {
    companion object {
        private const val TARGET_COUNT = 6

        /** Decodes the wire array; throws when malformed. */
        fun parse(flat: FloatArray): ScopeAnchors {
            require(flat.size == 3 + TARGET_COUNT * 2) { "anchor array length ${flat.size}" }
            return ScopeAnchors(
                crushLine = flat[0],
                midGray = flat[1],
                clipLine = flat[2],
                vectorTargets = (0 until TARGET_COUNT).map { Pair(flat[3 + it * 2], flat[4 + it * 2]) },
            )
        }
    }
}

/**
 * One scope tick decoded from [SwiftCore.scopeTraces] — the Kotlin view of the
 * Swift `ScopeFrameWire.traces` payload. Per-point levels and histogram
 * buckets are already on the anchored display axis; drawing needs no curve
 * math.
 */
class ScopeTraces(
    val pointCount: Int,
    /** `pointCount × 5` floats: `x, luma, red, green, blue` per point. */
    val points: FloatArray,
    val histogramLuma: FloatArray,
    val histogramRed: FloatArray,
    val histogramGreen: FloatArray,
    val histogramBlue: FloatArray,
) {
    companion object {
        /** Floats per point record — mirrors `ScopeFrameWire.pointStride`. */
        const val POINT_STRIDE = 5

        /** Display bins per histogram channel — mirrors `ScopeFrameWire.histogramBins`. */
        const val HISTOGRAM_BINS = 256

        /** Decodes the wire array; throws when malformed. */
        fun parse(flat: FloatArray): ScopeTraces {
            require(flat.isNotEmpty()) { "empty scope payload" }
            val count = flat[0].toInt()
            val pointsEnd = 1 + count * POINT_STRIDE
            require(flat.size == pointsEnd + 4 * HISTOGRAM_BINS) {
                "scope payload length ${flat.size} for $count points"
            }
            fun histogram(channel: Int): FloatArray {
                val start = pointsEnd + channel * HISTOGRAM_BINS
                return flat.copyOfRange(start, start + HISTOGRAM_BINS)
            }
            return ScopeTraces(
                pointCount = count,
                points = flat.copyOfRange(1, pointsEnd),
                histogramLuma = histogram(0),
                histogramRed = histogram(1),
                histogramGreen = histogram(2),
                histogramBlue = histogram(3),
            )
        }
    }
}
