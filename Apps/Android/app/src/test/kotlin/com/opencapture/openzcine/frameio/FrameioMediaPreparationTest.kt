package com.opencapture.openzcine.frameio

import com.opencapture.opencine.runtime.MonitorMovieExportContainer
import com.opencapture.opencine.runtime.MonitorMovieExportLut
import com.opencapture.openzcine.FeedLut
import com.opencapture.openzcine.FeedLutSelection
import com.opencapture.openzcine.media.StagedMediaShare
import java.nio.file.Files
import java.nio.file.Path
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
    fun `default bake creates a temporary mov without changing the staged original`() = runTest {
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
                    MediaDeliveryConfiguration(
                        bakeLut = true,
                        includeMetadata = false,
                        selectedLut = selection,
                    ),
                ) {}

            assertEquals(source, exporter.source)
            assertEquals("C0001.mov", prepared.share.displayName)
            assertEquals("video/quicktime", prepared.share.mimeType)
            assertTrue(exporter.target?.fileName.toString().endsWith(".mov"))
            assertEquals("Unit LUT", prepared.appliedLutName)
            assertEquals(original.toList(), Files.readAllBytes(source).toList())
            assertTrue(Files.isRegularFile(prepared.share.file))
            assertTrue(prepared.share.file.startsWith(exportRoot))

            preparer.release(prepared)

            assertFalse(Files.exists(prepared.share.file))
        }
    }

    @Test
    fun `explicit mp4 export configuration changes target name and MIME only`() = runTest {
        withTempRoots { source, exportRoot ->
            val original = byteArrayOf(1, 2, 3, 4)
            Files.write(source, original)
            val exporter = FakeExporter()
            val preparer =
                AndroidFrameioArtifactPreparer(
                    exportRoot = exportRoot,
                    lutProvider = FixedLutProvider(unitLut()),
                    exporter = exporter,
                )

            val prepared =
                preparer.prepare(
                    artifact(source, supportsLutBake = true),
                    MediaDeliveryConfiguration(
                        bakeLut = true,
                        exportContainer = MonitorMovieExportContainer.MP4,
                        selectedLut = FeedLutSelection.BuiltIn(FeedLut.MONO),
                    ),
                ) {}

            assertEquals("C0001.mp4", prepared.share.displayName)
            assertEquals("video/mp4", prepared.share.mimeType)
            assertTrue(exporter.target?.fileName.toString().endsWith(".mp4"))
            assertEquals(original.toList(), Files.readAllBytes(source).toList())
            preparer.release(prepared)
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
                        MediaDeliveryConfiguration(
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
                        lut: MonitorMovieExportLut,
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
                        MediaDeliveryConfiguration(
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
                MediaDeliveryConfiguration(includeMetadata = true),
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

    private fun unitLut(): MonitorMovieExportLut =
        MonitorMovieExportLut(
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

    private class FixedLutProvider(private val payload: MonitorMovieExportLut?) : FrameioLutProvider {
        override suspend fun approvedPayload(selection: FeedLutSelection): MonitorMovieExportLut? = payload
    }

    private class FakeExporter : FrameioLutVideoExporter {
        var calls = 0
        var source: Path? = null
        var target: Path? = null

        override suspend fun export(
            source: Path,
            target: Path,
            lut: MonitorMovieExportLut,
            onProgress: suspend (Double) -> Unit,
        ) {
            calls += 1
            this.source = source
            this.target = target
            onProgress(0.5)
            Files.write(target, fakeIsoBmff())
            onProgress(1.0)
        }
    }

    private companion object {
        fun fakeIsoBmff(): ByteArray =
            byteArrayOf(
                0x00, 0x00, 0x00, 0x18,
                0x66, 0x74, 0x79, 0x70,
                0x69, 0x73, 0x6F, 0x6D,
                0x00, 0x00, 0x00, 0x00,
                0x69, 0x73, 0x6F, 0x6D,
                0x61, 0x76, 0x63, 0x31,
            )
    }
}
