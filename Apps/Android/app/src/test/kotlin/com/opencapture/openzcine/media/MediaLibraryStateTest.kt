package com.opencapture.openzcine.media

import java.nio.file.Files
import java.nio.file.Path
import kotlin.io.path.createTempDirectory
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNotNull
import kotlin.test.assertNull
import kotlin.test.assertTrue

/** JVM coverage for the persisted, core-authorized Android library state. */
class MediaLibraryStateTest {
    @Test
    fun `camera listing persists core wire records without reclassifying filenames`() {
        val preferences = MemoryPreferences()
        val index = MediaLibraryIndex(preferences)
        val still = clip(handle = 12, filename = "OBJECT.DATA", kind = MediaContentKind.STILL_PHOTO)
        val proxy = clip(handle = 13, filename = "UNUSUAL.NAME", kind = MediaContentKind.PLAYABLE_PROXY)

        index.rememberCameraListing("ZR-6001234", listOf(still, proxy))

        assertEquals(listOf(proxy, still), index.persistedClips("ZR-6001234"))
        assertEquals(MediaContentKind.STILL_PHOTO, index.persistedClips("ZR-6001234")[1].contentKind)
        assertEquals(
            StillPreviewStrategy.PROGRESSIVE,
            index.persistedClips("ZR-6001234")[1].stillPhoto?.previewStrategy,
        )
    }

    @Test
    fun `listing merge retains a previously indexed local object`() {
        val index = MediaLibraryIndex(MemoryPreferences())
        val older = clip(handle = 1, filename = "OLDER.BIN", captureDate = "20260713T101010")
        val latest = clip(handle = 2, filename = "LATEST.BIN", captureDate = "20260714T101010")

        index.rememberCameraListing("camera", listOf(older))
        index.rememberCameraListing("camera", listOf(latest))

        assertEquals(listOf(latest, older), index.persistedClips("camera"))
    }

    @Test
    fun `favorites are camera scoped and persist by full object identity`() {
        val preferences = MemoryPreferences()
        val index = MediaLibraryIndex(preferences)
        val first = clip(handle = 7, filename = "C0007.MOV")
        val sameFilenameElsewhere = first.copy(storageId = 2, handle = 8)

        val favorites = index.toggleFavorite("camera-a", first)

        assertTrue(first.libraryKey("camera-a") in favorites)
        assertFalse(sameFilenameElsewhere.libraryKey("camera-a") in favorites)
        val restored = MediaLibraryIndex(preferences)
        assertTrue(first.libraryKey("camera-a") in restored.favoriteIDs("camera-a"))
        assertTrue(restored.favoriteIDs("camera-b").isEmpty())
    }

    @Test
    fun `categories and sort consume shared core actions instead of extensions`() {
        val cameraID = "camera"
        val proxy = clip(handle = 1, filename = "PHOTO.NEF", kind = MediaContentKind.PLAYABLE_PROXY)
        val still = clip(handle = 2, filename = "VIDEO.MOV", kind = MediaContentKind.STILL_PHOTO)
        val master = clip(handle = 3, filename = "MASTER.WHATEVER", kind = MediaContentKind.R3D_MASTER)
        val unknown = clip(handle = 4, filename = "UNKNOWN.JPG", kind = MediaContentKind.UNSUPPORTED)
        val clips = listOf(proxy, still, master, unknown)

        assertEquals(
            listOf(master, proxy),
            MediaLibraryFiltering.displayed(
                clips,
                MediaLibraryCategory.VIDEOS,
                emptySet(),
                cameraID,
                MediaLibrarySortOrder.NAME,
            ),
        )
        assertEquals(
            listOf(still),
            MediaLibraryFiltering.displayed(
                clips,
                MediaLibraryCategory.PHOTOS,
                emptySet(),
                cameraID,
                MediaLibrarySortOrder.NAME,
            ),
        )
        assertEquals(
            listOf(master),
            MediaLibraryFiltering.displayed(
                clips,
                MediaLibraryCategory.FAVORITES,
                setOf(master.libraryKey(cameraID)),
                cameraID,
                MediaLibrarySortOrder.NAME,
            ),
        )
    }

