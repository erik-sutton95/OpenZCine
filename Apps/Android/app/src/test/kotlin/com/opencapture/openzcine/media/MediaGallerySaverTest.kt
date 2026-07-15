package com.opencapture.openzcine.media

import java.io.ByteArrayOutputStream
import java.io.IOException
import java.io.OutputStream
import java.nio.file.Files
import java.nio.file.Path
import java.time.Instant
import java.time.ZoneOffset
import java.util.concurrent.CancellationException
import kotlin.io.path.createTempDirectory
import kotlin.test.Test
import kotlin.test.assertContentEquals
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import kotlin.test.assertNull
import kotlin.test.assertTrue

/** Host-side coverage for scoped MediaStore orchestration and failure cleanup. */
class MediaGallerySaverTest {
    @Test
    fun `save writes and publishes a sequential batch with exact bytes`() =
        withRoot { root ->
            val first = artifact(root, "C0001.MOV", byteArrayOf(1, 2, 3))
            val second = artifact(root, "C0002.MP4", byteArrayOf(4, 5))
            val gateway = FakeGalleryGateway()

            val result = MediaGallerySaver(gateway).save(listOf(first, second))

            assertEquals(2, result.savedCount)
            assertEquals(0, result.failedCount)
            assertEquals(
                listOf(
                    "create:C0001.MOV",
                    "open:C0001.MOV",
                    "publish:C0001.MOV",
                    "create:C0002.MP4",
                    "open:C0002.MP4",
                    "publish:C0002.MP4",
                ),
                gateway.events,
            )
            assertContentEquals(byteArrayOf(1, 2, 3), gateway.bytesFor("C0001.MOV"))
            assertContentEquals(byteArrayOf(4, 5), gateway.bytesFor("C0002.MP4"))
            assertTrue(gateway.deleted.isEmpty())
            assertEquals("Saved 2 clips to Gallery.", result.operatorMessage())
        }

    @Test
    fun `batch continues after one write failure and deletes only its pending row`() =
        withRoot { root ->
            val first = artifact(root, "C0010.MOV", byteArrayOf(1))
            val second = artifact(root, "C0011.MOV", byteArrayOf(2))
            val third = artifact(root, "C0012.MOV", byteArrayOf(3))
            val gateway = FakeGalleryGateway(failWritesFor = setOf("C0011.MOV"))

            val result = MediaGallerySaver(gateway).save(listOf(first, second, third))

            assertEquals(2, result.savedCount)
            assertEquals(1, result.failedCount)
            assertEquals(MediaGalleryFailureKind.WRITE_FAILED, result.failures.single().kind)
            assertEquals(setOf("C0010.MOV", "C0012.MOV"), gateway.published)
            assertEquals(setOf("C0011.MOV"), gateway.deleted)
            assertEquals(
                "Saved 2 clips to Gallery; 1 clip couldn't be saved.",
                result.operatorMessage(),
            )
        }

    @Test
    fun `cancellation during copy deletes the pending row and never publishes`() =
        withRoot { root ->
            val bytes = ByteArray(900_000) { index -> (index % 251).toByte() }
            val source = artifact(root, "C0020.MOV", bytes)
            val gateway = FakeGalleryGateway()
            var checks = 0

            assertFailsWith<CancellationException> {
                MediaGallerySaver(gateway).save(listOf(source)) {
                    checks += 1
                    if (checks >= 4) throw CancellationException("Operator closed Media.")
                }
            }

            assertTrue(checks >= 4)
            assertEquals(setOf("C0020.MOV"), gateway.deleted)
            assertTrue(gateway.published.isEmpty())
        }

    @Test
    fun `permission denial is typed without creating a cleanup target`() =
        withRoot { root ->
            val source = artifact(root, "C0030.MOV", byteArrayOf(1, 2))
            val gateway = FakeGalleryGateway(createFailure = SecurityException("denied"))

            val result = MediaGallerySaver(gateway).save(listOf(source))

            assertEquals(0, result.savedCount)
            assertEquals(MediaGalleryFailureKind.PERMISSION_DENIED, result.failures.single().kind)
            assertTrue(result.failures.single().operatorMessage.startsWith("Gallery access was denied"))
            assertTrue(gateway.deleted.isEmpty())
        }

