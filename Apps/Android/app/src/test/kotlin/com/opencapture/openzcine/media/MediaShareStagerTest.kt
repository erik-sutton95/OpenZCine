package com.opencapture.openzcine.media

import java.nio.file.Files
import java.nio.file.Path
import kotlin.io.path.createTempDirectory
import kotlin.test.Test
import kotlin.test.assertContentEquals
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import kotlin.test.assertFalse
import kotlin.test.assertTrue

/** Host-side coverage for the complete-cache-only native-share boundary. */
class MediaShareStagerTest {
    @Test
    fun `stage copies a complete cache entry into the provider visible cache directory`() =
        withRoot { root ->
            val bytes = byteArrayOf(9, 8, 7, 6)
            val entry = completedEntry(root, "C0001.MOV", bytes)

            val staged = MediaShareStager(root.resolve("cache")).stage(entry, "C0001.MOV")

            assertEquals("C0001.MOV", staged.displayName)
            assertEquals("video/quicktime", staged.mimeType)
            assertTrue(staged.file.startsWith(root.resolve("cache/share/ready")))
            assertFalse(staged.file.startsWith(root.resolve("no-backup")))
            assertFalse(staged.file.fileName.toString().endsWith(".part"))
            assertContentEquals(bytes, Files.readAllBytes(staged.file))
            assertContentEquals(bytes, Files.readAllBytes(entry.finalPath))
            Files.list(root.resolve("cache/share/ready")).use { files ->
                assertTrue(files.allMatch { file -> file.fileName.toString().endsWith(".mov") })
            }
            Files.list(root.resolve("cache/share/staging")).use { files -> assertEquals(0, files.count()) }
        }

    @Test
    fun `stage rejects an active entry before any partial file can enter the share directory`() =
        withRoot { root ->
            val entry =
                MediaCacheStore(root.resolve("no-backup/media-cache"))
                    .openEntry("camera", "C0002.MOV", 4)
            entry.append(0, byteArrayOf(1, 2))
            val stager = MediaShareStager(root.resolve("cache"))

            val error = assertFailsWith<IncompleteMediaShareException> { stager.stage(entry, "C0002.MOV") }

            assertEquals(MediaCacheState.ACTIVE, error.cacheState)
            Files.list(root.resolve("cache/share/ready")).use { files -> assertEquals(0, files.count()) }
        }

    @Test
    fun `stage validates filename and MIME before it creates a provider visible copy`() =
        withRoot { root ->
            val entry = completedEntry(root, "C0003.MOV", byteArrayOf(1, 2, 3))
            val stager = MediaShareStager(root.resolve("cache"))

            listOf("", "../clip.mov", "folder\\clip.mov", "clip.mov\n", ".MOV")
                .forEach { filename ->
                    assertFailsWith<UnsafeMediaShareFilenameException> { stager.stage(entry, filename) }
                }
            assertFailsWith<UnsupportedMediaShareFormatException> { stager.stage(entry, "C0003.R3D") }
            Files.list(root.resolve("cache/share/ready")).use { files -> assertEquals(0, files.count()) }
        }

    @Test
    fun `stage reuses a verified immutable copy instead of growing the share cache`() =
        withRoot { root ->
            val entry = completedEntry(root, "C0004.MP4", byteArrayOf(3, 1, 4, 1, 5))
            val stager = MediaShareStager(root.resolve("cache"))

            val first = stager.stage(entry, "C0004.MP4")
            val second = stager.stage(entry, "C0004.MP4")

            assertEquals(first.file, second.file)
            Files.list(root.resolve("cache/share/ready")).use { files -> assertEquals(1, files.count()) }
        }

    @Test
    fun `share intent policy carries a typed stream URI and read grant`() =
        withRoot { root ->
            val entry = completedEntry(root, "C0005.M4V", byteArrayOf(4, 2))
            val staged = MediaShareStager(root.resolve("cache")).stage(entry, "C0005.M4V")

            val spec = MediaShareIntentSpec.forShare(staged)

            assertEquals(MediaShareIntentSpec.ACTION_SEND, spec.action)
            assertEquals("video/mp4", spec.mimeType)
            assertTrue(spec.streamExtraIncluded)
            assertEquals("C0005.M4V", spec.clipDataLabel)
            assertTrue(spec.grantsReadUriPermission)
            assertEquals("Share C0005.M4V", spec.chooserTitle)
        }

    @Test
    fun `stage refuses a completed entry whose final cache file no longer matches its byte count`() =
        withRoot { root ->
            val entry = completedEntry(root, "C0006.MOV", byteArrayOf(1, 2, 3, 4))
            Files.write(entry.finalPath, byteArrayOf(1))

            assertFailsWith<InvalidMediaShareSourceException> {
                MediaShareStager(root.resolve("cache")).stage(entry, "C0006.MOV")
            }
        }

    @Test
    fun `stage rejects a symlinked final cache file`() =
        withRoot { root ->
            val entry = completedEntry(root, "C0007.MOV", byteArrayOf(7, 7, 7))
            val replacement = root.resolve("replacement.mov")
            Files.write(replacement, byteArrayOf(7, 7, 7))
            Files.delete(entry.finalPath)
            Files.createSymbolicLink(entry.finalPath, replacement)

            assertFailsWith<InvalidMediaShareSourceException> {
                MediaShareStager(root.resolve("cache")).stage(entry, "C0007.MOV")
            }
            Files.list(root.resolve("cache/share/ready")).use { files -> assertEquals(0, files.count()) }
        }

    private fun completedEntry(root: Path, filename: String, bytes: ByteArray): MediaCacheEntry {
        val entry =
            MediaCacheStore(root.resolve("no-backup/media-cache"))
                .openEntry("camera", filename, bytes.size.toLong())
        entry.append(0, bytes)
        entry.complete()
        return entry
    }

    private fun withRoot(block: (Path) -> Unit) {
        val root = createTempDirectory("openzcine-media-share")
        try {
            block(root.toAbsolutePath().normalize())
        } finally {
            if (Files.exists(root)) {
                Files.walk(root).use { paths ->
                    paths.sorted(Comparator.reverseOrder()).forEach(Files::deleteIfExists)
                }
            }
        }
    }
}
