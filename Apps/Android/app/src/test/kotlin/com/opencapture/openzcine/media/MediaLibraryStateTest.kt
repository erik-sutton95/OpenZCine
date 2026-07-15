package com.opencapture.openzcine.media

import com.opencapture.openzcine.frameio.FrameioCameraRejoinEvidence
import com.opencapture.openzcine.frameio.FrameioDeliveryState
import com.opencapture.openzcine.frameio.FrameioInternetHopState
import java.nio.file.Files
import java.nio.file.Path
import kotlin.io.path.createTempDirectory
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNotNull
import kotlin.test.assertNull
import kotlin.test.assertTrue
import kotlinx.coroutines.test.runTest

/** JVM coverage for the persisted, core-authorized Android library state. */
class MediaLibraryStateTest {
    @Test
    fun `intentional Frameio hop retains the camera library until rejoin resolves`() {
        val retained =
            listOf(
                FrameioInternetHopState.LeavingCamera,
                FrameioInternetHopState.WaitingForInternet,
                FrameioInternetHopState.Online,
                FrameioInternetHopState.RejoiningCamera,
            )
        retained.forEach { state ->
            assertTrue(
                frameioHopKeepsCameraLibraryMounted(
                    state,
                    rejoinedConnectionObserved = false,
                ),
            )
        }

        assertFalse(
            frameioHopKeepsCameraLibraryMounted(
                FrameioInternetHopState.Idle,
                rejoinedConnectionObserved = false,
            ),
        )
        assertTrue(
            frameioHopKeepsCameraLibraryMounted(
                rejoinedState(),
                rejoinedConnectionObserved = false,
            ),
        )
        assertFalse(
            frameioHopKeepsCameraLibraryMounted(
                rejoinedState(),
                rejoinedConnectionObserved = true,
            ),
        )
        assertFalse(
            frameioHopKeepsCameraLibraryMounted(
                FrameioInternetHopState.Failed("failed"),
                rejoinedConnectionObserved = false,
            ),
        )
    }

    @Test
    fun `offline-only browser never fabricates a camera from retained Frameio state`() {
        assertFalse(
            effectiveMediaCameraConnection(
                cameraSessionAvailable = false,
                cameraConnected = false,
                frameioInternetHopState = FrameioInternetHopState.LeavingCamera,
                rejoinedConnectionObserved = false,
            ),
        )
        assertFalse(
            effectiveMediaCameraConnection(
                cameraSessionAvailable = false,
                cameraConnected = false,
                frameioInternetHopState = rejoinedState(),
                rejoinedConnectionObserved = false,
            ),
        )
    }

    @Test
    fun `Frameio dialog cannot close while the camera network handoff is unsettled`() {
        val blocked =
            listOf(
                FrameioInternetHopState.LeavingCamera,
                FrameioInternetHopState.WaitingForInternet,
                FrameioInternetHopState.RejoiningCamera,
            )
        blocked.forEach { state -> assertTrue(frameioHopBlocksDismissal(state)) }

        assertFalse(frameioHopBlocksDismissal(FrameioInternetHopState.Idle))
        assertFalse(frameioHopBlocksDismissal(FrameioInternetHopState.Online))
        assertFalse(frameioHopBlocksDismissal(rejoinedState()))
        assertFalse(frameioHopBlocksDismissal(FrameioInternetHopState.Failed("failed")))
    }

    @Test
    fun `failed Frameio upload cannot hide a failed camera rejoin`() {
        val summary =
            frameioDeliverySummary(
                state = FrameioDeliveryState.Failed("Upload failed"),
                internetHopState = FrameioInternetHopState.Failed("Saved profile did not reconnect"),
                errorMessage = null,
                skippedBeforeUpload = 0,
            )

        assertTrue(summary.contains("Upload failed"))
        assertTrue(summary.contains("camera rejoin not verified"))
        assertTrue(summary.contains("Saved profile did not reconnect"))
    }

    @Test
    fun `failed Frameio preparation cannot hide a later failed camera rejoin`() {
        val summary =
            frameioPreparationMessageAfterRejoin(
                message = "Couldn't prepare selected media.",
                internetHopState =
                    FrameioInternetHopState.Failed("Saved profile did not reconnect"),
            )

        assertNotNull(summary)
        assertTrue(summary.contains("Couldn't prepare selected media"))
        assertTrue(summary.contains("Camera rejoin not verified"))
        assertTrue(summary.contains("Saved profile did not reconnect"))
    }

