package com.opencapture.openzcine.gyro

import java.io.File
import java.nio.file.Files
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.Job
import kotlinx.coroutines.cancel
import kotlinx.coroutines.test.StandardTestDispatcher
import kotlinx.coroutines.test.TestCoroutineScheduler
import kotlinx.coroutines.test.resetMain
import kotlinx.coroutines.test.setMain
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

@OptIn(ExperimentalCoroutinesApi::class)
class GyroLogSharingTest {
    @Test fun `copy waits for IO and chooser returns to Main with read custody`() = fixture { f ->
        var shared: File? = null
        f.share(onReady = { shared = it })
        f.main.runCurrent()
        assertTrue(f.cache.listFiles().isNullOrEmpty())
        assertEquals(null, shared)
        f.io.runCurrent()
        assertEquals(null, shared)
        f.main.runCurrent()
        val first = requireNotNull(shared)
        assertTrue(first.canonicalPath.startsWith(File(f.cache, "share/ready/gyro").canonicalPath + File.separator))
        assertEquals("finalized gyro bytes", first.readText())
        first.inputStream().use { reader ->
            f.share(onReady = { shared = it })
            f.drain()
            val second = requireNotNull(shared)
            assertFalse(first == second)
            assertEquals("finalized gyro bytes", reader.bufferedReader().readText())
            assertEquals("finalized gyro bytes", second.readText())
            f.scope.cancel()
            f.drain()
            assertTrue(first.isFile)
            assertTrue(second.isFile)
        }
        assertEquals("finalized gyro bytes", f.source.readText())
    }

    @Test fun `activity retirement after IO suppresses chooser and removes unshared copy`() = fixture { f ->
        var presented = false
        var failed = false
        val job = f.share(onReady = { presented = true }, onFailure = { failed = true })
        f.main.runCurrent()
        f.io.runCurrent()
        assertTrue(f.cache.walkTopDown().any { it.isFile })
        f.scope.cancel()
        f.drain()
        assertTrue(job.isCancelled)
        assertFalse(presented)
        assertFalse(failed)
        assertFalse(f.cache.walkTopDown().any { it.isFile })
        assertEquals("finalized gyro bytes", f.source.readText())
    }

    @Test fun `cancellation before IO leaves no share artifact or callbacks`() = fixture { f ->
        var called = false
        val job = f.share(onReady = { called = true }, onFailure = { called = true })
        f.main.runCurrent()
        f.scope.cancel()
        f.drain()
        assertTrue(job.isCancelled)
        assertFalse(called)
        assertFalse(f.cache.walkTopDown().any { it.isFile })
    }

    @Test fun `copy failure is reported on Main and removes its staging directory`() = fixture { f ->
        assertTrue(f.source.delete())
        var failure: Exception? = null
        f.share(onReady = { error("A missing log must not reach the chooser.") }, onFailure = { failure = it })
        f.main.runCurrent()
        f.io.runCurrent()
        assertEquals(null, failure)
        f.drain()
        assertTrue(failure is java.io.IOException)
        assertFalse(f.cache.walkTopDown().any { it.isFile })
        assertTrue(File(f.cache, "share/staging/gyro").listFiles().isNullOrEmpty())
    }

    @Test fun `retired activity receives no delayed copy error`() = fixture { f ->
        assertTrue(f.source.delete())
        var called = false
        val job = f.share(onReady = { called = true }, onFailure = { called = true })
        f.main.runCurrent()
        f.io.runCurrent()
        f.scope.cancel()
        f.drain()
        assertTrue(job.isCancelled)
        assertFalse(called)
        assertFalse(f.cache.walkTopDown().any { it.isFile })
    }

    @Test fun `chooser failure reports the error and retires only its unpublished copy`() = fixture { f ->
        val failure = IllegalStateException("No share activity")
        var reported: Exception? = null
        f.share(onReady = { throw failure }, onFailure = { reported = it })
        f.drain()
        assertTrue(reported === failure)
        assertFalse(f.cache.walkTopDown().any { it.isFile })
        assertEquals("finalized gyro bytes", f.source.readText())
    }

    @Test fun `active and incomplete logs cannot be staged`() = fixture { f ->
        var failures = 0
        for (entry in listOf(f.entry.copy(active = true), f.entry.copy(summary = null))) {
            f.share(entry, onReady = { error("Unfinalized log reached chooser.") }, onFailure = { failures++ })
        }
        f.drain()
        assertEquals(2, failures)
        assertTrue(f.cache.listFiles().isNullOrEmpty())
        assertEquals("finalized gyro bytes", f.source.readText())
    }

    private fun fixture(body: (Fixture) -> Unit) {
        val f = Fixture()
        Dispatchers.setMain(StandardTestDispatcher(f.main))
        try { body(f) } finally {
            f.scope.cancel()
            f.drain()
            Dispatchers.resetMain()
            f.root.deleteRecursively()
        }
    }

    private class Fixture {
        val root: File = Files.createTempDirectory("gyro-share-test").toFile()
        val cache = File(root, "cache").apply { mkdirs() }
        val source = File(root, "take.gcsv").apply { writeText("finalized gyro bytes") }
        val entry = GyroLogEntry(JSONObject(), JSONObject(), source)
        val main = TestCoroutineScheduler()
        val io = TestCoroutineScheduler()
        val scope = CoroutineScope(Job() + StandardTestDispatcher(main))

        fun share(entry: GyroLogEntry = this.entry, onReady: (File) -> Unit,
            onFailure: (Exception) -> Unit = { throw AssertionError("Unexpected share failure", it) }): Job =
            shareGyroLog(scope, cache, entry, onReady, onFailure, StandardTestDispatcher(io))

        fun drain() { repeat(3) { main.runCurrent(); io.runCurrent() }; main.runCurrent() }
    }
}
