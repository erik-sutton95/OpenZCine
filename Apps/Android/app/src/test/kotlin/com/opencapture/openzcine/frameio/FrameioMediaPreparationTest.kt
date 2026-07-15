package com.opencapture.openzcine.frameio

import com.opencapture.openzcine.FeedLut
import com.opencapture.openzcine.FeedLutSelection
import com.opencapture.openzcine.media.StagedMediaShare
import java.nio.file.Files
import java.nio.file.Path
import java.nio.file.attribute.FileTime
import kotlin.io.path.createTempDirectory
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import kotlin.test.assertFalse
import kotlin.test.assertNotNull
import kotlin.test.assertTrue
import kotlinx.coroutines.test.runTest

class FrameioMediaPreparationTest {
    @Test
    fun `export watchdog resets only when codec progress advances`() {
        var nowNanos = 0L
        val watchdog = FrameioExportProgressWatchdog(stallTimeoutMillis = 100L) { nowNanos }

        nowNanos = 99_000_000L
        assertFalse(watchdog.hasStalled())
        watchdog.recordProgress(10)
        nowNanos = 198_000_000L
        watchdog.recordProgress(10)
        assertFalse(watchdog.hasStalled())
        nowNanos = 199_000_000L
        assertTrue(watchdog.hasStalled())
        watchdog.recordProgress(11)
        assertFalse(watchdog.hasStalled())
    }

    @Test
    fun `packed core cube maps to Media3 red green blue indexing`() {
        val size = 2
        val packed = ByteArray(size * size * size * 4)
        for (red in 0 until size) {
            for (green in 0 until size) {
                for (blue in 0 until size) {
                    val offset = ((green * size + blue) * size + red) * 4
                    packed[offset] = (red * 80).toByte()
                    packed[offset + 1] = (green * 90).toByte()
                    packed[offset + 2] = (blue * 100).toByte()
                    packed[offset + 3] = 0xFF.toByte()
                }
            }
        }

        val cube = FrameioLutPayload("Unit LUT", size, packed).toMedia3Cube()

        assertEquals(0xFF500064.toInt(), cube[1][0][1])
        assertEquals(0xFF005A00.toInt(), cube[0][1][0])
    }

    @Test
    fun `bake creates a temporary mp4 without changing the staged original`() = runTest {
        withTempRoots { source, exportRoot ->
            val original = byteArrayOf(1, 2, 3, 4)
            Files.write(source, original)
            val selection = FeedLutSelection.BuiltIn(FeedLut.NLOG_709)
            val exporter = FakeExporter()
            val preparer =
                AndroidFrameioArtifactPreparer(
                    exportRoot = exportRoot,
                    lutProvider = FixedLutProvider(unitLut()),
                    exporter = exporter,
                )
            val artifact = artifact(source, supportsLutBake = true)

            val prepared =
                preparer.prepare(
                    artifact,
                    FrameioDeliveryOptions(
                        bakeLut = true,
                        includeMetadata = false,
                        selectedLut = selection,
                    ),
                ) {}

            assertEquals(source, exporter.source)
            assertEquals("C0001.mp4", prepared.share.displayName)
            assertEquals("Unit LUT", prepared.appliedLutName)
            assertEquals(original.toList(), Files.readAllBytes(source).toList())
            assertTrue(Files.isRegularFile(prepared.share.file))
            assertTrue(prepared.share.file.startsWith(exportRoot))

            preparer.release(prepared)

            assertFalse(Files.exists(prepared.share.file))
        }
    }

    @Test
    fun `bake fails closed for a non-video artifact`() = runTest {
        withTempRoots { source, exportRoot ->
            Files.write(source, byteArrayOf(1, 2, 3, 4))
            val exporter = FakeExporter()
            val preparer =
                AndroidFrameioArtifactPreparer(
                    exportRoot = exportRoot,
                    lutProvider = FixedLutProvider(unitLut()),
                    exporter = exporter,
                )

            val error =
                assertFailsWith<FrameioDeliveryException> {
                    preparer.prepare(
                        artifact(source, supportsLutBake = false),
                        FrameioDeliveryOptions(
                            bakeLut = true,
                            selectedLut = FeedLutSelection.BuiltIn(FeedLut.MONO),
                        ),
                    ) {}
                }

            assertTrue(error.message.orEmpty().contains("isn't a video proxy"))
            assertEquals(0, exporter.calls)
        }
    }

