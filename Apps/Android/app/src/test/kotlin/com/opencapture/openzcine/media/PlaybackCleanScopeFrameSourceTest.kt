package com.opencapture.openzcine.media

import java.nio.ByteBuffer
import kotlin.test.Test
import kotlin.test.assertContentEquals
import kotlin.test.assertFailsWith

class PlaybackCleanScopeFrameSourceTest {
    @Test
    fun `gles rows are copied into top-down scope order`() {
        val bottomRow = byteArrayOf(1, 2, 3, 4, 5, 6, 7, 8)
        val topRow = byteArrayOf(11, 12, 13, 14, 15, 16, 17, 18)

        assertContentEquals(
            topRow + bottomRow,
            glRgbaTopDown(ByteBuffer.wrap(bottomRow + topRow), width = 2, height = 2),
        )
    }

    @Test
    fun `truncated clean frame is rejected`() {
        assertFailsWith<IllegalArgumentException> {
            glRgbaTopDown(ByteBuffer.allocate(7), width = 2, height = 1)
        }
    }
}