    @Test
    fun `sweep selection only adds items and visibility changes prune safely`() {
        val first = MediaLibrarySelection.begin("one")
        val swept = MediaLibrarySelection.addSweep(first, listOf("one", "two", "three"))

        assertEquals(setOf("one", "two", "three"), swept)
        assertEquals(setOf("two"), MediaLibrarySelection.retainVisible(swept, setOf("two")))
        assertEquals(emptySet(), MediaLibrarySelection.toggle(setOf("one"), "one"))
    }

    @Test
    fun `corrupt persisted controls fall back to a safe camera view`() {
        val preferences =
            MemoryPreferences(
                mapOf(
                    "view.source" to "NOT_A_SOURCE",
                    "view.category" to "NOPE",
                    "view.layout" to "SIDEWAYS",
                    "view.sort" to "WRONG",
                ),
            )

        assertEquals(
            MediaLibraryViewOptions(source = MediaLibrarySource.CAMERA),
            MediaLibraryIndex(preferences).viewOptions(MediaLibrarySource.CAMERA),
        )
    }

    @Test
    fun `view controls persist source category layout and sort`() {
        val preferences = MemoryPreferences()
        val options =
            MediaLibraryViewOptions(
                source = MediaLibrarySource.LOCAL,
                category = MediaLibraryCategory.FAVORITES,
                layout = MediaLibraryLayout.LIST,
                sortOrder = MediaLibrarySortOrder.NAME,
            )

        MediaLibraryIndex(preferences).saveViewOptions(options)

        assertEquals(options, MediaLibraryIndex(preferences).viewOptions(MediaLibrarySource.CAMERA))
    }

    @Test
    fun `complete lookup reads one identity-derived artifact and never creates a part`() {
        withStore { root, store ->
            val identity = MediaCacheObjectIdentity(1, 7, "20260714T101010", "C0007.MOV")
            val entry = store.openEntry("camera", identity, 3)
            entry.append(0, byteArrayOf(1, 2, 3))
            entry.complete()

            val before = artifactCount(root)
            val found = store.completedEntryOrNull("camera", identity, 3)
            val missing =
                store.completedEntryOrNull(
                    "camera",
                    identity.copy(handle = 8, filename = "C0008.MOV"),
                    3,
                )

            assertNotNull(found)
            assertEquals(MediaCacheState.COMPLETE, found.state)
            assertNull(missing)
            assertEquals(before, artifactCount(root))

            Files.delete(found.finalPath)

            assertNull(store.completedEntryOrNull("camera", identity, 3))
            assertEquals(0, artifactCount(root))
        }
    }

    private fun clip(
        handle: Long,
        filename: String,
        kind: MediaContentKind = MediaContentKind.PLAYABLE_PROXY,
        captureDate: String = "20260714T101010",
    ): MediaClipRecord =
        MediaClipRecord(
            handle = handle,
            storageId = 1,
            sizeBytes = 100,
            captureDate = captureDate,
            pixelWidth = 3840,
            pixelHeight = 2160,
            filename = filename,
            contentKind = kind,
            stillPhoto =
                if (kind == MediaContentKind.STILL_PHOTO) {
                    StillPhotoClassification("JPEG", StillPreviewStrategy.PROGRESSIVE)
                } else {
                    null
                },
        )

    private fun withStore(block: (Path, MediaCacheStore) -> Unit) {
        val root = createTempDirectory("openzcine-media-library")
        try {
            block(root, MediaCacheStore(root.resolve("no-backup/media-cache")))
        } finally {
            root.toFile().deleteRecursively()
        }
    }

    private fun artifactCount(root: Path): Long =
        Files.walk(root).use { paths ->
            paths.filter { path -> Files.isRegularFile(path) }.count()
        }

    private class MemoryPreferences(initial: Map<String, String> = emptyMap()) : MediaLibraryPreferences {
        private val values = initial.toMutableMap()

        override fun getString(key: String): String? = values[key]

        override fun putString(key: String, value: String?) {
            if (value == null) values.remove(key) else values[key] = value
        }
    }
}
