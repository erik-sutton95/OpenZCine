package com.opencapture.openzcine.media

import java.nio.file.Files
import java.nio.file.Path
import java.nio.file.attribute.FileTime
import java.util.concurrent.CancellationException
import kotlin.io.path.createTempDirectory
import kotlin.test.Test
import kotlin.test.assertContentEquals
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import kotlin.test.assertFalse
import kotlin.test.assertNotEquals
import kotlin.test.assertTrue

/** Host-side coverage for the complete-cache-only native-share boundary. */
class MediaShareStagerTest {
    @Test
    fun `stage copies a complete cache entry into the provider visible cache directory`() =
        withRoot { root ->
            val bytes = byteArrayOf(9, 8, 7, 6)
            val entry = completedEntry(root, "C0001.MOV", bytes)

            val staged =
                MediaShareStager(root.resolve("cache")).stage(
                    entry,
                    clip("C0001.MOV", MediaContentKind.PLAYABLE_PROXY),
                )

            assertEquals("C0001.MOV", staged.displayName)
            assertEquals("video/*", staged.mimeType)
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
    fun `stage validates a display filename before it creates a provider visible copy`() =
        withRoot { root ->
            val entry = completedEntry(root, "C0003.MOV", byteArrayOf(1, 2, 3))
            val stager = MediaShareStager(root.resolve("cache"))

            listOf("", "../clip.mov", "folder\\clip.mov", "clip.mov\n", ".MOV")
                .forEach { filename ->
                    assertFailsWith<UnsafeMediaShareFilenameException> { stager.stage(entry, filename) }
                }
            Files.list(root.resolve("cache/share/ready")).use { files -> assertEquals(0, files.count()) }
        }

    @Test
    fun `stage derives MIME family from the shared core action not the filename`() =
        withRoot { root ->
            val entry = completedEntry(root, "C0003.BIN", byteArrayOf(1, 2, 3))

            val staged =
                MediaShareStager(root.resolve("cache")).stage(
                    entry,
                    clip("C0003.BIN", MediaContentKind.STILL_PHOTO),
                )

            assertEquals("image/*", staged.mimeType)
            assertEquals("C0003.BIN", staged.displayName)
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
    fun `stage does not reuse a same length artifact after source content changes`() =
        withRoot { root ->
            val entry = completedEntry(root, "C0004A.MP4", byteArrayOf(3, 1, 4, 1, 5))
            val stager = MediaShareStager(root.resolve("cache"))

            val first = stager.stage(entry, "C0004A.MP4")
            val replacement = byteArrayOf(2, 7, 1, 8, 2)
            Files.write(entry.finalPath, replacement)
            val second = stager.stage(entry, "C0004A.MP4")

            assertNotEquals(first.file, second.file)
            assertContentEquals(replacement, Files.readAllBytes(second.file))
            assertContentEquals(byteArrayOf(3, 1, 4, 1, 5), Files.readAllBytes(first.file))
            Files.list(root.resolve("cache/share/ready")).use { files -> assertEquals(2, files.count()) }
        }

    @Test
    fun `stage copies from the opened source handle when the path is replaced mid copy`() =
        withRoot { root ->
            val original = byteArrayOf(1, 3, 3, 7)
            val replacement = root.resolve("replacement.mov")
            Files.write(replacement, byteArrayOf(9, 9, 9, 9))
            val entry = completedEntry(root, "C0004B.MOV", original)
            var cancellationChecks = 0

            val staged =
                MediaShareStager(root.resolve("cache")).stage(entry, "C0004B.MOV") {
                    cancellationChecks += 1
                    if (cancellationChecks == 2) {
                        val heldSource = root.resolve("held-source.mov")
                        Files.move(entry.finalPath, heldSource)
                        Files.createSymbolicLink(entry.finalPath, replacement)
                    }
                }

            assertContentEquals(original, Files.readAllBytes(staged.file))
            assertTrue(Files.isSymbolicLink(entry.finalPath))
        }

    @Test
    fun `stage cancellation removes a partial staging file without publishing a share artifact`() =
        withRoot { root ->
            val bytes = ByteArray(3 * 64 * 1024) { index -> (index % 251).toByte() }
            val entry = completedEntry(root, "C0004C.MOV", bytes)
            var cancellationChecks = 0

            assertFailsWith<CancellationException> {
                MediaShareStager(root.resolve("cache")).stage(entry, "C0004C.MOV") {
                    cancellationChecks += 1
                    if (cancellationChecks >= 5) {
                        throw CancellationException("Playback closed.")
                    }
                }
            }

            assertTrue(cancellationChecks >= 5)
            Files.list(root.resolve("cache/share/ready")).use { files -> assertEquals(0, files.count()) }
            Files.list(root.resolve("cache/share/staging")).use { files -> assertEquals(0, files.count()) }
        }

    @Test
    fun `stage preserves a recent share artifact instead of revoking a possible URI grant`() =
        withRoot { root ->
            var now = 10_000L
            val stager = constrainedStager(root) { now }
            val firstEntry = completedEntry(root, "C0004D.MOV", byteArrayOf(1, 2, 3, 4))
            val secondEntry = completedEntry(root, "C0004E.MOV", byteArrayOf(5, 6, 7, 8))
            val first = stager.stage(firstEntry, "C0004D.MOV")

            assertFailsWith<MediaShareCacheLimitException> {
                stager.stage(secondEntry, "C0004E.MOV")
            }

            assertTrue(Files.exists(first.file))
            Files.list(root.resolve("cache/share/ready")).use { files -> assertEquals(1, files.count()) }
            Files.list(root.resolve("cache/share/staging")).use { files -> assertEquals(0, files.count()) }
        }

    @Test
    fun `stage preserves an unusable same name artifact until its grant retention expires`() =
        withRoot { root ->
            var now = 10_000L
            val stager = constrainedStager(root) { now }
            val source = byteArrayOf(1, 2, 3, 4)
            val entry = completedEntry(root, "C0004DA.MOV", source)
            val first = stager.stage(entry, "C0004DA.MOV")
            val corrupt = byteArrayOf(9, 9, 9, 9)
            Files.write(first.file, corrupt)
            Files.setLastModifiedTime(first.file, FileTime.fromMillis(now))

            assertFailsWith<MediaShareCacheLimitException> {
                stager.stage(entry, "C0004DA.MOV")
            }

            assertContentEquals(corrupt, Files.readAllBytes(first.file))
            Files.list(root.resolve("cache/share/ready")).use { files -> assertEquals(1, files.count()) }
            Files.list(root.resolve("cache/share/staging")).use { files -> assertEquals(0, files.count()) }

            now += 101L
            val replacement = stager.stage(entry, "C0004DA.MOV")

            assertEquals(first.file, replacement.file)
            assertContentEquals(source, Files.readAllBytes(replacement.file))
        }

    @Test
    fun `stage deterministically evicts an expired artifact before publishing a new share`() =
        withRoot { root ->
            var now = 10_000L
            val stager = constrainedStager(root) { now }
            val firstEntry = completedEntry(root, "C0004F.MOV", byteArrayOf(1, 2, 3, 4))
            val secondEntry = completedEntry(root, "C0004G.MOV", byteArrayOf(5, 6, 7, 8))
            val first = stager.stage(firstEntry, "C0004F.MOV")

            now += 101L
            val second = stager.stage(secondEntry, "C0004G.MOV")

            assertFalse(Files.exists(first.file))
            assertTrue(Files.exists(second.file))
            Files.list(root.resolve("cache/share/ready")).use { files -> assertEquals(1, files.count()) }
        }

    @Test
    fun `share intent policy carries a typed stream URI and read grant`() =
        withRoot { root ->
            val entry = completedEntry(root, "C0005.M4V", byteArrayOf(4, 2))
            val staged =
                MediaShareStager(root.resolve("cache")).stage(
                    entry,
                    clip("C0005.M4V", MediaContentKind.PLAYABLE_PROXY),
                )

            val spec = MediaShareIntentSpec.forShare(staged)

            assertEquals(MediaShareIntentSpec.ACTION_SEND, spec.action)
            assertEquals("video/*", spec.mimeType)
            assertTrue(spec.streamExtraIncluded)
            assertEquals("C0005.M4V", spec.clipDataLabel)
            assertTrue(spec.grantsReadUriPermission)
            assertEquals("Share C0005.M4V", spec.chooserTitle)
        }

    @Test
    fun `batch policy uses send multiple and a safe mixed media MIME type`() =
        withRoot { root ->
            val stager = MediaShareStager(root.resolve("cache"))
            val video =
                stager.stage(
                    completedEntry(root, "C0005A.MOV", byteArrayOf(4, 2)),
                    clip("C0005A.MOV", MediaContentKind.PLAYABLE_PROXY),
                )
            val still =
                stager.stage(
                    completedEntry(root, "DSC_0007.JPG", byteArrayOf(7, 7)),
                    clip("DSC_0007.JPG", MediaContentKind.STILL_PHOTO),
                )

            val spec = MediaShareIntentSpec.forShares(listOf(video, still))

            assertEquals(MediaShareIntentSpec.ACTION_SEND_MULTIPLE, spec.action)
            assertEquals("*/*", spec.mimeType)
            assertTrue(spec.streamExtraIncluded)
            assertEquals("OpenZCine media", spec.clipDataLabel)
            assertTrue(spec.grantsReadUriPermission)
            assertEquals("Share 2 items", spec.chooserTitle)
            assertEquals("image/*", still.mimeType)
        }

    @Test
    fun `configured export is verified and copied into provider ready storage`() =
        withRoot { root ->
            val export = root.resolve("transient/export.mov")
            Files.createDirectories(export.parent)
            Files.write(export, byteArrayOf(9, 8, 7, 6))

            val staged =
                MediaShareStager(root.resolve("cache")).stagePreparedArtifact(
                    source = export,
                    expectedBytes = 4,
                    displayName = "C0009.mov",
                    mimeType = "video/quicktime",
                )

            assertTrue(staged.file.startsWith(root.resolve("cache/share/ready")))
            assertEquals(listOf<Byte>(9, 8, 7, 6), Files.readAllBytes(staged.file).toList())
            assertTrue(Files.exists(export))
            Files.write(export, byteArrayOf(1))
            assertFailsWith<InvalidMediaShareSourceException> {
                MediaShareStager(root.resolve("cache")).stagePreparedArtifact(
                    source = export,
                    expectedBytes = 4,
                    displayName = "C0009.mov",
                    mimeType = "video/quicktime",
                )
            }
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

    private fun clip(filename: String, contentKind: MediaContentKind): MediaClipRecord =
        MediaClipRecord(
            handle = 1,
            storageId = 1,
            sizeBytes = 0,
            captureDate = "20260715T120000",
            pixelWidth = 0,
            pixelHeight = 0,
            filename = filename,
            contentKind = contentKind,
            stillPhoto =
                if (contentKind == MediaContentKind.STILL_PHOTO) {
                    StillPhotoClassification("Photo", StillPreviewStrategy.COMPLETE_FILE)
                } else {
                    null
                },
        )

    private fun constrainedStager(root: Path, clock: () -> Long): MediaShareStager =
        MediaShareStager(
            cacheDirectory = root.resolve("cache"),
            clock = clock,
            maximumReadyBytes = 6,
            maximumReadyArtifacts = 1,
            grantRetentionMillis = 100,
        )

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
