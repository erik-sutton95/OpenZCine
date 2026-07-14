package com.opencapture.openzcine

import com.opencapture.openzcine.core.LiveFrame
import java.util.concurrent.atomic.AtomicLong
import kotlin.math.max
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.conflate
import kotlinx.coroutines.flow.onEach

/**
 * Frame-pacing counters for the live feed: presented fps, decode time, and
 * frames dropped by latest-wins conflation. Emits one summary line through
 * [log] roughly every [reportIntervalNanos] of presented frames.
 *
 * Pure Kotlin (no Android imports) so the accounting is JVM-unit-testable.
 * [frameReceived] may be called from a different thread than
 * [framePresented] (the source emits upstream of the conflation buffer);
 * everything else is presenter-thread-only.
 */
class FramePacingStats(
    private val reportIntervalNanos: Long = 5_000_000_000L,
    private val log: (String) -> Unit,
) {
    private val received = AtomicLong(0)
    private var receivedAtWindowStart = 0L
    private var presented = 0L
    private var decodeTotalNanos = 0L
    private var decodeMaxNanos = 0L
    private var windowStartNanos = 0L
    private var hasWindow = false

    /** Records one frame arriving from the source, before conflation. */
    fun frameReceived() {
        received.incrementAndGet()
    }

    /**
     * Records one frame decoded and handed to the renderer.
     *
     * @param decodeNanos Time spent decoding this frame.
     * @param nowNanos Monotonic time of presentation ([System.nanoTime]).
     */
    fun framePresented(decodeNanos: Long, nowNanos: Long) {
        if (!hasWindow) {
            // The first present only establishes the window baseline — counting
            // it would overstate fps by one fencepost frame per window.
            hasWindow = true
            windowStartNanos = nowNanos
            receivedAtWindowStart = received.get()
            return
        }
        presented++
        decodeTotalNanos += decodeNanos
        decodeMaxNanos = max(decodeMaxNanos, decodeNanos)

        val elapsed = nowNanos - windowStartNanos
        if (elapsed < reportIntervalNanos || presented == 0L) return

        val receivedInWindow = received.get() - receivedAtWindowStart
        val fps = presented * 1e9 / elapsed
        val avgMs = decodeTotalNanos / presented / 1e6
        val maxMs = decodeMaxNanos / 1e6
        log(
            "feed pacing: %.1f fps | decode avg %.1f ms max %.1f ms | dropped %d/%d"
                .format(fps, avgMs, maxMs, receivedInWindow - presented, receivedInWindow)
        )
        presented = 0
        decodeTotalNanos = 0
        decodeMaxNanos = 0
        windowStartNanos = nowNanos
        receivedAtWindowStart = received.get()
    }
}

/**
 * Drives frames from a source into a renderer with latest-wins conflation:
 * if [decode] + [present] run slower than the source emits, intermediate
 * frames are skipped (and counted as dropped by [stats]) instead of queueing
 * up latency. Suspends until the source completes or the caller is cancelled.
 *
 * Generic over the decoded type so the pipeline is JVM-unit-testable without
 * Android bitmaps.
 */
suspend fun <T : Any> pumpFrames(
    frames: Flow<LiveFrame>,
    stats: FramePacingStats,
    decode: (ByteArray) -> T?,
    present: (T) -> Unit,
) {
    frames
        .onEach { stats.frameReceived() }
        .conflate()
        .collect { frame ->
            val start = System.nanoTime()
            val decoded = decode(frame.jpegData) ?: return@collect
            present(decoded)
            stats.framePresented(decodeNanos = System.nanoTime() - start, nowNanos = System.nanoTime())
        }
}
