package com.opencapture.openzcine.media

import com.opencapture.opencine.nikon.NikonMediaClipRecord
import com.opencapture.opencine.nikon.NikonMediaContentKind
import com.opencapture.opencine.nikon.NikonMediaDeletionPlan
import com.opencapture.opencine.nikon.NikonStillPhotoClassification
import com.opencapture.opencine.nikon.NikonStillPreviewStrategy
import java.nio.file.Files
import kotlin.io.path.createTempDirectory
import kotlin.test.Test
import kotlin.test.assertFalse
import kotlin.test.assertEquals
import kotlin.test.assertNull
import kotlin.test.assertTrue

/** JVM coverage for the camera-card deletion policy and its local purge. */
class MediaDeletionTest {
    @Test
    fun `frozen playback deletion copy and targets reject a late master or backup`() {
        val proxy = still(handle = 5, filename = "SIMULATED.MP4")
        val master = still(handle = 6, filename = "SIMULATED.NEV")
        val captured = NikonMediaDeletionPlan.of(listOf(proxy), listOf(proxy), oneBucket)
        val copy = deleteConfirmationMessage(listOf(proxy), captured)
        assertFalse("master" in copy)
        assertTrue(sameDeletionPlan(captured, NikonMediaDeletionPlan.of(listOf(proxy), listOf(proxy), oneBucket)))
        val widened = NikonMediaDeletionPlan.of(listOf(proxy, master), listOf(proxy), oneBucket)
        assertFalse(sameDeletionPlan(captured, widened))
        assertEquals(listOf(proxy), captured.targets)
        assertEquals(copy, deleteConfirmationMessage(listOf(proxy), captured))
        val backup = proxy.copy(handle = 55, storageId = 2)
        assertFalse(sameDeletionPlan(captured, NikonMediaDeletionPlan.of(listOf(proxy, backup), listOf(proxy), oneBucket)))
    }

    @Test
    fun `rating write result decodes confirmed stars, coded refusals, and no-code failures`() {
        assertEquals(RatingWriteResult.Confirmed(3), ratingWriteResult(3))
        assertEquals(RatingWriteResult.Confirmed(0), ratingWriteResult(0))
        // -1 is a failure with no reported code; a smaller negative is a negated wire code.
        assertEquals(RatingWriteResult.Refused(0), ratingWriteResult(-1))
        assertEquals(RatingWriteResult.Refused(0x2013), ratingWriteResult(-0x2013))
        assertEquals(RatingWriteResult.Refused(0x2005), ratingWriteResult(-0x2005))
    }

    @Test
    fun `rating refusal message carries the response code so the report self-diagnoses`() {
        val accessDenied = ratingRefusalMessage(0x2013)
        assertTrue(accessDenied.contains("Access Denied"))
        assertTrue(accessDenied.contains("0x2013"))
        assertTrue(ratingRefusalMessage(0x2005).contains("0x2005"))
        // No code reported → a distinct, code-free line (not a bogus 0x0000).
        assertTrue(ratingRefusalMessage(0).contains("didn't respond"))
    }

    @Test
    fun `confirmation copy names pairs, backups and masters only when the plan has them`() {
        val jpeg = still(handle = 1, filename = "DSC_0001.JPG")
        val raw = still(handle = 2, filename = "DSC_0001.NEF")
        val backupJpeg = still(handle = 21, filename = "DSC_0001.JPG", storageId = 2)
        val backupRaw = still(handle = 22, filename = "DSC_0001.NEF", storageId = 2)
        val stills = deleteConfirmationMessage(listOf(jpeg, raw, backupJpeg, backupRaw), listOf(jpeg), oneBucket)
        assertTrue("backup copies on the other card" in stills)
        assertTrue("RAW and JPEG" in stills)

        val proxy = still(handle = 5, filename = "A001_0001.MP4")
        val master = still(handle = 6, filename = "A001_0001.NEV")
        val video = deleteConfirmationMessage(listOf(proxy, master), listOf(proxy), oneBucket)
        assertTrue("A001_0001.MP4" in video)
        assertTrue("master" in video)
        assertTrue("RAW and JPEG" !in video)
        assertTrue("backup copies" !in video)

        val undated = still(handle = 1, filename = "DSC_0003.JPG", captureDate = "")
        val elsewhere = still(handle = 2, filename = "DSC_0003.NEF", storageId = 2, captureDate = "")
        assertEquals(
            "Delete this photo from the camera card?",
            deleteConfirmationMessage(listOf(undated, elsewhere), listOf(undated), oneBucket),
        )
    }