    @Test
    fun `storage creation and publish failures have distinct operator categories`() =
        withRoot { root ->
            val source = artifact(root, "C0040.MP4", byteArrayOf(7, 8))
            val createResult =
                MediaGallerySaver(
                    FakeGalleryGateway(
                        createFailure = MediaGalleryStoreUnavailableException("no volume"),
                    ),
                ).save(listOf(source))
            val publishGateway = FakeGalleryGateway(failPublishFor = setOf("C0040.MP4"))

            val publishResult = MediaGallerySaver(publishGateway).save(listOf(source))

            assertEquals(MediaGalleryFailureKind.STORAGE_UNAVAILABLE, createResult.failures.single().kind)
            assertEquals(MediaGalleryFailureKind.PUBLISH_FAILED, publishResult.failures.single().kind)
            assertEquals(setOf("C0040.MP4"), publishGateway.deleted)
            assertTrue(publishGateway.published.isEmpty())
        }

    @Test
    fun `cleanup failure is surfaced instead of claiming the pending row was removed`() =
        withRoot { root ->
            val source = artifact(root, "C0050.MOV", byteArrayOf(9))
            val gateway =
                FakeGalleryGateway(
                    failWritesFor = setOf("C0050.MOV"),
                    failDeleteFor = setOf("C0050.MOV"),
                )

            val result = MediaGallerySaver(gateway).save(listOf(source))

            assertEquals(MediaGalleryFailureKind.CLEANUP_FAILED, result.failures.single().kind)
            assertEquals(setOf("C0050.MOV"), gateway.deleteAttempts)
            assertTrue(result.failures.single().operatorMessage.contains("couldn't clean up"))
        }

    @Test
    fun `invalid source is rejected before MediaStore insertion`() =
        withRoot { root ->
            val source = artifact(root, "C0060.MOV", byteArrayOf(1, 2, 3))
            Files.write(source.file, byteArrayOf(1))
            val gateway = FakeGalleryGateway()

            val result = MediaGallerySaver(gateway).save(listOf(source))

            assertEquals(MediaGalleryFailureKind.SOURCE_UNAVAILABLE, result.failures.single().kind)
            assertTrue(gateway.events.isEmpty())
        }

    @Test
    fun `staged artifact conversion keeps authoritative video action and exact MIME metadata`() =
        withRoot { root ->
            val file = root.resolve("ready-video.mov")
            Files.write(file, byteArrayOf(1, 2, 3, 4))

            val artifact =
                MediaGalleryArtifact.fromStagedShare(
                    StagedMediaShare(file, "C0070.MOV", "video/*"),
                )

            assertEquals("video/quicktime", artifact.mimeType)
            assertEquals(4, artifact.expectedBytes)
            assertFailsWith<InvalidMediaGalleryArtifactException> {
                MediaGalleryArtifact.fromStagedShare(
                    StagedMediaShare(file, "DSC_0070.JPG", "image/*"),
                )
            }
            assertFailsWith<InvalidMediaGalleryArtifactException> {
                MediaGalleryArtifact.fromStagedShare(
                    StagedMediaShare(file, "../C0070.MOV", "video/*"),
                )
            }
            assertFailsWith<InvalidMediaGalleryArtifactException> {
                MediaGalleryArtifact.fromStagedShare(
                    StagedMediaShare(file, "C0070.R3D", "video/*"),
                )
            }
        }

    @Test
    fun `result message reports non-video incomplete and preparation omissions`() {
        val result =
            MediaGalleryBatchResult(
                savedCount = 1,
                failures =
                    listOf(
                        MediaGalleryFailure(
                            "C0080.MOV",
                            MediaGalleryFailureKind.WRITE_FAILED,
                            "C0080.MOV failed.",
                        ),
                    ),
            )

        assertEquals(
            "Saved 1 clip to Gallery; 1 clip couldn't be saved; 2 non-video items skipped; " +
                "1 incomplete item wasn't ready; 3 items couldn't be prepared; " +
                "1 temporary export wasn't removed.",
            result.operatorMessage(
                MediaGalleryOmissions(
                    nonVideoCount = 2,
                    incompleteCount = 1,
                    preparationFailureCount = 3,
                    temporaryCleanupFailureCount = 1,
                ),
            ),
        )
        assertEquals(
            "No videos were saved to Gallery; 1 non-video item skipped.",
            MediaGalleryBatchResult(0, emptyList())
                .operatorMessage(MediaGalleryOmissions(nonVideoCount = 1)),
        )
    }

