package com.opencapture.openzcine.media

import java.io.IOException
import java.nio.file.Files
import java.nio.file.Path
import kotlin.io.path.createTempDirectory
import kotlin.test.Test
import kotlin.test.assertContentEquals
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import kotlin.test.assertFalse
import kotlin.test.assertNotEquals
import kotlin.test.assertSame
import kotlin.test.assertTrue

/** Host-side coverage for cache paths, resumption, validation, and finalization. */
class MediaCacheStoreTest {
    @Test
    fun `paths stay contained and stable while unsafe filenames are rejected`() =
        withStore { root, store ->
            val first = store.openEntry("ZR serial/with separators", "C0001.MOV", 8)
            val second = store.openEntry("ZR serial/with separators", "C0001.MOV", 8)

            assertSame(first, second)
            assertTrue(first.partialPath.startsWith(root))
            assertTrue(first.finalPath.startsWith(root))
            assertEquals(first.partialPath.parent, first.finalPath.parent)
            assertFalse(first.finalPath.toString().contains("ZR serial"))

            listOf("", ".", "..", "../clip.mov", "/clip.mov", "folder/clip.mov", "folder\\clip.mov")
                .forEach { filename ->
                    assertFailsWith<UnsafeMediaCacheFilenameException> {
                        store.openEntry("camera", filename, 1)
                    }
                }
        }

    @Test
    fun `same-named clips on different objects never share cached footage`() =
        withStore { _, store ->
            val first =
                store.openEntry(
                    "camera",
                    MediaCacheObjectIdentity(
                        storageId = 0x0001_0001L,
                        handle = 42L,
                        captureDate = "20260714T120000",
                        filename = "C0001.MOV",
                    ),
                    3,
                )
            val otherStorage =
                store.openEntry(
                    "camera",
                    MediaCacheObjectIdentity(
                        storageId = 0x0002_0001L,
                        handle = 42L,
                        captureDate = "20260714T120000",
                        filename = "C0001.MOV",
                    ),
                    3,
                )
            val reusedName =
                store.openEntry(
                    "camera",
                    MediaCacheObjectIdentity(
                        storageId = 0x0001_0001L,
                        handle = 99L,
                        captureDate = "20260715T120000",
                        filename = "C0001.MOV",
                    ),
                    3,
                )

            first.append(0, byteArrayOf(1, 2, 3))
            first.complete()

            assertNotEquals(first.finalPath, otherStorage.finalPath)
            assertNotEquals(first.finalPath, reusedName.finalPath)
            assertEquals(0, otherStorage.downloadedBytes)
            assertEquals(MediaCacheState.ACTIVE, reusedName.state)
        }

    @Test
    fun `existing partial file resumes at its exact byte length`() =
        withStore { root, store ->
            val first = store.openEntry("camera", "C0002.MOV", 6)
            first.append(0, byteArrayOf(1, 2, 3))

            val resumed = MediaCacheStore(root).openEntry("camera", "C0002.MOV", 6)

            assertEquals(3, resumed.downloadedBytes)
            resumed.append(3, byteArrayOf(4, 5, 6))
            assertContentEquals(byteArrayOf(1, 2, 3, 4, 5, 6), Files.readAllBytes(resumed.partialPath))
        }

    @Test
    fun `append rejects a non-sequential transfer offset`() =
        withStore { _, store ->
            val entry = store.openEntry("camera", "C0003.MOV", 4)
            entry.append(0, byteArrayOf(1, 2))

            val error =
                assertFailsWith<MediaCacheOffsetException> {
                    entry.append(1, byteArrayOf(3))
                }

            assertEquals(2, error.expectedOffset)
            assertEquals(1, error.actualOffset)
            assertEquals(2, entry.downloadedBytes)
        }

    @Test
    fun `append publishes bytes and progress without exceeding expected length`() =
        withStore { _, store ->
            val entry = store.openEntry("camera", "C0004.MOV", 8)

            entry.append(0, byteArrayOf(1, 2))
            entry.append(2, byteArrayOf(3, 4))

            assertEquals(4, entry.downloadedBytes)
            assertEquals(0.5, entry.progress)
            assertContentEquals(byteArrayOf(1, 2, 3, 4), Files.readAllBytes(entry.partialPath))
            assertFailsWith<MediaCacheLengthException> {
                entry.append(4, ByteArray(5))
            }
        }

    @Test
    fun `completion validates length and atomically publishes the final file`() =
        withStore { root, store ->
            val entry = store.openEntry("camera", "C0005.MOV", 4)
            val bytes = byteArrayOf(9, 8, 7, 6)
            entry.append(0, bytes)

            entry.complete()

            assertEquals(MediaCacheState.COMPLETE, entry.state)
            assertEquals(1.0, entry.progress)
            assertFalse(Files.exists(entry.partialPath))
            assertTrue(Files.exists(entry.finalPath))
            assertContentEquals(bytes, Files.readAllBytes(entry.finalPath))

            val reopened = MediaCacheStore(root).openEntry("camera", "C0005.MOV", 4)
            assertEquals(MediaCacheState.COMPLETE, reopened.state)
            assertEquals(4, reopened.downloadedBytes)
        }

