package com.opencapture.openzcine

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertTrue

class ScopeGpuHistogramTest {
    @Test
    fun `samples solid red into channel bins`() {
        // ARGB packed as Android Color.RED (0xFFFF0000)
        val pixels = IntArray(64) { 0xFFFF0000.toInt() }
        val result = ScopeGpuHistogram.samplePixels(pixels)
        assertEquals(256, result.red.size)
        assertTrue(result.red[255] == 64)
        assertEquals(0, result.green[255])
        assertEquals(0, result.blue[255])
        assertTrue(result.luma.sum() == 64)
    }
}
