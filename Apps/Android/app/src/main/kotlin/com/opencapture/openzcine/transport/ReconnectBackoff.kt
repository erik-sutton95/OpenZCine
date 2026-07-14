package com.opencapture.openzcine.transport

import kotlin.math.max
import kotlin.math.pow
import kotlin.math.roundToLong

/**
 * Jittered exponential backoff for reconnect retries — the Kotlin twin of the
 * shared core's `ReconnectBackoff` (`Sources/OpenZCineCore/ReconnectBackoff.swift`).
 *
 * Plain doubling wakes every retry at the same instants and hammers a flaky
 * access point with synchronized bursts; spreading each delay by a random
 * fraction de-correlates them. The jitter sample is injected (`0.0..1.0`)
 * rather than drawn internally so the schedule stays pure and unit-testable.
 *
 * @property baseMillis Delay for the very first retry (attempt 0).
 * @property maxMillis Hard ceiling, applied before and after jitter.
 * @property multiplier Per-attempt growth factor (2.0 = double each attempt).
 * @property jitterFraction Proportional spread in `0.0..1.0` (0.3 = ±30%).
 */
data class ReconnectBackoff(
    val baseMillis: Long = 500,
    val maxMillis: Long = 30_000,
    val multiplier: Double = 2.0,
    val jitterFraction: Double = 0.3,
) {
    /**
     * The delay in milliseconds before retry [attempt] (0 = first retry;
     * negatives are treated as 0). [jitter] is a sample in `0.0..1.0`
     * (clamped): 0 = lower bound, 0.5 = un-jittered, 1 = upper bound.
     */
    fun delayMillis(attempt: Int, jitter: Double): Long {
        val exponent = max(0, attempt).toDouble()
        val capped = minOf(maxMillis.toDouble(), baseMillis * multiplier.pow(exponent))
        val clampedJitter = jitter.coerceIn(0.0, 1.0)
        val signedSpread = (clampedJitter * 2 - 1) * jitterFraction
        val jittered = capped * (1 + signedSpread)
        return jittered.coerceIn(0.0, maxMillis.toDouble()).roundToLong()
    }
}