    @Test
    fun `purgeClip drops the index row and the favorite`() {
        val preferences = MemoryMediaPreferences()
        val index = MediaLibraryIndex(preferences)
        val keep = still(handle = 1, filename = "DSC_0001.JPG")
        val doomed = still(handle = 2, filename = "DSC_0002.JPG")
        index.rememberCameraListing("camera", listOf(keep, doomed))
        index.toggleFavorite("camera", doomed)

        index.purgeClip("camera", doomed)

        assertEquals(listOf(keep), index.persistedClips("camera"))
        assertTrue(index.favoriteIDs("camera").isEmpty())
        // Purging the last row clears the store entirely.
        index.purgeClip("camera", keep)
        assertTrue(index.persistedClips("camera").isEmpty())
    }

    @Test
    fun `purgeEntry removes the final artifact and the resumable partial`() {
        val root = createTempDirectory("openzcine-media-deletion")
        try {
            val store = MediaCacheStore(root.resolve("media-cache"))
            val identity =
                MediaCacheObjectIdentity(
                    storageId = 1,
                    handle = 2,
                    captureDate = "20260714T101010",
                    filename = "DSC_0002.JPG",
                )
            val entry = store.openEntry("camera", identity, 3)
            entry.append(0, byteArrayOf(1, 2, 3))
            entry.complete()
            assertTrue(Files.isRegularFile(entry.finalPath))

            store.purgeEntry("camera", identity)

            assertTrue(Files.notExists(entry.finalPath))
            assertTrue(Files.notExists(entry.partialPath))
            assertNull(store.completedEntryOrNull("camera", identity, 3))
            // Purging an identity that has no artifacts is a no-op.
            store.purgeEntry("camera", identity)
        } finally {
            root.toFile().deleteRecursively()
        }
    }

    /** Single-bucket owner used by every camera-source pairing call. */
    private val oneBucket: (NikonMediaClipRecord) -> String = { "camera" }

    private fun still(
        handle: Long,
        filename: String,
        storageId: Long = 1,
        captureDate: String = "20260714T101010",
    ): NikonMediaClipRecord {
        val kind =
            when (filename.substringAfterLast('.').lowercase()) {
                "mov", "mp4" -> NikonMediaContentKind.PLAYABLE_PROXY
                "r3d" -> NikonMediaContentKind.R3D_MASTER
                "nev" -> NikonMediaContentKind.UNSUPPORTED
                else -> NikonMediaContentKind.STILL_PHOTO
            }
        return NikonMediaClipRecord(
            handle = handle,
            storageId = storageId,
            sizeBytes = 100,
            captureDate = captureDate,
            pixelWidth = 3840,
            pixelHeight = 2160,
            filename = filename,
            contentKind = kind,
            // The label must agree with the extension, as it does in production — the listing
            // wire carries the shared core's own classification of this filename. Hardcoding
            // "JPEG" for every still made the fixture claim a .NEF was a JPEG, which only went
            // unnoticed while the pairing predicates read the extension and ignored the label.
            stillPhoto =
                if (kind == NikonMediaContentKind.STILL_PHOTO) {
                    val label =
                        when (filename.substringAfterLast('.').lowercase()) {
                            "nef", "nrw", "dng" -> "NEF"
                            "hif", "heif", "heic" -> "HEIF"
                            "tif", "tiff" -> "TIFF"
                            "png" -> "PNG"
                            else -> "JPEG"
                        }
                    NikonStillPhotoClassification(label, NikonStillPreviewStrategy.PROGRESSIVE)
                } else {
                    null
                },
        )
    }

    private class MemoryMediaPreferences : MediaLibraryPreferences {
        private val values = mutableMapOf<String, String>()

        override fun getString(key: String): String? = values[key]

        override fun putString(key: String, value: String?) {
            if (value == null) values.remove(key) else values[key] = value
        }
    }
}