    @Test
    fun `completion rejects a short temporary file`() =
        withStore { _, store ->
            val entry = store.openEntry("camera", "C0006.MOV", 5)
            entry.append(0, byteArrayOf(1, 2, 3))

            val error = assertFailsWith<MediaCacheLengthException> { entry.complete() }

            assertEquals(5, error.expectedLength)
            assertEquals(3, error.actualLength)
            assertEquals(MediaCacheState.ACTIVE, entry.state)
            assertTrue(Files.exists(entry.partialPath))
            assertFalse(Files.exists(entry.finalPath))
        }

    @Test
    fun `failed and cancelled entries preserve and resume their partial bytes`() =
        withStore { _, store ->
            val failed = store.openEntry("camera", "FAILED.MOV", 4)
            failed.append(0, byteArrayOf(1, 2))
            failed.fail(IOException("transport"))
            assertEquals(MediaCacheState.FAILED, failed.state)
            failed.resume()
            failed.append(2, byteArrayOf(3, 4))
            assertEquals(4, failed.downloadedBytes)

            val cancelled = store.openEntry("camera", "CANCELLED.MOV", 2)
            cancelled.append(0, byteArrayOf(1))
            cancelled.cancel()
            assertEquals(MediaCacheState.CANCELLED, cancelled.state)
            cancelled.resume()
            cancelled.append(1, byteArrayOf(2))
            assertEquals(2, cancelled.downloadedBytes)
        }

    @Test
    fun `usage accounts for cache artifacts and clear retains incomplete transfers`() =
        withStore { root, store ->
            val completed = store.openEntry("camera", "COMPLETE.MOV", 4)
            completed.append(0, byteArrayOf(1, 2, 3, 4))
            completed.complete()

            val incomplete = store.openEntry("camera", "INCOMPLETE.MOV", 6)
            incomplete.append(0, byteArrayOf(5, 6, 7))
            val unrelated = root.resolve("not-a-media-cache-artifact")
            Files.write(unrelated, byteArrayOf(8, 9))

            assertEquals(
                MediaCacheUsage(
                    completeEntryCount = 1,
                    completeBytes = 4,
                    incompleteEntryCount = 1,
                    incompleteBytes = 3,
                ),
                store.cacheUsage(),
            )

            val result = store.clearCompletedEntries()

            assertEquals(1, result.removedCompleteEntryCount)
            assertEquals(4, result.removedCompleteBytes)
            assertEquals(1, result.preservedIncompleteEntryCount)
            assertEquals(3, result.preservedIncompleteBytes)
            assertFalse(Files.exists(completed.finalPath))
            assertTrue(Files.exists(incomplete.partialPath))
            assertTrue(Files.exists(unrelated))
            assertEquals(
                MediaCacheUsage(
                    completeEntryCount = 0,
                    completeBytes = 0,
                    incompleteEntryCount = 1,
                    incompleteBytes = 3,
                ),
                store.cacheUsage(),
            )

            val reopened = store.openEntry("camera", "COMPLETE.MOV", 4)
            assertEquals(MediaCacheState.ACTIVE, reopened.state)
            assertEquals(0, reopened.downloadedBytes)
        }

    @Test
    fun `cache accounting never follows a symbolic bucket`() {
        val root = createTempDirectory("openzcine-media-cache")
        val outside = createTempDirectory("openzcine-outside-cache")
        try {
            val store = MediaCacheStore(root)
            val bucket = root.resolve("a".repeat(64))
            val outsideArtifact = outside.resolve("b".repeat(64) + ".media")
            Files.write(outsideArtifact, byteArrayOf(1, 2, 3))
            Files.createSymbolicLink(bucket, outside)

            assertEquals(
                MediaCacheUsage(
                    completeEntryCount = 0,
                    completeBytes = 0,
                    incompleteEntryCount = 0,
                    incompleteBytes = 0,
                ),
                store.cacheUsage(),
            )
            assertEquals(0, store.clearCompletedEntries().removedCompleteEntryCount)
            assertTrue(Files.exists(outsideArtifact))
        } finally {
            deleteTree(root)
            deleteTree(outside)
        }
    }

    private fun withStore(block: (Path, MediaCacheStore) -> Unit) {
        val root = createTempDirectory("openzcine-media-cache")
        try {
            block(root.toAbsolutePath().normalize(), MediaCacheStore(root))
        } finally {
            deleteTree(root)
        }
    }

    private fun deleteTree(root: Path) {
        if (!Files.exists(root)) return
        Files.walk(root).use { paths ->
            paths.sorted(Comparator.reverseOrder()).forEach(Files::deleteIfExists)
        }
    }
}
