package com.opencapture.openzcine.transport

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNull
import kotlin.test.assertTrue

/**
 * Z 6III over USB-C (issue #562): every attempt failed at the first bulk-in read
 * (`usb.handshake.read`) about 2.2 s after handshaking began, well inside the 5 s
 * GetDeviceInfo deadline. A dead bulk-out already got a reset and a retry; a dead
 * bulk-in got neither, and Android's -1 could not say whether it was a timeout or
 * an error. These pin the bulk-in twin: classify by elapsed time, clear the
 * halted pipe once and retry within the same deadline, never past it.
 */
class UsbPtpDeadReadRecoveryTest {
    private class FakeClock(var now: Long = 1_000L) {
        fun advance(millis: Long) {
            now += millis
        }
    }

    @Test
    fun `a healthy read is returned and never clears the pipe`() {
        val clock = FakeClock()
        var clears = 0
        val outcome =
            recoverDeadBulkInRead(
                isClosed = { false },
                canRecover = true,
                timeoutMillis = 5_000,
                nowMillis = { clock.now },
                read = { clock.advance(40); 512 },
                clearHalt = { clears += 1 },
            )

        assertEquals(512, outcome.byteCount)
        assertNull(outcome.firstFailure)
        assertFalse(outcome.recoveryAttempted)
        assertEquals(0, clears)
    }

    @Test
    fun `an early failure is an error that clears the pipe once and retries in the remaining time`() {
        val clock = FakeClock()
        val reads = mutableListOf<Int>()
        var clears = 0
        val outcome =
            recoverDeadBulkInRead(
                isClosed = { false },
                canRecover = true,
                timeoutMillis = 5_000,
                nowMillis = { clock.now },
                read = { timeout ->
                    reads += timeout
                    if (reads.size == 1) {
                        clock.advance(1_800)
                        -1
                    } else {
                        clock.advance(30)
                        512
                    }
                },
                clearHalt = { clears += 1; clock.advance(20) },
            )

        assertEquals(512, outcome.byteCount)
        assertEquals(UsbBulkInFailure.ERROR, outcome.firstFailure)
        assertNull(outcome.retryFailure)
        assertTrue(outcome.recoveryAttempted)
        assertTrue(outcome.retried)
        assertEquals(1, clears)
        // The retry only gets what is left of the caller's deadline.
        assertEquals(listOf(5_000, 5_000 - 1_800 - 20), reads)
    }

    @Test
    fun `a read that used its whole timeout is a timeout and is not retried`() {
        val clock = FakeClock()
        var reads = 0
        var clears = 0
        val outcome =
            recoverDeadBulkInRead(
                isClosed = { false },
                canRecover = true,
                timeoutMillis = 5_000,
                nowMillis = { clock.now },
                read = { reads += 1; clock.advance(5_002); -1 },
                clearHalt = { clears += 1 },
            )

        assertEquals(-1, outcome.byteCount)
        assertEquals(UsbBulkInFailure.TIMEOUT, outcome.firstFailure)
        assertFalse(outcome.recoveryAttempted)
        assertEquals(1, reads)
        assertEquals(0, clears)
    }

    @Test
    fun `a read that ends just short of its timeout still counts as a timeout`() {
        assertEquals(UsbBulkInFailure.TIMEOUT, classifyBulkInFailure(elapsedMillis = 4_980, timeoutMillis = 5_000))
        assertEquals(UsbBulkInFailure.ERROR, classifyBulkInFailure(elapsedMillis = 2_200, timeoutMillis = 5_000))
        assertEquals(UsbBulkInFailure.ERROR, classifyBulkInFailure(elapsedMillis = 0, timeoutMillis = 200))
    }

