@file:androidx.media3.common.util.UnstableApi

package com.opencapture.openzcine.media

import androidx.media3.common.C
import androidx.media3.common.audio.AudioProcessor
import java.nio.ByteBuffer
import java.nio.ByteOrder
import kotlin.math.abs
import kotlin.test.Test
import kotlin.test.assertContentEquals
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import kotlin.test.assertNotNull
import kotlin.test.assertSame
import kotlin.test.assertTrue

class DecodedPlaybackAudioProcessorTest {
    @Test
    fun `PCM bytes pass through exactly`() {
        val processor = configuredProcessor(channelCount = 2)
        val input = pcm16(-32_768, 32_767, -1, 1, 1234, -5678)
        val expected = input.remainingBytes()

        processor.queueInput(input)

        assertContentEquals(expected, processor.output.remainingBytes())
        assertEquals(0, input.remaining())
    }

    @Test
    fun `bounded Media3 output storage is reused across buffers`() {
        val processor = configuredProcessor(channelCount = 2)
        processor.queueInput(pcm16(1, 2, 3, 4))
        val firstOutput = processor.output

        processor.queueInput(pcm16(5, 6))
        val secondOutput = processor.output

        assertSame(firstOutput, secondOutput)
    }

    @Test
    fun `stereo channels accumulate independent absolute peaks`() {
        val processor = configuredProcessor(channelCount = 2)

        processor.queueInput(pcm16(8_192, -16_384, -24_576, 4_096))

        val peaks = assertNotNull(processor.drainSample())
        assertFloatEquals(0.75f, peaks.left)
        assertFloatEquals(0.5f, peaks.right)
    }

    @Test
    fun `mono peak is mirrored to both meter channels`() {
        val processor = configuredProcessor(channelCount = 1)

        processor.queueInput(pcm16(1_024, -32_768, 16_384))

        val peaks = assertNotNull(processor.drainSample())
        assertEquals(1f, peaks.left)
        assertEquals(1f, peaks.right)
    }

    @Test
    fun `multichannel input meters first two channels and passes every channel`() {
        val processor = configuredProcessor(channelCount = 4)
        val input = pcm16(4_096, -8_192, -32_768, 30_000, -16_384, 2_048, 31_000, -31_000)
        val expected = input.remainingBytes()

        processor.queueInput(input)

        assertContentEquals(expected, processor.output.remainingBytes())
        val peaks = assertNotNull(processor.drainSample())
        assertFloatEquals(0.5f, peaks.left)
        assertFloatEquals(0.25f, peaks.right)
    }

    @Test
    fun `drain returns interval maxima then clears them`() {
        val processor = configuredProcessor(channelCount = 2)
        processor.queueInput(pcm16(4_096, 8_192))
        processor.output
        processor.queueInput(pcm16(-16_384, 2_048))

        val first = assertNotNull(processor.drainSample())
        val second = processor.drainSample()

        assertFloatEquals(0.5f, first.left)
        assertFloatEquals(0.25f, first.right)
        assertEquals(0f, second?.left ?: 0f)
        assertEquals(0f, second?.right ?: 0f)
    }

    @Test
    fun `flush and reset discard accumulated peaks`() {
        val processor = configuredProcessor(channelCount = 2)
        processor.queueInput(pcm16(-32_768, -32_768))
        processor.flush(AudioProcessor.StreamMetadata.DEFAULT)
        val flushed = processor.drainSample()
        assertEquals(0f, flushed?.left ?: 0f)
        assertEquals(0f, flushed?.right ?: 0f)

        processor.queueInput(pcm16(-32_768, -32_768))
        processor.reset()
        val reset = processor.drainSample()
        assertEquals(0f, reset?.left ?: 0f)
        assertEquals(0f, reset?.right ?: 0f)
    }

    @Test
    fun `non 16-bit PCM is rejected because sink conversion must run first`() {
        val processor = DecodedPlaybackAudioProcessor()

        assertFailsWith<AudioProcessor.UnhandledAudioFormatException> {
            processor.configure(AudioProcessor.AudioFormat(48_000, 2, C.ENCODING_PCM_FLOAT))
        }
    }

    @Test
    fun `prepared source stays absent until real PCM is observed`() {
        val processor = configuredProcessor(channelCount = 2)
        assertEquals(null, processor.drainSample())
        processor.queueInput(pcm16(0, 0))
        val measured = processor.drainSample()
        assertTrue(measured != null)
        assertEquals(0f, measured.left)
        assertEquals(0f, measured.right)
    }

    @Test
    fun `flush replaces the source without carrying a held peak`() {
        val processor = configuredProcessor(channelCount = 2)
        processor.queueInput(pcm16(-32_768, -32_768))
        val old = processor.drainSample()
        assertTrue(old != null)
        processor.flush(AudioProcessor.StreamMetadata.DEFAULT)
        assertEquals(null, processor.drainSample())
        processor.queueInput(pcm16(0, 0))
        val replacement = processor.drainSample()
        assertTrue(replacement != null)
        assertTrue(old.sourceGeneration != replacement.sourceGeneration)
        assertEquals(0f, replacement.left)
        assertEquals(0f, replacement.right)
    }

    @Test
    fun `disposal closes sampling before late format and decoded callbacks`() {
        val processor = configuredProcessor(channelCount = 2)
        processor.queueInput(pcm16(-32_768, -32_768))
        processor.close()
        assertEquals(null, processor.drainSample())
        processor.flush(AudioProcessor.StreamMetadata.DEFAULT)
        processor.queueInput(pcm16(-32_768, -32_768))
        assertEquals(null, processor.drainSample())
    }

    private fun configuredProcessor(channelCount: Int): DecodedPlaybackAudioProcessor =
        DecodedPlaybackAudioProcessor().apply {
            val format = AudioProcessor.AudioFormat(48_000, channelCount, C.ENCODING_PCM_16BIT)
            assertEquals(format, configure(format))
            flush(AudioProcessor.StreamMetadata.DEFAULT)
        }

    private fun pcm16(vararg samples: Int): ByteBuffer =
        ByteBuffer.allocateDirect(samples.size * Short.SIZE_BYTES)
            .order(ByteOrder.nativeOrder())
            .apply {
                samples.forEach { putShort(it.toShort()) }
                flip()
            }

    private fun ByteBuffer.remainingBytes(): ByteArray =
        ByteArray(remaining()).also { duplicate().get(it) }

    private fun assertFloatEquals(expected: Float, actual: Float) {
        assertTrue(abs(expected - actual) < 0.000_01f, "Expected $expected, got $actual")
    }
}
