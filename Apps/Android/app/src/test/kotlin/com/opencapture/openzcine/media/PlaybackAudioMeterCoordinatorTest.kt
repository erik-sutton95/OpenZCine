@file:androidx.media3.common.util.UnstableApi
@file:OptIn(kotlinx.coroutines.ExperimentalCoroutinesApi::class)

package com.opencapture.openzcine.media

import androidx.media3.common.C
import androidx.media3.common.audio.AudioProcessor
import java.nio.ByteBuffer
import java.nio.ByteOrder
import kotlinx.coroutines.cancelAndJoin
import kotlinx.coroutines.launch
import kotlinx.coroutines.test.advanceTimeBy
import kotlinx.coroutines.test.runCurrent
import kotlinx.coroutines.test.runTest
import kotlin.math.abs
import kotlin.test.Test
import kotlin.test.assertContentEquals
import kotlin.test.assertEquals
import kotlin.test.assertNotNull
import kotlin.test.assertNull
import kotlin.test.assertTrue
import com.opencapture.opencine.nikon.LiveAudioMeterLevels

class PlaybackAudioMeterCoordinatorTest {
    @Test
    fun `wire parser returns LiveAudioMeterLevels and retains ages`() {
        val payload = floatArrayOf(-12f, -6f, 1.25f, -24f, -18f, 0.75f)

        val wire = assertNotNull(PlaybackAudioMeterWire.parse(payload))

        assertEquals(-12.0, wire.levels.left.levelDb)
        assertEquals(-6.0, wire.levels.left.peakDb)
        assertEquals(-24.0, wire.levels.right.levelDb)
        assertEquals(-18.0, wire.levels.right.peakDb)
        assertContentEquals(payload, wire.payload)
        payload[0] = 0f
        assertEquals(-12f, wire.payload[0])
    }

    @Test
    fun `wire parser rejects malformed native payloads`() {
        assertNull(PlaybackAudioMeterWire.parse(null))
        assertNull(PlaybackAudioMeterWire.parse(floatArrayOf(-60f)))
        assertNull(PlaybackAudioMeterWire.parse(floatArrayOf(-12f, -6f, Float.NaN, -12f, -6f, 0f)))
        assertNull(PlaybackAudioMeterWire.parse(floatArrayOf(1f, 1f, 0f, -12f, -6f, 0f)))
        assertNull(PlaybackAudioMeterWire.parse(floatArrayOf(-6f, -12f, 0f, -12f, -6f, 0f)))
        assertNull(PlaybackAudioMeterWire.parse(floatArrayOf(-12f, -6f, -1f, -12f, -6f, 0f)))
    }

    @Test
    fun `poller drains decoded peaks and publishes native levels at iOS cadence`() = runTest {
        val processor = configuredProcessor()
        var nowNanos = 0L
        var call: StepCall? = null
        val coordinator =
            PlaybackAudioMeterCoordinator(
                audioProcessor = processor,
                stepper =
                    PlaybackAudioMeterStepper { previous, left, right, dt ->
                        call = StepCall(previous.copyOf(), left, right, dt)
                        floatArrayOf(-6f, -3f, 0.25f, -12f, -9f, 0.5f)
                    },
                monotonicNanos = { nowNanos },
                pollIntervalMillis = 42L,
            )
        val job = launch { coordinator.poll() }
        runCurrent()
        processor.queueInput(pcm16(-16_384, 8_192))
        processor.output
        nowNanos = 42_000_000L

        advanceTimeBy(42L)
        runCurrent()

        val observed = assertNotNull(call)
        assertEquals(0, observed.previous.size)
        assertFloatEquals(0.5f, observed.left)
        assertFloatEquals(0.25f, observed.right)
        assertFloatEquals(0.042f, observed.dt)
        val levels = assertNotNull(coordinator.levels.value)
        assertEquals(-6.0, levels.left.levelDb)
        assertEquals(-9.0, levels.right.peakDb)
        job.cancelAndJoin()
        assertNull(coordinator.levels.value)
    }

    @Test
    fun `malformed result clears presentation and restarts native state`() = runTest {
        val processor = configuredProcessor()
        var nowNanos = 0L
        val priorSizes = mutableListOf<Int>()
        var callCount = 0
        val coordinator =
            PlaybackAudioMeterCoordinator(
                audioProcessor = processor,
                stepper =
                    PlaybackAudioMeterStepper { previous, _, _, _ ->
                        priorSizes += previous.size
                        callCount += 1
                        if (callCount == 1) {
                            floatArrayOf(Float.NaN)
                        } else {
                            floatArrayOf(-60f, -60f, 0f, -60f, -60f, 0f)
                        }
                    },
                monotonicNanos = { nowNanos },
                pollIntervalMillis = 1L,
            )
        val job = launch { coordinator.poll() }
        runCurrent()
        // A malformed native-result fixture starts from actual measured PCM silence.
        processor.queueInput(pcm16(0, 0))
        processor.output

        nowNanos = 1_000_000L
        advanceTimeBy(1L)
        runCurrent()
        assertNull(coordinator.levels.value)

        nowNanos = 2_000_000L
        advanceTimeBy(1L)
        runCurrent()
        assertEquals(listOf(0, 0), priorSizes)
        assertNotNull(coordinator.levels.value)
        job.cancelAndJoin()
    }