    @Test
    fun `confirmed Frameio delivery reports orphaned temporary exports without claiming failure`() {
        val summary =
            frameioDeliverySummary(
                state =
                    FrameioDeliveryState.Completed(
                        uploadedCount = 1,
                        failedCount = 0,
                        cleanupFailureCount = 1,
                    ),
                internetHopState = rejoinedState(),
                errorMessage = null,
                skippedBeforeUpload = 0,
            )

        assertTrue(summary.contains("Delivered 1 cached item"))
        assertTrue(summary.contains("1 temporary export not removed"))
        assertTrue(summary.contains("camera rejoined"))
    }

    @Test
    fun `Frameio summary distinguishes uploaded skipped and failed batch counts`() {
        val summary =
            frameioDeliverySummary(
                state =
                    FrameioDeliveryState.Completed(
                        uploadedCount = 2,
                        skippedCount = 3,
                        failedCount = 1,
                    ),
                internetHopState = FrameioInternetHopState.Idle,
                errorMessage = null,
                skippedBeforeUpload = 0,
            )

        assertTrue(summary.contains("Delivered 2 cached items"))
        assertTrue(summary.contains("3 already uploaded"))
        assertTrue(summary.contains("1 failed"))
    }

    @Test
    fun `Frameio media preparation cleanup ends an active hop before returning`() = runTest {
        var ended = false

        endActiveFrameioHopAfterMediaJob(
            isActive = { true },
            endHop = { ended = true },
        )

        assertTrue(ended)
    }

    @Test
    fun `Frameio media preparation cleanup skips a hop already ended by delivery`() = runTest {
        var calls = 0

        endActiveFrameioHopAfterMediaJob(
            isActive = { false },
            endHop = { calls += 1 },
        )

        assertEquals(0, calls)
    }

