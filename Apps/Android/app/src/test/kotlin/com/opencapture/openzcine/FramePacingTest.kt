package com.opencapture.openzcine

import com.opencapture.openzcine.core.LiveFrame
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertTrue
import kotlinx.coroutines.cancelAndJoin
import kotlinx.coroutines.flow.MutableSharedFlow
import kotlinx.coroutines.flow.asFlow
import kotlinx.coroutines.launch
import kotlinx.coroutines.test.runTest

class FramePacingStatsTest {
    private val reports = mutableListOf<String>()
    private val stats = FramePacingStats(reportIntervalNanos = 1_000_000_000L, log = reports::add)

    /** One received + presented frame every 40 ms; frame 0 is the window baseline. */
    private fun presentSteadily(count: Int, decodeNanos: Long = 10_000_000L) {
        repeat(count) { index ->
            stats.frameReceived()
            stats.framePresented(decodeNanos = decodeNanos, nowNanos = index * 40_000_000L)
        }
    }

    @Test
    fun `reports fps and decode times once the interval elapses`() {
        // Baseline frame + 25 frames over exactly one second.
        presentSteadily(26)
        assertEquals(1, reports.size)
        assertEquals("feed pacing: 25.0 fps | decode avg 10.0 ms max 10.0 ms | dropped 0/25", reports[0])
    }

    @Test
    fun `counts frames conflated away as dropped`() {
        stats.frameReceived()
        stats.framePresented(decodeNanos = 0L, nowNanos = 0L) // baseline
        repeat(50) { stats.frameReceived() }
        repeat(25) { index ->
            stats.framePresented(decodeNanos = 5_000_000L, nowNanos = (index + 1) * 40_000_000L)
        }
        assertEquals(1, reports.size)
        assertTrue(reports[0].endsWith("dropped 25/50"), reports[0])
    }

    @Test
    fun `window resets after each report`() {
        // Baseline + two full one-second windows of 25 frames each.
        presentSteadily(51)
        assertEquals(2, reports.size)
        assertTrue(reports[1].contains("25.0 fps"), reports[1])
    }
}

class PumpFramesTest {
    private fun frame(index: Int): LiveFrame =
        LiveFrame(timestampNanos = index.toLong(), jpegData = byteArrayOf(index.toByte()))

    @Test
    fun `presents every frame when the consumer keeps up`() = runTest {
        val source = MutableSharedFlow<LiveFrame>()
        val presented = mutableListOf<Byte>()
        val pump = launch {
            pumpFrames(
                frames = source,
                stats = FramePacingStats(log = {}),
                decode = { it[0] },
                present = { presented.add(it) },
            )
        }
        testScheduler.advanceUntilIdle() // subscribe before emitting
        repeat(5) { index ->
            source.emit(frame(index))
            testScheduler.advanceUntilIdle() // consumer keeps up: drains each frame
        }
        pump.cancelAndJoin()
        assertEquals(listOf<Byte>(0, 1, 2, 3, 4), presented)
    }

    @Test
    fun `conflates to the latest frame when the consumer lags`() = runTest {
        val presented = mutableListOf<Byte>()
        // A burst the consumer never gets between: latest-wins keeps only the
        // first frame (taken immediately) and the newest one. The drop ledger
        // itself is covered deterministically in FramePacingStatsTest.
        pumpFrames(
            frames = (0 until 10).map(::frame).asFlow(),
            stats = FramePacingStats(log = {}),
            decode = { it[0] },
            present = { presented.add(it) },
        )
        assertEquals(listOf<Byte>(0, 9), presented)
    }

    @Test
    fun `skips frames the decoder rejects`() = runTest {
        val source = MutableSharedFlow<LiveFrame>()
        val presented = mutableListOf<Byte>()
        val pump = launch {
            pumpFrames(
                frames = source,
                stats = FramePacingStats(log = {}),
                decode = { bytes -> bytes[0].takeIf { it.toInt() % 2 == 0 } },
                present = { presented.add(it) },
            )
        }
        testScheduler.advanceUntilIdle()
        repeat(4) { index ->
            source.emit(frame(index))
            testScheduler.advanceUntilIdle()
        }
        pump.cancelAndJoin()
        assertEquals(listOf<Byte>(0, 2), presented)
    }

    @Test
    fun `switching sources cancels the old pump cleanly`() = runTest {
        val firstSource = MutableSharedFlow<LiveFrame>()
        val presented = mutableListOf<Byte>()
        val firstPump = launch {
            pumpFrames(
                frames = firstSource,
                stats = FramePacingStats(log = {}),
                decode = { it[0] },
                present = { presented.add(it) },
            )
        }
        testScheduler.advanceUntilIdle()
        firstSource.emit(frame(1))
        testScheduler.advanceUntilIdle()
        // Source switch: the shell cancels the old collector and pumps the new
        // source (LaunchedEffect keyed on the source does exactly this).
        firstPump.cancelAndJoin()
        pumpFrames(
            frames = listOf(frame(10)).asFlow(),
            stats = FramePacingStats(log = {}),
            decode = { it[0] },
            present = { presented.add(it) },
        )
        assertEquals(listOf<Byte>(1, 10), presented)
    }
}
