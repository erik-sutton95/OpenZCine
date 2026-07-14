package com.opencapture.openzcine.media

import java.nio.file.Files
import kotlin.io.path.createTempDirectory
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertIs
import kotlin.test.assertTrue

/** Pure still-viewer policy, cache reuse, and stale-request regression coverage. */
class StillPreviewStateTest {
    @Test
    fun `HEIF and RAW fallbacks never claim a full preview`() {
        val heif = StillPhotoClassification("HEIF", StillPreviewStrategy.COMPLETE_FILE)
        val raw = StillPhotoClassification("Nikon RAW", StillPreviewStrategy.THUMBNAIL_ONLY)

        val heifFallback =
            assertIs<StillPreviewUiState.ThumbnailFallback>(
                StillPreviewStates.decoderUnavailable(heif, hasThumbnail = true),
            )
        val rawFallback =
            assertIs<StillPreviewUiState.ThumbnailFallback>(
                StillPreviewStates.decoderUnavailable(raw, hasThumbnail = false),
            )

        assertEquals(
            "This HEIF image could not be decoded for a full preview on this Android device. " +
                "Showing the camera thumbnail.",
            heifFallback.message,
        )
        assertEquals(
            "Nikon RAW files are not decoded for a full preview on Android. " +
                "The camera did not provide a thumbnail.",
            rawFallback.message,
        )
    }

    @Test
    fun `progressive state carries bounded cache progress and JPEG copy`() {
        val state =
            StillPreviewStates.downloading(
                StillPhotoClassification("JPEG", StillPreviewStrategy.PROGRESSIVE),
                progress = 1.7,
            )

        assertEquals(1.0, state.progress)
        assertEquals("Loading full JPEG preview…", state.message)
        assertEquals(8, previewSampleSize(8_256, 5_504))
    }

    @Test
    fun `load gate rejects a late decode after close and accepts a replacement request`() {
        val gate = StillViewerLoadGate()
        val first = gate.begin()
        assertTrue(gate.accepts(first))

        gate.invalidate()
        assertTrue(!gate.accepts(first))

        val replacement = gate.begin()
        assertTrue(gate.accepts(replacement))
        assertTrue(!gate.accepts(first))
    }

    @Test
    fun `cancelled photo cache resumes through the same safe object identity`() {
        val root = createTempDirectory("openzcine-still-cache")
        try {
            val identity =
                MediaCacheObjectIdentity(
                    storageId = 0x0001_0001L,
                    handle = 0x1008L,
                    captureDate = "20260715T101010",
                    filename = "DSC_0007.JPG",
                )
            val first = MediaCacheStore(root).openEntry("ZR-6001234", identity, 4)
            first.append(0, byteArrayOf(1, 2))
            first.cancel()

            val reopened = MediaCacheStore(root).openEntry("ZR-6001234", identity, 4)

            assertEquals(2, reopened.downloadedBytes)
            assertEquals(MediaCacheState.ACTIVE, reopened.state)
            reopened.append(2, byteArrayOf(3, 4))
            reopened.complete()
            assertEquals(MediaCacheState.COMPLETE, reopened.state)
        } finally {
            Files.walk(root).use { paths ->
                paths.sorted(Comparator.reverseOrder()).forEach(Files::deleteIfExists)
            }
        }
    }
}
