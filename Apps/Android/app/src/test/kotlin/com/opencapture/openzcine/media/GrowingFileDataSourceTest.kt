package com.opencapture.openzcine.media

import androidx.media3.common.C
import java.io.IOException
import java.io.InterruptedIOException
import java.nio.channels.ClosedChannelException
import java.nio.file.Files
import java.nio.file.Path
import java.util.concurrent.ExecutionException
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors
import java.util.concurrent.Future
import java.util.concurrent.TimeUnit
import java.util.concurrent.TimeoutException
import kotlin.io.path.createTempDirectory
import kotlin.test.Test
import kotlin.test.assertContentEquals
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import kotlin.test.assertIs

/** Host-side behavior of Media3 reads over a progressively growing local file. */
class GrowingFileDataSourceTest {
    @Test
    fun `read waits at temporary EOF and resumes when bytes are appended`() =
        withEntry(expectedLength = 3) { entry ->
            val source = GrowingFileDataSource(entry)
            assertEquals(3, source.openAt(0))
            withExecutor { executor ->
                val result = executor.submitRead(source, 3)
                assertStillWaiting(result)

                entry.append(0, byteArrayOf(1, 2, 3))

                val read = result.get(2, TimeUnit.SECONDS)
                assertEquals(3, read.count)
                assertContentEquals(byteArrayOf(1, 2, 3), read.bytes)
            }
            source.close()
        }

    @Test
    fun `opening at a seek position reads from that absolute byte`() =
        withEntry(expectedLength = 6) { entry ->
            entry.append(0, "abcdef".encodeToByteArray())
            val source = GrowingFileDataSource(entry)
            assertEquals(3, source.openAt(3))
            val buffer = ByteArray(3)

            val count = source.read(buffer, 0, buffer.size)

            assertEquals(3, count)
            assertContentEquals("def".encodeToByteArray(), buffer)
            source.close()
        }

    @Test
    fun `completed entry returns EOF only after all requested bytes are read`() =
        withEntry(expectedLength = 3) { entry ->
            entry.append(0, byteArrayOf(4, 5, 6))
            entry.complete()
            val source = GrowingFileDataSource(entry)
            source.openAt(0)
            val buffer = ByteArray(3)

            assertEquals(3, source.read(buffer, 0, buffer.size))
            assertContentEquals(byteArrayOf(4, 5, 6), buffer)
            assertEquals(C.RESULT_END_OF_INPUT, source.read(buffer, 0, buffer.size))
            source.close()
        }

    @Test
    fun `explicit data length returns EOF without waiting for the full object`() =
        withEntry(expectedLength = 6) { entry ->
            entry.append(0, "abcdef".encodeToByteArray())
            val source = GrowingFileDataSource(entry)
            assertEquals(2, source.openAt(position = 2, length = 2))
            val buffer = ByteArray(4)

            assertEquals(2, source.read(buffer, 0, buffer.size))
            assertContentEquals("cd".encodeToByteArray(), buffer.copyOf(2))
            assertEquals(C.RESULT_END_OF_INPUT, source.read(buffer, 0, buffer.size))
            source.close()
        }

    @Test
    fun `transfer failure wakes a reader blocked at temporary EOF`() =
        withEntry(expectedLength = 3) { entry ->
            val source = GrowingFileDataSource(entry)
            source.openAt(0)
            withExecutor { executor ->
                val result = executor.submitRead(source, 1)
                assertStillWaiting(result)

                entry.fail(IOException("camera disconnected"))

                val cause = assertFutureFailure(result)
                assertIs<IOException>(cause)
                assertEquals("Camera media transfer failed.", cause.message)
                assertEquals("camera disconnected", cause.cause?.message)
            }
            source.close()
        }

    @Test
    fun `transfer cancellation wakes a reader blocked at temporary EOF`() =
        withEntry(expectedLength = 3) { entry ->
            val source = GrowingFileDataSource(entry)
            source.openAt(0)
            withExecutor { executor ->
                val result = executor.submitRead(source, 1)
                assertStillWaiting(result)

                entry.cancel()

                assertIs<InterruptedIOException>(assertFutureFailure(result))
            }
            source.close()
        }

    @Test
    fun `closing the data source releases a blocked reader without cancelling the transfer`() =
        withEntry(expectedLength = 3) { entry ->
            val source = GrowingFileDataSource(entry)
            source.openAt(0)
            withExecutor { executor ->
                val result = executor.submitRead(source, 1)
                assertStillWaiting(result)

                source.close()

                assertIs<ClosedChannelException>(assertFutureFailure(result))
                assertEquals(MediaCacheState.ACTIVE, entry.state)
            }
        }

    private fun withEntry(expectedLength: Long, block: (MediaCacheEntry) -> Unit) {
        val root = createTempDirectory("openzcine-growing-source")
        try {
            val entry = MediaCacheStore(root).openEntry("camera", "CLIP.MOV", expectedLength)
            block(entry)
        } finally {
            deleteTree(root)
        }
    }

    private fun ExecutorService.submitRead(
        source: GrowingFileDataSource,
        byteCount: Int,
    ): Future<ReadResult> =
        submit<ReadResult> {
            val bytes = ByteArray(byteCount)
            ReadResult(source.read(bytes, 0, byteCount), bytes)
        }

    private fun assertStillWaiting(result: Future<ReadResult>) {
        assertFailsWith<TimeoutException> { result.get(100, TimeUnit.MILLISECONDS) }
    }

    private fun assertFutureFailure(result: Future<ReadResult>): Throwable {
        val wrapper = assertFailsWith<ExecutionException> { result.get(2, TimeUnit.SECONDS) }
        return wrapper.cause ?: error("Future failed without a cause.")
    }

    private fun withExecutor(block: (ExecutorService) -> Unit) {
        val executor = Executors.newSingleThreadExecutor()
        try {
            block(executor)
        } finally {
            executor.shutdownNow()
            executor.awaitTermination(2, TimeUnit.SECONDS)
        }
    }

    private fun deleteTree(root: Path) {
        if (!Files.exists(root)) return
        Files.walk(root).use { paths ->
            paths.sorted(Comparator.reverseOrder()).forEach(Files::deleteIfExists)
        }
    }

    private data class ReadResult(val count: Int, val bytes: ByteArray)
}
