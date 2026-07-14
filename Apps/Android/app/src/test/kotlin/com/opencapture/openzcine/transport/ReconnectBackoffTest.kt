package com.opencapture.openzcine.transport

import kotlin.test.Test
import kotlin.test.assertEquals

/** Mirrors the Swift core's ReconnectBackoff semantics. */
class ReconnectBackoffTest {
    private val backoff = ReconnectBackoff()

    @Test
    fun `midpoint jitter doubles from the base each attempt`() {
        assertEquals(500, backoff.delayMillis(attempt = 0, jitter = 0.5))
        assertEquals(1_000, backoff.delayMillis(attempt = 1, jitter = 0.5))
        assertEquals(2_000, backoff.delayMillis(attempt = 2, jitter = 0.5))
    }

    @Test
    fun `delay is capped at the maximum`() {
        assertEquals(30_000, backoff.delayMillis(attempt = 20, jitter = 0.5))
        // Upper-bound jitter never pushes past the cap either.
        assertEquals(30_000, backoff.delayMillis(attempt = 20, jitter = 1.0))
    }

    @Test
    fun `jitter spreads the delay by the configured fraction`() {
        assertEquals(350, backoff.delayMillis(attempt = 0, jitter = 0.0))
        assertEquals(650, backoff.delayMillis(attempt = 0, jitter = 1.0))
    }

    @Test
    fun `out-of-range jitter samples are clamped`() {
        assertEquals(350, backoff.delayMillis(attempt = 0, jitter = -3.0))
        assertEquals(650, backoff.delayMillis(attempt = 0, jitter = 7.0))
    }

    @Test
    fun `negative attempts are treated as the first retry`() {
        assertEquals(500, backoff.delayMillis(attempt = -5, jitter = 0.5))
    }
}
