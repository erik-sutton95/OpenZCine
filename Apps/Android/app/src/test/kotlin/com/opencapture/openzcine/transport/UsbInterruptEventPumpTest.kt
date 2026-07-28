package com.opencapture.openzcine.transport

import java.nio.BufferOverflowException
import java.nio.ByteBuffer
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.TimeoutException
import kotlin.concurrent.thread
import kotlin.test.Test
import kotlin.test.assertContentEquals
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNull
import kotlin.test.assertTrue

/**
 * Models AOSP's `UsbRequest` / `UsbDeviceConnection` pair for one interrupt-IN
 * request, including the semantics the crash in issue #270 turned on:
 * `cancel()` never clears the queued flag. Only a completion handed back by
 * [awaitCompletion] — the framework's `requestWait` calling `dequeue` — clears
 * it, and queueing again while it is set throws the framework's own
 * `IllegalStateException("this request is currently queued")`.
 */
private class FakeInterruptChannel : UsbInterruptChannel {
    /** One scripted outcome for a single `requestWait` call. */
    sealed interface Completion {
        /** The framework returns our own request; [payload] lands in its buffer. */
        class Own(val payload: ByteArray) : Completion

        /** `requestWait` returned a request belonging to something else. */
        data object Foreign : Completion

        /** `requestWait` returned null because the framework reported an error. */
        data object Error : Completion

        /** Nothing completed in time; the transfer stays queued. */
        data object Timeout : Completion

        /** `dequeue` overflowed the buffer: already dequeued, payload lost. */
        data object Overflow : Completion

        /** `requestWait` threw something else entirely. */
        class Failure(val error: Throwable) : Completion
    }

    private val scripted = ArrayDeque<Completion>()
    private var queued: ByteBuffer? = null

    /** Gate used by the close/read race test to park a reader inside the wait. */
    private var gateWaits: Boolean = false
    private val waitEntered = CountDownLatch(1)
    private val waitReleased = CountDownLatch(1)

    var connectionOpen: Boolean = true
    var queueAttempts: Int = 0
        private set
    var cancelCount: Int = 0
        private set
    var waitCount: Int = 0
        private set
    var closeCount: Int = 0
        private set

    /** Queue calls the framework rejected. The crash. Must stay at zero. */
    var illegalQueueAttempts: Int = 0
        private set

    val isQueued: Boolean
        get() = queued != null

    fun script(vararg completions: Completion) {
        scripted.addAll(completions)
    }

    /** Parks every wait until [cancel] arrives, as a real blocked `requestWait` does. */
    fun parkWaitsUntilCancelled() {
        gateWaits = true
    }

    fun awaitParkedReader(): Boolean = waitEntered.await(5, TimeUnit.SECONDS)

    override fun queue(buffer: ByteBuffer): Boolean {
        queueAttempts += 1
        if (queued != null) {
            illegalQueueAttempts += 1
            throw IllegalStateException("this request is currently queued")
        }
        if (!connectionOpen) return false
        queued = buffer
        return true
    }

    override fun cancel() {
        cancelCount += 1
        // AOSP only asks the kernel to discard the URB here; the queued flag
        // survives until the aborted transfer is reaped by a wait.
        waitReleased.countDown()
    }

    override fun awaitCompletion(timeoutMillis: Long): Boolean {
        waitCount += 1
        if (gateWaits) {
            waitEntered.countDown()
            waitReleased.await(5, TimeUnit.SECONDS)
        }
        return when (val completion = scripted.removeFirstOrNull() ?: Completion.Timeout) {
            is Completion.Own -> {
                val buffer = requireNotNull(queued) { "nothing was queued to complete" }
                buffer.put(completion.payload)
                queued = null
                true
            }
            Completion.Foreign, Completion.Error -> false
            Completion.Timeout -> throw TimeoutException("no completion")
            Completion.Overflow -> {
                // `dequeue` clears the framework flag before it throws.
                queued = null
                throw BufferOverflowException()
            }
            is Completion.Failure -> throw completion.error
        }
    }

    override fun close() {
        closeCount += 1
        connectionOpen = false
    }
}

/**
 * Deterministic coverage for the interrupt-event request lifecycle behind the
 * Play Console crash in issue #270 (`IllegalStateException: this request is
 * currently queued`). Every test asserts the framework was never asked to queue
 * a transfer it still owned.
 */
class UsbInterruptEventPumpTest {
    private val channel = FakeInterruptChannel()

    private fun primedPump(): UsbInterruptEventPump =
        UsbInterruptEventPump(channel).also { it.prime(PRIMED_BYTES) }

    @Test
    fun `priming queues the interrupt read before the event pump asks for one`() {
        primedPump()

        // Nikon bodies only emit events while a transfer is outstanding, and the
        // ZR stalls its switch into application mode until this one is drained.
        assertEquals(1, channel.queueAttempts)
        assertTrue(channel.isQueued)
        assertEquals(0, channel.waitCount)
    }

