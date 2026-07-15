package com.opencapture.openzcine

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import kotlin.test.assertFalse
import kotlin.test.assertTrue

class ExposureAssistWireTest {
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
    }

    @Test
    fun `feed effects record keeps separate renderer-ready zebra zones`() {
        val record =
            FeedEffectsRenderConfiguration.parse(
                floatArrayOf(
                    1f, 200f, 0.062f, 0.784f, 0.00132f, 160f,
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
                0f, 180f, 0f, 0.7f, 0.002f, 160f,
                1f, 0f, 0f,
                1f, 0.7f, 1f, 1f, 1f,
                1f, 0.4f, 1f, 0.7f, 0.2f,
            )
        assertFailsWith<IllegalArgumentException> {
            FeedEffectsRenderConfiguration.parse(valid.copyOf().also { it[9] = 0.5f })
        }
        assertFailsWith<IllegalArgumentException> {
            FeedEffectsRenderConfiguration.parse(valid.copyOf().also { it[17] = 1.1f })
        }
    }

    @Test
    fun `false color reference requires a complete finite palette`() {
        val reference =
            FeedFalseColorReference.parse(
                floatArrayOf(2f, 1f, 0f, 0f, 0f, 1f, 0f),
            )
        assertEquals(2, reference.colors.size)
        assertEquals(listOf(0f, 1f, 0f), reference.colors[1].toList())

        assertFailsWith<IllegalArgumentException> {
            FeedFalseColorReference.parse(floatArrayOf(2f, 1f, 0f, 0f))
        }
        assertFailsWith<IllegalArgumentException> {
            FeedFalseColorReference.parse(floatArrayOf(1f, 1.1f, 0f, 0f))
        }
    }
}