    @Test
    fun `orphan prune removes only expired owned exports`() {
        val root = createTempDirectory("frameio-prune")
        try {
            val now = 10_000L
            val expired = root.resolve("frameio-00000000-0000-0000-0000-000000000001.mp4")
            val fresh = root.resolve("frameio-00000000-0000-0000-0000-000000000002.mp4")
            val unrelated = root.resolve("camera-original.mp4")
            Files.write(expired, byteArrayOf(1))
            Files.write(fresh, byteArrayOf(2))
            Files.write(unrelated, byteArrayOf(3))
            Files.setLastModifiedTime(expired, FileTime.fromMillis(now - 2_000L))
            Files.setLastModifiedTime(fresh, FileTime.fromMillis(now))

            pruneOwnedFrameioExports(
                root = root,
                nowEpochMillis = now,
                maximumAgeMillis = 1_000L,
                maximumBytes = Long.MAX_VALUE,
            )

            assertFalse(Files.exists(expired))
            assertTrue(Files.exists(fresh))
            assertTrue(Files.exists(unrelated))
        } finally {
            root.toFile().deleteRecursively()
        }
    }

    @Test
    fun `orphan budget preserves protected export while evicting oldest unprotected files`() {
        val root = createTempDirectory("frameio-budget")
        try {
            val oldest = root.resolve("frameio-00000000-0000-0000-0000-000000000011.mp4")
            val protected = root.resolve("frameio-00000000-0000-0000-0000-000000000012.mp4")
            val newest = root.resolve("frameio-00000000-0000-0000-0000-000000000013.mp4")
            listOf(oldest, protected, newest).forEachIndexed { index, path ->
                Files.write(path, byteArrayOf(1, 2, 3, 4))
                Files.setLastModifiedTime(path, FileTime.fromMillis(1_000L + index))
            }

            pruneOwnedFrameioExports(
                root = root,
                protected = setOf(protected),
                nowEpochMillis = 2_000L,
                maximumAgeMillis = Long.MAX_VALUE,
                maximumBytes = 4L,
            )

            assertFalse(Files.exists(oldest))
            assertTrue(Files.exists(protected))
            assertFalse(Files.exists(newest))
        } finally {
            root.toFile().deleteRecursively()
        }
    }

    @Test
    fun `release reports an owned temporary export that could not be removed`() = runTest {
        val root = createTempDirectory("frameio-release")
        try {
            val temporary = root.resolve("frameio-00000000-0000-0000-0000-000000000021.mp4")
            Files.write(temporary, byteArrayOf(1, 2, 3))
            val preparer =
                AndroidFrameioArtifactPreparer(
                    exportRoot = root,
                    lutProvider = FixedLutProvider(unitLut()),
                    exporter = FakeExporter(),
                    deleteExport = { false },
                )
            val prepared =
                FrameioPreparedArtifact(
                    StagedMediaShare(temporary, "C0001.mp4", "video/mp4"),
                    byteCount = 3,
                    appliedLutName = "Unit LUT",
                    transientExport = temporary,
                )

            assertFailsWith<FrameioDeliveryException> { preparer.release(prepared) }
            assertTrue(Files.exists(temporary))
        } finally {
            root.toFile().deleteRecursively()
        }
    }

    @Test
    fun `failed export cleanup cannot override cancellation`() = runTest {
        withTempRoots { source, exportRoot ->
            Files.write(source, byteArrayOf(1, 2, 3, 4))
            val exporter =
                object : FrameioLutVideoExporter {
                    override suspend fun export(
                        source: Path,
                        target: Path,
                        lut: FrameioLutPayload,
                        onProgress: suspend (Double) -> Unit,
                    ) {
                        Files.write(target, byteArrayOf(9, 8, 7))
                        throw kotlinx.coroutines.CancellationException("unit cancel")
                    }
                }
            val preparer =
                AndroidFrameioArtifactPreparer(
                    exportRoot = exportRoot,
                    lutProvider = FixedLutProvider(unitLut()),
                    exporter = exporter,
                    deleteExport = { false },
                )

            val cancellation =
                assertFailsWith<kotlinx.coroutines.CancellationException> {
                    preparer.prepare(
                        artifact(source, supportsLutBake = true),
                        FrameioDeliveryOptions(
                            bakeLut = true,
                            selectedLut = FeedLutSelection.BuiltIn(FeedLut.MONO),
                        ),
                    ) {}
                }

            assertTrue(cancellation.suppressedExceptions.isNotEmpty())
            assertTrue(
                Files.list(exportRoot).use { paths -> paths.iterator().hasNext() },
            )
        }
    }

