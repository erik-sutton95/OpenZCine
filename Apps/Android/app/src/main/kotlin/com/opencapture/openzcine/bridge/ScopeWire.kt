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

/** Direction of a Swift-measured Traffic Lights goal-post fill. */
enum class TrafficLightsBarSide {
    /** The channel remains inside the core's mid-grey dead zone. */
    NEUTRAL,

    /** The channel leans toward the highlight / clip end of the goal post. */
    OVER,

    /** The channel leans toward the shadow / crush end of the goal post. */
    UNDER,
}

/** One RGB channel from the core-owned Traffic Lights goal-post meter. */
data class TrafficLightsChannel(
    /** Core-derived 0…1 reference-IRE level. */
    val level: Float,
    /** The core detected a clip-edge pileup. */
    val clip: Boolean,
    /** The core detected a crush-edge pileup. */
    val crush: Boolean,
    /** Core-derived side of the centre line that receives fill. */
    val side: TrafficLightsBarSide,
    /** Core-derived normalized fill for [side]. */
    val fill: Float,
)

/** Immutable Swift-owned RGB Traffic Lights result for one clean scope tick. */
data class TrafficLightsReading(
    val red: TrafficLightsChannel,
    val green: TrafficLightsChannel,
    val blue: TrafficLightsChannel,
) {
    companion object {
        /** Safe neutral fallback for a legacy scope payload with no trailer. */
        val EMPTY =
            TrafficLightsReading(
                red = TrafficLightsChannel(0f, false, false, TrafficLightsBarSide.NEUTRAL, 0f),
                green = TrafficLightsChannel(0f, false, false, TrafficLightsBarSide.NEUTRAL, 0f),
                blue = TrafficLightsChannel(0f, false, false, TrafficLightsBarSide.NEUTRAL, 0f),
            )
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
    /** Optional additive Swift Traffic Lights payload; null only for a legacy core binary. */
    val trafficLights: TrafficLightsReading?,
) {
    companion object {
        /** Floats per point record — mirrors `ScopeFrameWire.pointStride`. */
        const val POINT_STRIDE = 5

        /** Display bins per histogram channel — mirrors `ScopeFrameWire.histogramBins`. */
        const val HISTOGRAM_BINS = 256

        /** Mirrors `ScopeFrameWire.trafficTrailerMagic`. */
        private const val TRAFFIC_TRAILER_MAGIC = 31_415f

        /** Mirrors `ScopeFrameWire.trafficTrailerVersion`. */
        private const val TRAFFIC_TRAILER_VERSION = 1f

        /** Floats in each RGB Traffic Lights trailer record. */
        private const val TRAFFIC_CHANNEL_STRIDE = 5

        /** Marker, version, then three RGB channel records. */
        private const val TRAFFIC_TRAILER_FLOATS = 2 + 3 * TRAFFIC_CHANNEL_STRIDE

        /** Decodes the wire array; throws when malformed. */
        fun parse(flat: FloatArray): ScopeTraces {
            require(flat.isNotEmpty()) { "empty scope payload" }
            require(flat[0].isFinite() && flat[0] >= 0f) { "invalid scope point count ${flat[0]}" }
            val count = flat[0].toInt()
            require(flat[0] == count.toFloat()) { "fractional scope point count ${flat[0]}" }
            require(count <= (flat.size - 1) / POINT_STRIDE) { "scope point count $count overflows payload" }
            val pointsEnd = 1 + count * POINT_STRIDE
            val legacyLength = pointsEnd + 4 * HISTOGRAM_BINS
            require(flat.size == legacyLength || flat.size == legacyLength + TRAFFIC_TRAILER_FLOATS) {
                "scope payload length ${flat.size} for $count points"
            }
            fun histogram(channel: Int): FloatArray {
                val start = pointsEnd + channel * HISTOGRAM_BINS
                return flat.copyOfRange(start, start + HISTOGRAM_BINS)
            }
            val trafficLights =
                if (flat.size == legacyLength) {
                    null
                } else {
                    parseTrafficLights(flat, legacyLength)
                }
            return ScopeTraces(
                pointCount = count,
                points = flat.copyOfRange(1, pointsEnd),
                histogramLuma = histogram(0),
                histogramRed = histogram(1),
                histogramGreen = histogram(2),
                histogramBlue = histogram(3),
                trafficLights = trafficLights,
            )
        }

        /** Validates the versioned additive trailer before any UI observes it. */
        private fun parseTrafficLights(flat: FloatArray, start: Int): TrafficLightsReading {
            require(flat[start] == TRAFFIC_TRAILER_MAGIC) { "unknown Traffic Lights trailer" }
            require(flat[start + 1] == TRAFFIC_TRAILER_VERSION) {
                "unsupported Traffic Lights trailer version ${flat[start + 1]}"
            }

            fun channel(index: Int): TrafficLightsChannel {
                val offset = start + 2 + index * TRAFFIC_CHANNEL_STRIDE
                val level = flat[offset]
                val clip = flag(flat[offset + 1], "clip", index)
                val crush = flag(flat[offset + 2], "crush", index)
                val side = side(flat[offset + 3], index)
                val fill = flat[offset + 4]
                require(level.isFinite() && level in 0f..1f) { "invalid Traffic Lights level $level" }
                require(fill.isFinite() && fill in 0f..1f) { "invalid Traffic Lights fill $fill" }
                if (side == TrafficLightsBarSide.NEUTRAL) {
                    require(fill == 0f) { "neutral Traffic Lights channel has fill $fill" }
                }
                return TrafficLightsChannel(level, clip, crush, side, fill)
            }

            return TrafficLightsReading(channel(0), channel(1), channel(2))
        }

        private fun flag(value: Float, name: String, channel: Int): Boolean {
            require(value == 0f || value == 1f) { "invalid Traffic Lights $name flag $value for channel $channel" }
            return value == 1f
        }

        private fun side(value: Float, channel: Int): TrafficLightsBarSide =
            when (value) {
                0f -> TrafficLightsBarSide.NEUTRAL
                1f -> TrafficLightsBarSide.OVER
                2f -> TrafficLightsBarSide.UNDER
                else -> throw IllegalArgumentException("invalid Traffic Lights side $value for channel $channel")
            }
    }
}