    @Test
    fun `consecutive timeouts retain the exact queued request and buffer`() {
        val pump = primedPump()
        val payload = byteArrayOf(4, 0, 0, 0)
        channel.script(
            FakeInterruptChannel.Completion.Timeout,
            FakeInterruptChannel.Completion.Timeout,
            FakeInterruptChannel.Completion.Own(payload),
        )

        assertContentEquals(ByteArray(0), pump.read(READ_BYTES, TIMEOUT_MILLIS))
        assertContentEquals(ByteArray(0), pump.read(READ_BYTES, TIMEOUT_MILLIS))
        assertContentEquals(payload, pump.read(READ_BYTES, TIMEOUT_MILLIS))

        assertEquals(1, channel.queueAttempts)
        assertEquals(0, channel.cancelCount)
        assertEquals(0, channel.illegalQueueAttempts)
    }

    @Test
    fun `a delivered event lets the next read queue exactly one fresh transfer`() {
        val pump = primedPump()
        channel.script(
            FakeInterruptChannel.Completion.Own(byteArrayOf(1, 2, 3)),
            FakeInterruptChannel.Completion.Timeout,
        )

        assertContentEquals(byteArrayOf(1, 2, 3), pump.read(READ_BYTES, TIMEOUT_MILLIS))
        assertContentEquals(ByteArray(0), pump.read(READ_BYTES, TIMEOUT_MILLIS))

        assertEquals(2, channel.queueAttempts)
        assertEquals(0, channel.illegalQueueAttempts)
    }

    @Test
    fun `an error completion is cancelled and reaped before the next read queues`() {
        val pump = primedPump()
        channel.script(
            FakeInterruptChannel.Completion.Error,
            FakeInterruptChannel.Completion.Own(ByteArray(0)),
            FakeInterruptChannel.Completion.Timeout,
        )

        assertNull(pump.read(READ_BYTES, TIMEOUT_MILLIS))
        assertEquals(1, channel.cancelCount)
        assertFalse(channel.isQueued)
        assertFalse(pump.isRetired())

        assertContentEquals(ByteArray(0), pump.read(READ_BYTES, TIMEOUT_MILLIS))
        assertEquals(2, channel.queueAttempts)
        assertEquals(0, channel.illegalQueueAttempts)
    }

    @Test
    fun `an unexpected foreign completion is reaped before the next read queues`() {
        val pump = primedPump()
        channel.script(
            FakeInterruptChannel.Completion.Foreign,
            FakeInterruptChannel.Completion.Own(ByteArray(0)),
            FakeInterruptChannel.Completion.Timeout,
        )

        assertNull(pump.read(READ_BYTES, TIMEOUT_MILLIS))
        assertContentEquals(ByteArray(0), pump.read(READ_BYTES, TIMEOUT_MILLIS))

        assertEquals(1, channel.cancelCount)
        assertEquals(2, channel.queueAttempts)
        assertEquals(0, channel.illegalQueueAttempts)
    }

    @Test
    fun `a wait that throws is reaped before the next read queues`() {
        val pump = primedPump()
        channel.script(
            FakeInterruptChannel.Completion.Failure(RuntimeException("usb went sideways")),
            FakeInterruptChannel.Completion.Own(ByteArray(0)),
            FakeInterruptChannel.Completion.Timeout,
        )

        assertNull(pump.read(READ_BYTES, TIMEOUT_MILLIS))
        assertContentEquals(ByteArray(0), pump.read(READ_BYTES, TIMEOUT_MILLIS))

        assertEquals(1, channel.cancelCount)
        assertEquals(2, channel.queueAttempts)
        assertEquals(0, channel.illegalQueueAttempts)
    }

    @Test
    fun `a cancellation that does not reap immediately still never re-queues`() {
        val pump = primedPump()
        channel.script(
            FakeInterruptChannel.Completion.Error,
            // The abort takes a few reap attempts to come back, exactly as a
            // discarded URB can. Cancelling did not clear the queued flag.
            FakeInterruptChannel.Completion.Timeout,
            FakeInterruptChannel.Completion.Timeout,
            FakeInterruptChannel.Completion.Own(ByteArray(0)),
            FakeInterruptChannel.Completion.Timeout,
        )

        assertNull(pump.read(READ_BYTES, TIMEOUT_MILLIS))
        assertFalse(pump.isRetired())
        assertFalse(channel.isQueued)

        assertContentEquals(ByteArray(0), pump.read(READ_BYTES, TIMEOUT_MILLIS))
        assertEquals(2, channel.queueAttempts)
        assertEquals(0, channel.illegalQueueAttempts)
    }

