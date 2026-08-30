package com.opencapture.openzcine.transport

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertTrue

/**
 * The Z 6III OnePlus 15 reconnect (Discussion #12): bulk-out returns -1 for the
 * 12-byte GetDeviceInfo container even when GET_DEVICE_STATUS reads OK. Reset
 * without retrying this write made every reconnect fail in the UI.
 */
class UsbPtpDeadWriteRecoveryTest {
    @Test
    fun `a healthy write is returned and never resets`() {
        var writes = 0
        var resets = 0
        val outcome =
            recoverDeadBulkOutWrite(
                isClosed = { false },
                alreadyRecovered = false,
                write = {
                    writes += 1
                    12
                },
                reset = { resets += 1 },
            )

        assertEquals(12, outcome.byteCount)
        assertFalse(outcome.recoveryAttempted)
        assertFalse(outcome.retried)
        assertEquals(1, writes)
        assertEquals(0, resets)
    }

    @Test
    fun `a dead write resets once and retries the same transfer`() {
        val writes = mutableListOf<Int>()
        var resets = 0
        val outcome =
            recoverDeadBulkOutWrite(
                isClosed = { false },
                alreadyRecovered = false,
                write = {
                    val result = if (writes.isEmpty()) -1 else 12
                    writes += result
                    result
                },
                reset = { resets += 1 },
            )

        assertEquals(12, outcome.byteCount)
        assertTrue(outcome.recoveryAttempted)
        assertTrue(outcome.retried)
        assertEquals(listOf(-1, 12), writes)
        assertEquals(1, resets)
    }

    @Test
    fun `a second dead write does not reset again`() {
        var writes = 0
        var resets = 0
        val outcome =
            recoverDeadBulkOutWrite(
                isClosed = { false },
                alreadyRecovered = true,
                write = {
                    writes += 1
                    -1
                },
                reset = { resets += 1 },
            )

        assertEquals(-1, outcome.byteCount)
        assertTrue(outcome.recoveryAttempted)
        assertFalse(outcome.retried)
        assertEquals(1, writes)
        assertEquals(0, resets)
    }

    @Test
    fun `a closed connection never writes or resets`() {
        var writes = 0
        var resets = 0
        val outcome =
            recoverDeadBulkOutWrite(
                isClosed = { true },
                alreadyRecovered = false,
                write = {
                    writes += 1
                    12
                },
                reset = { resets += 1 },
            )

        assertEquals(-1, outcome.byteCount)
        assertFalse(outcome.recoveryAttempted)
        assertFalse(outcome.retried)
        assertEquals(0, writes)
        assertEquals(0, resets)
    }

    @Test
    fun `closing during reset still reports failure after the one-shot recovery`() {
        var closed = false
        var writes = 0
        val outcome =
            recoverDeadBulkOutWrite(
                isClosed = { closed },
                alreadyRecovered = false,
                write = {
                    writes += 1
                    -1
                },
                reset = { closed = true },
            )

        assertEquals(-1, outcome.byteCount)
        assertTrue(outcome.recoveryAttempted)
        assertTrue(outcome.retried)
        assertEquals(1, writes)
    }
}
