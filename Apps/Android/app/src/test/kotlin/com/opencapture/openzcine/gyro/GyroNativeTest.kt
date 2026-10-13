package com.opencapture.openzcine.gyro

import org.junit.Assert.assertEquals
import org.junit.Test
import java.nio.ByteBuffer
import java.nio.ByteOrder

class GyroNativeTest {
    @Test fun `batch retains sensor time and axis values without float narrowing`() {
        val timestamp = 123456.123456789
        val values = ByteBuffer.wrap(encodeGyroBatch(listOf(
            AndroidGyroSample(timestamp, -1.25, 2.5, -3.75),
        ))).order(ByteOrder.LITTLE_ENDIAN)
        assertEquals(timestamp, values.double, 0.0)
        assertEquals(-1.25, values.double, 0.0)
        assertEquals(2.5, values.double, 0.0)
        assertEquals(-3.75, values.double, 0.0)
        assertEquals(0, values.remaining())
    }

    @Test(expected = IllegalArgumentException::class)
    fun `unbounded batch is rejected before native call`() {
        encodeGyroBatch(List(513) { AndroidGyroSample(it.toDouble(), 0.0, 0.0, 0.0) })
    }
}