    @Test
    fun `unmeasured PCM is absent and never invokes native ballistics`() = runTest {
        var calls = 0
        val coordinator = PlaybackAudioMeterCoordinator(
            audioProcessor = configuredProcessor(),
            stepper = PlaybackAudioMeterStepper { _, _, _, _ ->
                calls += 1
                floatArrayOf(-60f, -60f, 0f, -60f, -60f, 0f)
            },
            monotonicNanos = { 0L },
            pollIntervalMillis = 1L,
        )
        val job = launch { coordinator.poll() }
        runCurrent()
        advanceTimeBy(2L)
        runCurrent()
        assertEquals(0, calls)
        assertNull(coordinator.levels.value)
        job.cancelAndJoin()
    }

    @Test
    fun `source replacement resets JNI peak hold while actual silence stays known`() = runTest {
        val processor = configuredProcessor()
        val priorSizes = mutableListOf<Int>()
        val coordinator = PlaybackAudioMeterCoordinator(
            audioProcessor = processor,
            stepper = PlaybackAudioMeterStepper { previous, _, _, _ ->
                priorSizes += previous.size
                floatArrayOf(-60f, -60f, 0f, -60f, -60f, 0f)
            },
            monotonicNanos = { 0L },
            pollIntervalMillis = 1L,
        )
        val job = launch { coordinator.poll() }
        runCurrent()
        processor.queueInput(pcm16(0, 0))
        processor.output
        advanceTimeBy(1L)
        runCurrent()
        assertNotNull(coordinator.levels.value)
        processor.flush(AudioProcessor.StreamMetadata.DEFAULT)
        advanceTimeBy(1L)
        runCurrent()
        assertNull(coordinator.levels.value)
        processor.queueInput(pcm16(0, 0))
        processor.output
        advanceTimeBy(1L)
        runCurrent()
        assertNotNull(coordinator.levels.value)
        assertEquals(listOf(0, 0), priorSizes)
        coordinator.close()
        advanceTimeBy(1L)
        runCurrent()
        assertNull(coordinator.levels.value)
        job.cancelAndJoin()
    }

    @Test
    fun `flush during native step refuses retired result and preserves successor audio`() = runTest {
        val processor = configuredProcessor()
        val calls = mutableListOf<StepCall>()
        val coordinator = PlaybackAudioMeterCoordinator(
            audioProcessor = processor,
            stepper = PlaybackAudioMeterStepper { previous, left, right, dt ->
                calls += StepCall(previous.copyOf(), left, right, dt)
                if (calls.size == 1) {
                    // Deterministic replacement exactly between drain and native-result publication.
                    processor.flush(AudioProcessor.StreamMetadata.DEFAULT)
                    processor.queueInput(pcm16(4_096, 8_192))
                    processor.output
                    floatArrayOf(0f, 0f, 0f, 0f, 0f, 0f)
                } else {
                    floatArrayOf(-18f, -18f, 0f, -12f, -12f, 0f)
                }
            },
            monotonicNanos = { 0L },
            pollIntervalMillis = 1L,
        )
        val job = launch { coordinator.poll() }
        runCurrent()
        processor.queueInput(pcm16(-32_768, -32_768))
        processor.output
        advanceTimeBy(1L)
        runCurrent()
        assertEquals(1, calls.size)
        assertEquals(1f, calls[0].left)
        assertNull(coordinator.levels.value)

        advanceTimeBy(1L)
        runCurrent()
        assertEquals(2, calls.size)
        assertEquals(0, calls[1].previous.size)
        assertEquals(0.125f, calls[1].left)
        assertEquals(0.25f, calls[1].right)
        val successor = assertNotNull(coordinator.levels.value)
        assertEquals(-18.0, successor.left.levelDb)
        assertEquals(-12.0, successor.right.levelDb)
        job.cancelAndJoin()
    }

    private data class StepCall(
        val previous: FloatArray,
        val left: Float,
        val right: Float,
        val dt: Float,
    )

    private fun configuredProcessor(): DecodedPlaybackAudioProcessor =
        DecodedPlaybackAudioProcessor().apply {
            configure(AudioProcessor.AudioFormat(48_000, 2, C.ENCODING_PCM_16BIT))
            flush(AudioProcessor.StreamMetadata.DEFAULT)
        }

    private fun pcm16(vararg samples: Int): ByteBuffer =
        ByteBuffer.allocateDirect(samples.size * Short.SIZE_BYTES)
            .order(ByteOrder.nativeOrder())
            .apply {
                samples.forEach { putShort(it.toShort()) }
                flip()
            }

    private fun assertFloatEquals(expected: Float, actual: Float) {
        assertTrue(abs(expected - actual) < 0.000_01f, "Expected $expected, got $actual")
    }
}