    @Test
    fun `camera listing persists core wire records without reclassifying filenames`() {
        val preferences = MemoryPreferences()
        val index = MediaLibraryIndex(preferences)
        val still = clip(handle = 12, filename = "OBJECT.DATA", kind = MediaContentKind.STILL_PHOTO)
        val proxy =
            clip(handle = 13, filename = "UNUSUAL.NAME", kind = MediaContentKind.PLAYABLE_PROXY)
                .copy(sourcePixelWidth = 6_048, sourcePixelHeight = 3_402)

        index.rememberCameraListing("ZR-6001234", listOf(still, proxy))

        assertEquals(listOf(proxy, still), index.persistedClips("ZR-6001234"))
        assertEquals(MediaContentKind.STILL_PHOTO, index.persistedClips("ZR-6001234")[1].contentKind)
        assertEquals(
            StillPreviewStrategy.PROGRESSIVE,
            index.persistedClips("ZR-6001234")[1].stillPhoto?.previewStrategy,
        )
        assertEquals(6_048, index.persistedClips("ZR-6001234")[0].sourcePixelWidth)
        assertEquals(3_402, index.persistedClips("ZR-6001234")[0].sourcePixelHeight)
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
    fun `incremental proxy delta removes the paired R3D from persistence`() {
        val index = MediaLibraryIndex(MemoryPreferences())
        val master = clip(handle = 7, filename = "A001.R3D", kind = MediaContentKind.R3D_MASTER)
        val proxy = clip(handle = 8, filename = "A001.MP4")

        index.rememberCameraListing("camera", listOf(master))
        index.rememberCameraListing(
            cameraID = "camera",
            clips = listOf(proxy),
            removedObjects = listOf(MediaObjectIdentity(master)),
        )

        assertEquals(listOf(proxy), index.persistedClips("camera"))
    }

    @Test
    fun `camera index retains history beyond the former 1024 record cap`() {
        val index = MediaLibraryIndex(MemoryPreferences())
        val clips =
            (1L..1_300L).map { handle ->
                clip(
                    handle = handle,
                    filename = "C${handle.toString().padStart(4, '0')}.MOV",
                    captureDate = "20260715T${(handle % 24).toString().padStart(2, '0')}0000",
                )
            }

        index.rememberCameraListing("camera", clips)

        assertEquals(1_300, index.persistedClips("camera").size)
        assertTrue(index.persistedClips("camera").any { it.handle == 1L })
        assertTrue(index.persistedClips("camera").any { it.handle == 1_300L })
    }

    @Test
    fun `disconnected buckets preserve saved camera order and reject stale cache entries`() {
        withStore { _, store ->
            val index = MediaLibraryIndex(MemoryPreferences())
            val first = clip(handle = 1, filename = "A001.MOV").copy(sizeBytes = 3)
            val second =
                clip(handle = 2, filename = "B001.JPG", kind = MediaContentKind.STILL_PHOTO)
                    .copy(sizeBytes = 4)
            index.rememberCameraListing("serial-a", listOf(first))
            index.rememberCameraListing("serial-b", listOf(second))
            index.rememberCameraBucket("saved-a", "serial-a", "Camera A")
            index.rememberCameraBucket("saved-b", "serial-b", "Camera B")
            store.openEntry("serial-a", MediaCacheObjectIdentity(first), 3).apply {
                append(0, byteArrayOf(1, 2, 3))
                complete()
            }
            store.openEntry("serial-b", MediaCacheObjectIdentity(second), 4).apply {
                append(0, byteArrayOf(1, 2, 3, 4))
                complete()
            }

            val available =
                index.completedCameraBuckets(listOf("saved-b", "saved-a", "removed"), store)

            assertEquals(listOf("saved-b", "saved-a"), available.map { it.savedCameraID })
            assertEquals(listOf("serial-b", "serial-a"), available.map { it.cameraID })
            val stale =
                store.completedEntryOrNull("serial-a", MediaCacheObjectIdentity(first), 3)
            assertNotNull(stale)
            Files.delete(stale.finalPath)
            assertEquals(
                listOf("saved-b"),
                index.completedCameraBuckets(listOf("saved-a", "saved-b"), store)
                    .map { it.savedCameraID },
            )
        }
    }

    @Test
    fun `proxy delta preserves an older cached record whose PTP handle was reused`() {
        val index = MediaLibraryIndex(MemoryPreferences())
        val historical =
            clip(
                handle = 7,
                filename = "OLDER.R3D",
                captureDate = "20260701T120000",
                kind = MediaContentKind.R3D_MASTER,
            )
        val currentMaster =
            clip(
                handle = 7,
                filename = "A001.R3D",
                captureDate = "20260715T120000",
                kind = MediaContentKind.R3D_MASTER,
            )
        val proxy = clip(handle = 8, filename = "A001.MP4")
        index.rememberCameraListing("camera", listOf(historical))
        index.rememberCameraListing("camera", listOf(currentMaster))

        index.rememberCameraListing(
            cameraID = "camera",
            clips = listOf(proxy),
            removedObjects = listOf(MediaObjectIdentity(currentMaster)),
        )

        assertEquals(listOf(proxy, historical), index.persistedClips("camera"))
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
                    "view.thumbnail-size" to "HUGE",
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
                thumbnailSize = MediaThumbnailSize.LARGE,
            )

        MediaLibraryIndex(preferences).saveViewOptions(options)

        assertEquals(options, MediaLibraryIndex(preferences).viewOptions(MediaLibrarySource.CAMERA))
    }

    @Test
    fun `container resolution today and slot filters follow shared metadata fallbacks`() {
        val todayMov =
            clip(1, "A001.MOV", captureDate = "20260715T101010")
                .copy(storageId = 11, pixelWidth = 3_840)
        val todayMp4 =
            clip(2, "A002.MP4", captureDate = "20260715T111010")
                .copy(storageId = 11, pixelWidth = 3_840)
        val oldMov =
            clip(3, "A003.MOV", captureDate = "20260714T101010")
                .copy(storageId = 22, pixelWidth = 6_048)
        val missingWidth =
            clip(4, "A004_6K.MOV", captureDate = "20260715T121010")
                .copy(storageId = 11, pixelWidth = 0)
        val filters =
            MediaLibraryFilters(
                containers = setOf(MediaContainerFilter.MOV),
                resolutions = setOf(MediaResolutionFilter.FOUR_K),
                todayOnly = true,
                storageId = 11,
            )

        val displayed =
            MediaLibraryFiltering.displayed(
                clips = listOf(todayMov, todayMp4, oldMov, missingWidth),
                category = MediaLibraryCategory.ALL,
                favoriteIDs = emptySet(),
                cameraID = "camera",
                sortOrder = MediaLibrarySortOrder.NAME,
                filters = filters,
                todayToken = "20260715",
            )

        assertEquals(listOf(todayMov), displayed)
        assertEquals(4, filters.activeCount)
        assertEquals(MediaContainerFilter.MOV, todayMov.containerFilter())
        assertEquals(MediaContainerFilter.MOV, todayMov.copy(filename = "A001.M4V").containerFilter())
        assertEquals(MediaResolutionFilter.SIX_K, missingWidth.resolutionFilter())
    }

