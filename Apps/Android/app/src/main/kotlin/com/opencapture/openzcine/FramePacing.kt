package com.opencapture.openzcine

import com.opencapture.openzcine.core.LiveFrame
import java.util.concurrent.atomic.AtomicLong
import kotlin.math.max
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.conflate
import kotlinx.coroutines.flow.onEach

/**
 * Frame-pacing counters for the live feed: presented fps, decode time, frames
 * dropped by latest-wins conflation, and how OLD a frame is when it reaches the
 * renderer. Emits one summary line through [log] roughly every
 * [reportIntervalNanos] of presented frames.
 *
 * AGE is the number the field reports are about and the only one here that was
 * missing. Every other counter measures THROUGHPUT, and throughput does not
 * answer "how far behind the room is this picture" — a feed can hold a steady
 * 30 fps while running a third of a second late, because a stage that keeps up
 * on average can still be holding a frame that is waiting its turn. Tuning fps
 * without watching age is how a pipeline gets fast and late at the same time.
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
    private var ageTotalNanos = 0L
    private var ageMaxNanos = 0L
    private var agedFrames = 0L
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
     * @param ageNanos How long this frame waited between the transport having it
     *   and the renderer getting it — decode, plus any time it spent held. The
     *   transport stamps on the same `CLOCK_MONOTONIC` Kotlin reads, so the two
     *   are directly comparable. Negative or absent values are ignored rather
     *   than trusted: a source with no usable stamp must not invent a latency.
     */
    fun framePresented(decodeNanos: Long, nowNanos: Long, ageNanos: Long = -1L) {
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
        if (ageNanos >= 0) {
            ageTotalNanos += ageNanos
            ageMaxNanos = max(ageMaxNanos, ageNanos)
            agedFrames++
        }

        val elapsed = nowNanos - windowStartNanos
        if (elapsed < reportIntervalNanos || presented == 0L) return

        val receivedInWindow = received.get() - receivedAtWindowStart
        val fps = presented * 1e9 / elapsed
        val avgMs = decodeTotalNanos / presented / 1e6
        val maxMs = decodeMaxNanos / 1e6
        // Reported only when it was actually measured. A source with no usable stamp printing
        // "age avg 0.0 ms" would be claiming the one thing we cannot see, and this counter exists
        // precisely because the invisible number was the one that mattered.
        val age =
            if (agedFrames > 0) {
                "age avg %.1f ms max %.1f ms | "
                    .format(ageTotalNanos / agedFrames / 1e6, ageMaxNanos / 1e6)
            } else {
                ""
            }
        log(
            "feed pacing: %.1f fps | decode avg %.1f ms max %.1f ms | %sdropped %d/%d"
                .format(fps, avgMs, maxMs, age, receivedInWindow - presented, receivedInWindow)
        )
        presented = 0
        decodeTotalNanos = 0
        decodeMaxNanos = 0
        ageTotalNanos = 0
        ageMaxNanos = 0
        agedFrames = 0
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
    pumpFramesWithSourceFrame(
        frames = frames,
        stats = stats,
        decode = { frame -> decode(frame.jpegData) },
        present = { _, decoded -> present(decoded) },
    )
}

/**
 * Variant of [pumpFrames] that keeps the accepted source frame paired with
 * its decoded presentation. Live overlays use this to avoid applying a newer
 * focus or horizon packet to an older bitmap after conflation.
 *
 * [decode] receives the whole frame, not just its JPEG bytes, so a source
 * whose frames already carry a decoded payload (HDMI capture) can skip the
 * decoder entirely.
 */
suspend fun <T : Any> pumpFramesWithSourceFrame(
    frames: Flow<LiveFrame>,
    stats: FramePacingStats,
    decode: (LiveFrame) -> T?,
    present: (LiveFrame, T) -> Unit,
) {
    frames
        .onEach { stats.frameReceived() }
        .conflate()
        .collect { frame ->
            val start = System.nanoTime()
            val decoded = decode(frame) ?: return@collect
            present(frame, decoded)
            val done = System.nanoTime()
            stats.framePresented(
                decodeNanos = done - start,
                nowNanos = done,
                // The transport stamps `timestampNanos` off CLOCK_MONOTONIC, which is the clock
                // `System.nanoTime()` reads — see `PTPIPClientSession.monotonicNanoseconds`. A
                // source that leaves it at zero (or ahead of us) reports no age rather than a
                // fictional one.
                ageNanos = if (frame.timestampNanos > 0) done - frame.timestampNanos else -1L,
            )
        }
}
