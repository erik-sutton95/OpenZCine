package com.opencapture.openzcine.diagnostics

import com.opencapture.opencine.media.FeedIncidentAges
import com.opencapture.opencine.media.FeedIncidentDecoder
import com.opencapture.opencine.media.FeedIncidentLifecycle
import com.opencapture.opencine.media.FeedIncidentRates
import com.opencapture.opencine.media.FeedIncidentSnapshot
import com.opencapture.opencine.media.FeedIncidentSource

/** Observations for one canonical held connection; owns no camera, decoder, collector or timer. */
internal class NikonFeedIncidentProducer(
    private val source: FeedIncidentSource,
    private val isCurrentConnection: () -> Boolean,
    private val clock: () -> Double = { System.nanoTime() / 1_000_000_000.0 },
) {
    private val gate = Any()
    private var closed = false
    private val counts = IntArray(4)
    private val stamps = arrayOfNulls<Double>(4)
    private var previousAt: Double? = null
    private var previousCounts: IntArray? = null

    fun received() { note(0) }
    fun published() { note(3) }
    private fun note(stage: Int) = synchronized(gate) {
        if (!closed && isCurrentConnection()) { counts[stage]++; stamps[stage] = clock() }
    }

    /** Wraps the existing decoder call, capturing this observer before native work starts. */
    fun <T : Any> decode(work: () -> T?): T? {
        note(1)
        val output = work()
        if (output != null) note(2)
        return output
    }

    fun snapshot(lifecycle: FeedIncidentLifecycle, now: Double = clock()): FeedIncidentSnapshot = synchronized(gate) {
        val elapsed = previousAt?.let { now - it } ?: 0.0
        fun rate(index: Int): Double {
            val previous = previousCounts ?: return 0.0
            return if (elapsed > 0.0) (counts[index] - previous[index]).coerceAtLeast(0) / elapsed else 0.0
        }
        fun age(index: Int): Double? = stamps[index]?.let { (now - it).coerceAtLeast(0.0) }
        val sample = FeedIncidentSnapshot(now, System.currentTimeMillis(),
            rates = FeedIncidentRates(accessUnitHz = rate(0), decodeSubmitHz = rate(1), decodedOutputHz = rate(2)),
            ages = FeedIncidentAges(accessUnitAge = age(0), decodedOutputAge = age(2)),
            decoder = FeedIncidentDecoder(codec = "jpeg"),
            lifecycle = lifecycle.copy(outputObservable = counts[2] > 0, presentationExpected = false,
                liveEstablished = stamps[3] != null))
        previousAt = now
        previousCounts = counts.copyOf()
        sample
    }

    fun publish(lifecycle: FeedIncidentLifecycle) {
        val sample = snapshot(lifecycle)
        synchronized(gate) { if (!closed && isCurrentConnection()) source.ingestSnapshot(sample) }
    }

    fun unexpectedDisconnect() = synchronized(gate) {
        if (!closed) source.noteUnexpectedDisconnect(clock())
    }

    fun end() {
        val shouldEnd = synchronized(gate) { if (closed) false else { closed = true; true } }
        if (shouldEnd) source.endSession(clock())
    }
}