    @Test
    fun `resolution prefers paired R3D source then proxy pixels then filename`() {
        val paired =
            clip(1, "SHOT_4K.MP4")
                .copy(pixelWidth = 1_920, sourcePixelWidth = 6_048, sourcePixelHeight = 3_402)
        val proxyOnly = clip(2, "SHOT_6K.MP4").copy(pixelWidth = 3_840)
        val filenameOnly = clip(3, "SHOT_5.4K.MP4").copy(pixelWidth = 0)
        val filename54Token = clip(4, "SHOT_54K.MOV").copy(pixelWidth = 0)
        val filenameUhd = clip(5, "SHOT_UHD.MOV").copy(pixelWidth = 0)
        val filenameHd = clip(6, "SHOT_1080.MOV").copy(pixelWidth = 0)

        assertEquals(MediaResolutionFilter.SIX_K, paired.resolutionFilter())
        assertEquals(MediaResolutionFilter.FOUR_K, proxyOnly.resolutionFilter())
        assertEquals(MediaResolutionFilter.FIVE_FOUR_K, filenameOnly.resolutionFilter())
        assertEquals(MediaResolutionFilter.FIVE_FOUR_K, filename54Token.resolutionFilter())
        assertEquals(MediaResolutionFilter.FOUR_K, filenameUhd.resolutionFilter())
        assertEquals(MediaResolutionFilter.HD, filenameHd.resolutionFilter())
    }

    @Test
    fun `filter groups use OR within a group and stale camera slots clear safely`() {
        val hd = clip(1, "A001.MOV").copy(storageId = 11, pixelWidth = 1_920)
        val sixK = clip(2, "A002.MP4").copy(storageId = 22, pixelWidth = 6_048)
        val filters =
            MediaLibraryFilters(
                containers = setOf(MediaContainerFilter.MOV, MediaContainerFilter.MP4),
                resolutions = setOf(MediaResolutionFilter.HD, MediaResolutionFilter.SIX_K),
                storageId = 11,
            )

        assertEquals(
            listOf(hd),
            MediaLibraryFiltering.displayed(
                listOf(hd, sixK),
                MediaLibraryCategory.ALL,
                emptySet(),
                "camera",
                MediaLibrarySortOrder.NAME,
                filters,
                "20260715",
            ),
        )
        assertEquals(filters, filters.retainingAvailableStorage(MediaLibrarySource.CAMERA, listOf(hd)))
        assertNull(
            filters.retainingAvailableStorage(MediaLibrarySource.CAMERA, listOf(sixK)).storageId,
        )
        assertNull(filters.retainingAvailableStorage(MediaLibrarySource.LOCAL, listOf(hd)).storageId)
    }

    @Test
    fun `delivery metadata summary contains only bounded clip facts`() {
        val summary =
            mediaDeliveryMetadataSummary(
                listOf(clip(1, "A001.MOV", captureDate = "20260715T101010")),
            )

        assertEquals("A001.MOV · 20260715T101010 · 0MB", summary)
        assertFalse(summary.contains("camera"))

        val bounded =
            mediaDeliveryMetadataSummary(
                (1..40).map { index -> clip(index.toLong(), "A${index.toString().padStart(3, '0')}.MOV") },
            )
        assertEquals(33, bounded.lines().size)
        assertTrue(bounded.endsWith("+8 more selected items"))
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

    private fun rejoinedState(): FrameioInternetHopState.Rejoined =
        FrameioInternetHopState.Rejoined(
            FrameioCameraRejoinEvidence("Nikon ZR", "ZR", verifiedAtEpochMillis = 1L),
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