    @Test
    fun `M4V uses MPEG-4 gallery metadata and unknown extension is rejected`() {
        assertEquals("video/mp4", galleryVideoMimeType("C0090.M4V"))
        assertEquals("video/mp4", galleryVideoMimeType("C0090.mp4"))
        assertEquals("video/quicktime", galleryVideoMimeType("C0090.mov"))
        assertEquals(null, galleryVideoMimeType("C0090.R3D"))
    }

    @Test
    fun `requested camera capture metadata parses strictly and survives artifact conversion`() =
        withRoot { root ->
            val timestamp = mediaCaptureTimestampMillis("20260715T120000", ZoneOffset.UTC)
            assertEquals(Instant.parse("2026-07-15T12:00:00Z").toEpochMilli(), timestamp)
            assertNull(mediaCaptureTimestampMillis("2026-07-15", ZoneOffset.UTC))
            assertNull(mediaCaptureTimestampMillis("20260230T120000", ZoneOffset.UTC))
            val file = root.resolve("ready.mov")
            Files.write(file, byteArrayOf(1, 2, 3))

            val artifact =
                MediaGalleryArtifact.fromStagedShare(
                    StagedMediaShare(file, "C0091.MOV", "video/quicktime"),
                    captureTimestampMillis = timestamp,
                )

            assertEquals(timestamp, artifact.captureTimestampMillis)
        }

    private fun artifact(root: Path, name: String, bytes: ByteArray): MediaGalleryArtifact {
        val path = root.resolve(name.lowercase())
        Files.write(path, bytes)
        return MediaGalleryArtifact(
            file = path,
            displayName = name,
            mimeType = galleryVideoMimeType(name) ?: error("Unsupported test video"),
            expectedBytes = bytes.size.toLong(),
        )
    }

    private fun withRoot(block: (Path) -> Unit) {
        val root = createTempDirectory("openzcine-gallery")
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

    private class FakeGalleryGateway(
        private val createFailure: Exception? = null,
        private val failWritesFor: Set<String> = emptySet(),
        private val failPublishFor: Set<String> = emptySet(),
        private val failDeleteFor: Set<String> = emptySet(),
    ) : MediaGalleryGateway {
        val events = mutableListOf<String>()
        val published = mutableSetOf<String>()
        val deleted = mutableSetOf<String>()
        val deleteAttempts = mutableSetOf<String>()
        private val names = mutableMapOf<String, String>()
        private val outputs = mutableMapOf<String, ByteArrayOutputStream>()
        private var nextID = 0

        override fun createPending(artifact: MediaGalleryArtifact): PendingMediaGalleryItem {
            createFailure?.let { throw it }
            val item = PendingMediaGalleryItem("pending-${nextID++}")
            names[item.identifier] = artifact.displayName
            events += "create:${artifact.displayName}"
            return item
        }

        override fun openPending(item: PendingMediaGalleryItem): OutputStream {
            val name = name(item)
            events += "open:$name"
            val output = ByteArrayOutputStream()
            outputs[name] = output
            if (name !in failWritesFor) return output
            return object : OutputStream() {
                override fun write(value: Int) = throw IOException("write failed")

                override fun write(bytes: ByteArray, offset: Int, length: Int) =
                    throw IOException("write failed")
            }
        }

        override fun publish(item: PendingMediaGalleryItem) {
            val name = name(item)
            events += "publish:$name"
            if (name in failPublishFor) throw MediaGalleryPublishException("publish failed")
            published += name
        }

        override fun deletePending(item: PendingMediaGalleryItem) {
            val name = name(item)
            deleteAttempts += name
            events += "delete:$name"
            if (name in failDeleteFor) throw IOException("delete failed")
            deleted += name
        }

        fun bytesFor(name: String): ByteArray = outputs.getValue(name).toByteArray()

        private fun name(item: PendingMediaGalleryItem): String =
            names[item.identifier] ?: error("Unknown pending item")
    }
}