    @Test
    fun `a cancellation that never reaps retires the pump instead of re-queueing`() {
        val pump = primedPump()
        // Only the error; every later wait times out, so the abort never returns.
        channel.script(FakeInterruptChannel.Completion.Error)

        assertNull(pump.read(READ_BYTES, TIMEOUT_MILLIS))
        assertTrue(pump.isRetired())
        assertTrue(channel.isQueued)

        assertNull(pump.read(READ_BYTES, TIMEOUT_MILLIS))
        assertNull(pump.read(READ_BYTES, TIMEOUT_MILLIS))
        assertEquals(1, channel.queueAttempts)
        assertEquals(0, channel.illegalQueueAttempts)
    }

    @Test
    fun `an overflowed dequeue drops the event without cancelling or retiring`() {
        val pump = primedPump()
        channel.script(
            FakeInterruptChannel.Completion.Overflow,
            FakeInterruptChannel.Completion.Timeout,
        )

        assertContentEquals(ByteArray(0), pump.read(READ_BYTES, TIMEOUT_MILLIS))
        assertFalse(pump.isRetired())
        assertEquals(0, channel.cancelCount)

        assertContentEquals(ByteArray(0), pump.read(READ_BYTES, TIMEOUT_MILLIS))
        assertEquals(2, channel.queueAttempts)
        assertEquals(0, channel.illegalQueueAttempts)
    }

    @Test
    fun `a refused queue on a detached device retires instead of throwing`() {
        channel.connectionOpen = false
        val pump = primedPump()

        assertTrue(pump.isRetired())
        assertNull(pump.read(READ_BYTES, TIMEOUT_MILLIS))
        assertEquals(1, channel.queueAttempts)
        assertEquals(0, channel.illegalQueueAttempts)
    }

    @Test
    fun `a device detached mid-session retires on the next queue`() {
        val pump = primedPump()
        channel.script(FakeInterruptChannel.Completion.Own(byteArrayOf(9)))

        assertContentEquals(byteArrayOf(9), pump.read(READ_BYTES, TIMEOUT_MILLIS))
        channel.connectionOpen = false

        assertNull(pump.read(READ_BYTES, TIMEOUT_MILLIS))
        assertTrue(pump.isRetired())
        assertEquals(2, channel.queueAttempts)
        assertEquals(0, channel.illegalQueueAttempts)
    }

    @Test
    fun `shutdown aborts the transfer and no later read queues another`() {
        val pump = primedPump()

        pump.shutdown()
        pump.release()

        assertEquals(1, channel.cancelCount)
        assertEquals(1, channel.closeCount)
        assertTrue(pump.isRetired())
        assertNull(pump.read(READ_BYTES, TIMEOUT_MILLIS))
        assertEquals(1, channel.queueAttempts)
        assertEquals(0, channel.illegalQueueAttempts)
    }

    @Test
    fun `teardown racing a parked read cannot queue behind the close`() {
        val pump = primedPump()
        channel.parkWaitsUntilCancelled()
        // The abort comes back as the reader's own completion, as a discarded
        // URB does, so the reader returns bytes and then must not queue again.
        channel.script(FakeInterruptChannel.Completion.Own(byteArrayOf(7)))

        var readResult: ByteArray? = null
        val reader = thread { readResult = pump.read(READ_BYTES, TIMEOUT_MILLIS) }
        assertTrue(channel.awaitParkedReader(), "reader never entered the wait")

        pump.shutdown()
        reader.join(5_000)
        pump.release()

        assertContentEquals(byteArrayOf(7), readResult)
        assertTrue(pump.isRetired())
        assertNull(pump.read(READ_BYTES, TIMEOUT_MILLIS))
        assertEquals(1, channel.queueAttempts)
        assertEquals(0, channel.illegalQueueAttempts)
    }

    @Test
    fun `a replacement session queues on its own request while the old one stays retired`() {
        // Detach/reattach and rapid reconnect both build a new transport, and
        // therefore a new UsbRequest — no lifecycle state may be shared.
        val detached = primedPump()
        detached.shutdown()
        detached.release()

        val reattached = FakeInterruptChannel()
        val pump = UsbInterruptEventPump(reattached).also { it.prime(PRIMED_BYTES) }
        reattached.script(FakeInterruptChannel.Completion.Own(byteArrayOf(5, 5)))

        assertContentEquals(byteArrayOf(5, 5), pump.read(READ_BYTES, TIMEOUT_MILLIS))
        assertNull(detached.read(READ_BYTES, TIMEOUT_MILLIS))

        assertEquals(1, channel.queueAttempts)
        assertEquals(1, reattached.queueAttempts)
        assertEquals(0, channel.illegalQueueAttempts)
        assertEquals(0, reattached.illegalQueueAttempts)
    }

    private companion object {
        const val PRIMED_BYTES: Int = 512
        const val READ_BYTES: Int = 16 * 1024
        const val TIMEOUT_MILLIS: Int = 1_000
    }
}