    @Test
    fun `an error with no recovery left is classified but not retried`() {
        val clock = FakeClock()
        var reads = 0
        var clears = 0
        val outcome =
            recoverDeadBulkInRead(
                isClosed = { false },
                canRecover = false,
                timeoutMillis = 5_000,
                nowMillis = { clock.now },
                read = { reads += 1; clock.advance(10); -1 },
                clearHalt = { clears += 1 },
            )

        assertEquals(-1, outcome.byteCount)
        assertEquals(UsbBulkInFailure.ERROR, outcome.firstFailure)
        assertFalse(outcome.recoveryAttempted)
        assertEquals(1, reads)
        assertEquals(0, clears)
    }

    @Test
    fun `an error too close to the deadline is not retried past it`() {
        val clock = FakeClock()
        var reads = 0
        var clears = 0
        val outcome =
            recoverDeadBulkInRead(
                isClosed = { false },
                canRecover = true,
                timeoutMillis = 5_000,
                nowMillis = { clock.now },
                read = { reads += 1; clock.advance(4_920); -1 },
                clearHalt = { clears += 1 },
            )

        assertEquals(-1, outcome.byteCount)
        assertEquals(UsbBulkInFailure.ERROR, outcome.firstFailure)
        assertFalse(outcome.retried)
        assertEquals(1, reads)
        assertEquals(0, clears)
    }

    @Test
    fun `the pipe clear gets a share of the remaining time, never more`() {
        val clock = FakeClock()
        val budgets = mutableListOf<Int>()
        recoverDeadBulkInRead(
            isClosed = { false },
            canRecover = true,
            timeoutMillis = 1_000,
            nowMillis = { clock.now },
            read = { clock.advance(700); -1 },
            clearHalt = { budget -> budgets += budget },
        )

        assertEquals(1, budgets.size)
        assertTrue(budgets.single() in 1..300, "clear budget ${budgets.single()} exceeds what is left")
    }

    @Test
    fun `a retry that also fails reports how it failed`() {
        val clock = FakeClock()
        var reads = 0
        val outcome =
            recoverDeadBulkInRead(
                isClosed = { false },
                canRecover = true,
                timeoutMillis = 5_000,
                nowMillis = { clock.now },
                read = { timeout ->
                    reads += 1
                    clock.advance(if (reads == 1) 5L else timeout.toLong())
                    -1
                },
                clearHalt = {},
            )

        assertEquals(-1, outcome.byteCount)
        assertEquals(UsbBulkInFailure.ERROR, outcome.firstFailure)
        assertEquals(UsbBulkInFailure.TIMEOUT, outcome.retryFailure)
        assertTrue(outcome.recoveryAttempted)
        assertTrue(outcome.retried)
        assertEquals(2, reads)
    }

    @Test
    fun `a closed connection never reads or clears`() {
        var reads = 0
        var clears = 0
        val outcome =
            recoverDeadBulkInRead(
                isClosed = { true },
                canRecover = true,
                timeoutMillis = 5_000,
                nowMillis = { 0L },
                read = { reads += 1; 512 },
                clearHalt = { clears += 1 },
            )

        assertEquals(-1, outcome.byteCount)
        assertFalse(outcome.recoveryAttempted)
        assertEquals(0, reads)
        assertEquals(0, clears)
    }

    @Test
    fun `closing during the pipe clear skips the retry`() {
        val clock = FakeClock()
        var closed = false
        var reads = 0
        val outcome =
            recoverDeadBulkInRead(
                isClosed = { closed },
                canRecover = true,
                timeoutMillis = 5_000,
                nowMillis = { clock.now },
                read = { reads += 1; clock.advance(10); -1 },
                clearHalt = { closed = true },
            )

        assertEquals(-1, outcome.byteCount)
        assertTrue(outcome.recoveryAttempted)
        assertFalse(outcome.retried)
        assertEquals(1, reads)
    }

    @Test
    fun `each failure kind and the recovery have their own diagnostic phase`() {
        val phases =
            listOf(
                UsbBulkInFailure.TIMEOUT.diagnosticPhase,
                UsbBulkInFailure.ERROR.diagnosticPhase,
                USB_BULK_IN_RECOVERED_PHASE,
            )
        assertEquals(phases.size, phases.toSet().size)
    }
}
