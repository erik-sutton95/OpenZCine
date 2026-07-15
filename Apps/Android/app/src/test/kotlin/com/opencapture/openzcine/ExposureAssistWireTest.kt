package com.opencapture.openzcine

import com.opencapture.openzcine.settings.normalizedZebraEntry
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import kotlin.test.assertFalse
import kotlin.test.assertTrue

class ExposureAssistWireTest {
    private fun falseColorReferencePayload(
        scale: FeedFalseColorScale,
        curveOrdinal: Int = 0,
    ): FloatArray {
        val segmentCount =
            when (scale) {
                FeedFalseColorScale.STOPS -> 8
                FeedFalseColorScale.IRE -> 9
                FeedFalseColorScale.LIMITS -> 4
            }
        val markers =
            if (scale == FeedFalseColorScale.STOPS) {
                listOf(0.02f, 0.2f, 0.4f, 0.6f, 0.8f, 0.98f)
            } else {
                emptyList()
            }
        return buildList {
            add(1f)
            add(curveOrdinal.toFloat())
            add(segmentCount.toFloat())
            add(markers.size.toFloat())
            repeat(segmentCount) { index ->
                add(index.toFloat() / segmentCount)
                add((index + 0.75f) / segmentCount)
                add(index.toFloat() / segmentCount)
                add(0.5f)
                add(1f - index.toFloat() / segmentCount)
            }
            addAll(markers)
        }.toFloatArray()
    }

    @Test
    fun `camera mapping accepts the complete Swift record`() {
        val mapping = ExposureAssistMapping.parse(floatArrayOf(1f, 16f, 85f, 200f))

        assertEquals(1, mapping.curveOrdinal)
        assertEquals(16f, mapping.blackNative)
        assertEquals(85f, mapping.middleGrayNative)
        assertEquals(200f, mapping.clipNative)
    }

    @Test
    fun `camera mapping rejects malformed or nonfinite Swift payloads`() {
        assertFailsWith<IllegalArgumentException> {
            ExposureAssistMapping.parse(floatArrayOf(0f, 0f, 85f))
        }
        assertFailsWith<IllegalArgumentException> {
            ExposureAssistMapping.parse(floatArrayOf(3f, 0f, 85f, 180f))
        }
        assertFailsWith<IllegalArgumentException> {
            ExposureAssistMapping.parse(floatArrayOf(0f, 0f, Float.NaN, 180f))
        }
        assertFailsWith<IllegalArgumentException> {
            ExposureAssistMapping.parse(floatArrayOf(0f, 100f, 85f, 80f))
        }
        assertFailsWith<IllegalArgumentException> {
            ExposureAssistMapping.parse(floatArrayOf(0f, 16f, 210f, 180f))
        }
    }

    @Test
    fun `feed effects record keeps separate renderer-ready zebra zones`() {
        val record =
            FeedEffectsRenderConfiguration.parse(
                floatArrayOf(
                    1f, 200f, 0f, 0.2f, 0.5f, 0.8f, 1f, 0.00132f, 160f,
                    0.2f, 0.4f, 0.8f,
                    1f, 0.78f, 1f, 1f, 1f,
                    0f, 0.41f, 1f, 0.72f, 0.2f,
                ),
            )

        assertEquals(1, record.curveOrdinal)
        assertEquals(200f, record.clipNative)
        assertTrue(record.highlightEnabled)
        assertFalse(record.midtoneEnabled)
        assertEquals(0.78f, record.highlightCode)
        assertEquals(0.41f, record.midtoneCode)
        assertEquals(listOf(0.2f, 0.4f, 0.8f), record.peakingColor.toList())
        assertEquals(listOf(1f, 0.72f, 0.2f), record.midtoneColor.toList())
    }

    @Test
    fun `feed effects record rejects an invalid flag or colour`() {
        val valid =
            floatArrayOf(
                0f, 180f, 0f, 0.2f, 0.5f, 0.8f, 1f, 0.002f, 160f,
                1f, 0f, 0f,
                1f, 0.7f, 1f, 1f, 1f,
                1f, 0.4f, 1f, 0.7f, 0.2f,
            )
        assertFailsWith<IllegalArgumentException> {
            FeedEffectsRenderConfiguration.parse(valid.copyOf().also { it[12] = 0.5f })
        }
        assertFailsWith<IllegalArgumentException> {
            FeedEffectsRenderConfiguration.parse(valid.copyOf().also { it[20] = 1.1f })
        }
        assertFailsWith<IllegalArgumentException> {
            FeedEffectsRenderConfiguration.parse(valid.copyOf().also { it[7] = 1.1f })
        }
        assertFailsWith<IllegalArgumentException> {
            FeedEffectsRenderConfiguration.parse(valid.copyOf().also { it[8] = 0f })
        }
    }

    @Test
    fun `false color reference requires a complete finite palette`() {
        val payload = falseColorReferencePayload(FeedFalseColorScale.STOPS)
        val reference =
            FeedFalseColorReference.parse(
                payload,
                FeedFalseColorScale.STOPS,
                expectedCurveOrdinal = 0,
            )
        assertEquals(0, reference.curveOrdinal)
        assertEquals(8, reference.segments.size)
        assertEquals(0.125f, reference.segments[1].lowerFraction)
        assertEquals(6, reference.stopMarkerFractions.size)

        val ire =
            FeedFalseColorReference.parse(
                falseColorReferencePayload(FeedFalseColorScale.IRE, curveOrdinal = 1),
                FeedFalseColorScale.IRE,
                expectedCurveOrdinal = 1,
            )
        assertEquals(9, ire.segments.size)
        assertTrue(ire.stopMarkerFractions.isEmpty())

        assertFailsWith<IllegalArgumentException> {
            FeedFalseColorReference.parse(
                payload.copyOf(payload.size - 1),
                FeedFalseColorScale.STOPS,
                expectedCurveOrdinal = 0,
            )
        }
        assertFailsWith<IllegalArgumentException> {
            FeedFalseColorReference.parse(
                payload.copyOf().also { it[0] = 2f },
                FeedFalseColorScale.STOPS,
                expectedCurveOrdinal = 0,
            )
        }
        assertFailsWith<IllegalArgumentException> {
            FeedFalseColorReference.parse(
                payload.copyOf().also { it[1] = 1f },
                FeedFalseColorScale.STOPS,
                expectedCurveOrdinal = 0,
            )
        }
        assertFailsWith<IllegalArgumentException> {
            FeedFalseColorReference.parse(
                payload.copyOf().also { it[3] = 5f },
                FeedFalseColorScale.STOPS,
                expectedCurveOrdinal = 0,
            )
        }
        assertFailsWith<IllegalArgumentException> {
            FeedFalseColorReference.parse(
                payload.copyOf().also { it[9] = 0f },
                FeedFalseColorScale.STOPS,
                expectedCurveOrdinal = 0,
            )
        }
        assertFailsWith<IllegalArgumentException> {
            FeedFalseColorReference.parse(
                payload.copyOf().also { it[45] = 0.01f },
                FeedFalseColorScale.STOPS,
                expectedCurveOrdinal = 0,
            )
        }
    }

    @Test
    fun `zebra direct entry clamps the complete native and IRE ranges`() {
        assertEquals(255, normalizedZebraEntry("255", 255))
        assertEquals(255, normalizedZebraEntry("999", 255))
        assertEquals(0, normalizedZebraEntry("0", 100))
        assertEquals(8, normalizedZebraEntry("008", 100))
        assertEquals(null, normalizedZebraEntry("", 100))
        assertEquals(null, normalizedZebraEntry("not-a-number", 100))
    }
}