    @Test
    fun `metadata sidecar records approved delivery context without cloud identifiers`() = runTest {
        val root = createTempDirectory("frameio-metadata")
        try {
            val source = root.resolve("source.mov")
            Files.write(source, byteArrayOf(1, 2, 3, 4))
            val artifact = artifact(source, supportsLutBake = true)
            val prepared =
                FrameioPreparedArtifact(
                    StagedMediaShare(source, "C0001.mp4", "video/mp4"),
                    9,
                    "Unit LUT",
                    null,
                )
            val destination =
                FrameioDestination(
                    accountID = "private-account-id",
                    workspaceID = "private-workspace-id",
                    projectID = "private-project-id",
                    projectName = "Dailies",
                    folderID = "private-folder-id",
                )
            val writer = AndroidFrameioMetadataSidecarWriter(root, clock = { 123_000L })

            writer.recordSuccessfulDelivery(
                artifact,
                prepared,
                destination,
                FrameioDeliveryOptions(includeMetadata = true),
            )

            val sidecar =
                Files.list(root).use { paths ->
                    paths.iterator().asSequence()
                        .firstOrNull { path -> path.fileName.toString().endsWith(".meta.json") }
                }
            assertNotNull(sidecar)
            val body = String(Files.readAllBytes(sidecar), Charsets.UTF_8)
            assertTrue(body.contains("\"originalFilename\": \"C0001.MOV\""))
            assertTrue(body.contains("\"deliveryFilename\": \"C0001.mp4\""))
            assertTrue(body.contains("\"projectName\": \"Dailies\""))
            assertTrue(body.contains("\"lutName\": \"Unit LUT\""))
            assertTrue(body.contains("\"cameraID\": \"camera-unit\""))
            assertTrue(body.contains("\"sizeBytes\": 9"))
            assertFalse(body.contains("private-account-id"))
            assertFalse(body.contains("private-workspace-id"))
            assertFalse(body.contains("private-project-id"))
            assertFalse(body.contains("private-folder-id"))
        } finally {
            root.toFile().deleteRecursively()
        }
    }

    private fun artifact(source: Path, supportsLutBake: Boolean): FrameioDeliveryArtifact =
        FrameioDeliveryArtifact(
            share = StagedMediaShare(source, "C0001.MOV", "video/quicktime"),
            byteCount = Files.size(source),
            context =
                FrameioArtifactContext(
                    cameraID = "camera-unit",
                    captureDate = "20260715T120000",
                    supportsLutBake = supportsLutBake,
                ),
        )

    private fun unitLut(): FrameioLutPayload =
        FrameioLutPayload(
            displayName = "Unit LUT",
            cubeSize = 2,
            packedRgba = ByteArray(2 * 2 * 2 * 4) { 0xFF.toByte() },
        )

    private suspend fun withTempRoots(block: suspend (Path, Path) -> Unit) {
        val root = createTempDirectory("frameio-preparation")
        try {
            block(root.resolve("C0001.MOV"), root.resolve("exports"))
        } finally {
            root.toFile().deleteRecursively()
        }
    }

    private class FixedLutProvider(private val payload: FrameioLutPayload?) : FrameioLutProvider {
        override suspend fun approvedPayload(selection: FeedLutSelection): FrameioLutPayload? = payload
    }

    private class FakeExporter : FrameioLutVideoExporter {
        var calls = 0
        var source: Path? = null

        override suspend fun export(
            source: Path,
            target: Path,
            lut: FrameioLutPayload,
            onProgress: suspend (Double) -> Unit,
        ) {
            calls += 1
            this.source = source
            onProgress(0.5)
            Files.write(target, byteArrayOf(9, 8, 7, 6, 5))
            onProgress(1.0)
        }
    }
}
