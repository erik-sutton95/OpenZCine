package com.opencapture.openzcine.media

import java.nio.file.Files
import kotlin.io.path.createTempDirectory
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNull
import kotlin.test.assertTrue

/** JVM coverage for the camera-card deletion policy and its local purge. */
class MediaDeletionTest {
    @Test
    fun `raw sibling pairs the same stem on the same card only`() {
        val jpeg = still(handle = 1, filename = "DSC_0001.JPG")
        val raw = still(handle = 2, filename = "DSC_0001.NEF")
        val otherCardRaw = still(handle = 3, filename = "DSC_0001.NEF", storageId = 2)
        val unrelated = still(handle = 4, filename = "DSC_0002.NEF")
        val catalog = listOf(jpeg, raw, otherCardRaw, unrelated)

        assertEquals(raw, rawSibling(catalog, jpeg))
        // Case-insensitive stem matching, like iOS.
        assertEquals(
            raw,
            rawSibling(catalog, jpeg.copy(filename = "dsc_0001.jpg")),
        )
        // RAW cells and non-stills never claim a sibling of their own.
        assertNull(rawSibling(catalog, raw))
        assertNull(rawSibling(catalog, still(handle = 5, filename = "C0001.MOV")))
        // Split recording: a same-stem RAW on another card is a separate item.
        assertNull(rawSibling(listOf(jpeg, otherCardRaw), jpeg))
    }

    @Test
    fun `deletion targets expand pairs once and keep raw-only selections narrow`() {
        val jpeg = still(handle = 1, filename = "DSC_0001.JPG")
        val raw = still(handle = 2, filename = "DSC_0001.NEF")
        val movie = still(handle = 3, filename = "C0001.MOV")
        val catalog = listOf(jpeg, raw, movie)

        // Deleting the JPEG deletes both sides of the pair.
        assertEquals(listOf(jpeg, raw), cameraDeletionTargets(catalog, listOf(jpeg)))
        // Selecting both sides still deletes each object exactly once.
        assertEquals(
            listOf(jpeg, raw),
            cameraDeletionTargets(catalog, listOf(jpeg, raw)),
        )
        // A RAW-only selection deletes only the RAW (its cell is its own item).
        assertEquals(listOf(raw), cameraDeletionTargets(catalog, listOf(raw)))
        assertEquals(listOf(movie), cameraDeletionTargets(catalog, listOf(movie)))
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

    private fun still(
        handle: Long,
        filename: String,
        storageId: Long = 1,
    ): MediaClipRecord =
        MediaClipRecord(
            handle = handle,
            storageId = storageId,
            sizeBytes = 100,
            captureDate = "20260714T101010",
            pixelWidth = 3840,
            pixelHeight = 2160,
            filename = filename,
            contentKind =
                if (filename.endsWith(".MOV", ignoreCase = true)) {
                    MediaContentKind.PLAYABLE_PROXY
                } else {
                    MediaContentKind.STILL_PHOTO
                },
            stillPhoto =
                if (filename.endsWith(".MOV", ignoreCase = true)) {
                    null
                } else {
                    StillPhotoClassification("JPEG", StillPreviewStrategy.PROGRESSIVE)
                },
        )

    private class MemoryMediaPreferences : MediaLibraryPreferences {
        private val values = mutableMapOf<String, String>()

        override fun getString(key: String): String? = values[key]

        override fun putString(key: String, value: String?) {
            if (value == null) values.remove(key) else values[key] = value
        }
    }
}
