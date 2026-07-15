package com.opencapture.openzcine.media

import com.opencapture.openzcine.bridge.SwiftCore
import java.nio.file.Files
import kotlin.io.path.createTempDirectory
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertIs
import kotlin.test.assertTrue

/** Regression coverage for the one generic cache listener used by clips and stills. */
class MediaObjectTransferTest {
    @Test
    fun `proxy and still share one generic transfer bridge and validated cache listener`() {
        val root = createTempDirectory("openzcine-object-transfer")
        try {
            val bridge = RecordingTransferBridge()
            val cacheStore = MediaCacheStore(root)

            val proxy =
                mediaRecord(
                    handle = 0x1001,
                    filename = "C0001.MOV",
                    contentKind = MediaContentKind.PLAYABLE_PROXY,
                )
            val still =
                mediaRecord(
                    handle = 0x1008,
                    filename = "DSC_0007.JPG",
                    contentKind = MediaContentKind.STILL_PHOTO,
                    stillPhoto = StillPhotoClassification("JPEG", StillPreviewStrategy.PROGRESSIVE),
                )

            val proxyResult =
                assertIs<MediaTransferPreparation.Ready>(
                    prepareMediaObjectTransfer(
                        cacheStore = cacheStore,
                        cameraID = "ZR-6001234",
                        clip = proxy,
                        objectLabel = "clip",
                        bridge = bridge,
                    ),
                )
            val stillResult =
                assertIs<MediaTransferPreparation.Ready>(
                    prepareMediaObjectTransfer(
                        cacheStore = cacheStore,
                        cameraID = "ZR-6001234",
                        clip = still,
                        objectLabel = "image",
                        bridge = bridge,
                    ),
                )

            assertEquals(
                listOf(StartedTransfer(0x1001, 0), StartedTransfer(0x1008, 0)),
                bridge.started,
            )
            assertEquals(MediaCacheState.COMPLETE, proxyResult.entry.state)
            assertEquals(MediaCacheState.COMPLETE, stillResult.entry.state)
            assertEquals(4L, proxyResult.entry.downloadedBytes)
            assertEquals(4L, stillResult.entry.downloadedBytes)
        } finally {
            Files.walk(root).use { paths ->
                paths.sorted(Comparator.reverseOrder()).forEach(Files::deleteIfExists)
            }
        }
    }

    @Test
    fun `complete cache opens while disconnected and a stale artifact fails closed`() {
        val root = createTempDirectory("openzcine-offline-object")
        try {
            val cacheStore = MediaCacheStore(root)
            val clip =
                mediaRecord(
                    handle = 0x2001,
                    filename = "OFFLINE.MOV",
                    contentKind = MediaContentKind.PLAYABLE_PROXY,
                )
            val identity = MediaCacheObjectIdentity(clip)
            val complete = cacheStore.openEntry("camera", identity, clip.sizeBytes)
            complete.append(0, byteArrayOf(1, 2, 3, 4))
            complete.complete()
            val disconnected = UnavailableTransferBridge()

            val ready =
                assertIs<MediaTransferPreparation.Ready>(
                    prepareMediaObjectTransfer(
                        cacheStore,
                        "camera",
                        clip,
                        "clip",
                        disconnected,
                        cameraTransferAvailable = false,
                    ),
                )

            assertEquals(complete.finalPath, ready.entry.finalPath)
            assertEquals(0, disconnected.resolveCalls)
            Files.delete(ready.entry.finalPath)

            val stale =
                assertIs<MediaTransferPreparation.Failed>(
                    prepareMediaObjectTransfer(
                        cacheStore,
                        "camera",
                        clip,
                        "clip",
                        disconnected,
                        cameraTransferAvailable = false,
                    ),
                )
            assertTrue(stale.message.contains("no longer available"))
            assertEquals(0, disconnected.resolveCalls)
            assertEquals(0, Files.walk(root).use { paths -> paths.filter(Files::isRegularFile).count() })
        } finally {
            Files.walk(root).use { paths ->
                paths.sorted(Comparator.reverseOrder()).forEach(Files::deleteIfExists)
            }
        }
    }

    private fun mediaRecord(
        handle: Long,
        filename: String,
        contentKind: MediaContentKind,
        stillPhoto: StillPhotoClassification? = null,
    ): MediaClipRecord =
        MediaClipRecord(
            handle = handle,
            storageId = 0x0001_0001,
            sizeBytes = 4,
            captureDate = "20260715T101010",
            pixelWidth = 1,
            pixelHeight = 1,
            filename = filename,
            contentKind = contentKind,
            stillPhoto = stillPhoto,
        )

    private class RecordingTransferBridge : MediaObjectTransferBridge {
        override val isAvailable: Boolean = true
        val started = mutableListOf<StartedTransfer>()

        override fun resolveMediaSize(handle: Int, reportedSize: Long): Long = reportedSize

        override fun startMediaTransfer(
            handle: Int,
            reportedSize: Long,
            resumeOffset: Long,
            listener: SwiftCore.MediaTransferListener,
        ) {
            started += StartedTransfer(handle, resumeOffset)
            listener.onStarted(reportedSize)
            check(listener.onChunk(resumeOffset, byteArrayOf(1, 2, 3, 4)))
            listener.onCompleted(reportedSize)
        }
    }

    private class UnavailableTransferBridge : MediaObjectTransferBridge {
        override val isAvailable: Boolean = false
        var resolveCalls = 0

        override fun resolveMediaSize(handle: Int, reportedSize: Long): Long {
            resolveCalls += 1
            return reportedSize
        }

        override fun startMediaTransfer(
            handle: Int,
            reportedSize: Long,
            resumeOffset: Long,
            listener: SwiftCore.MediaTransferListener,
        ) = error("A disconnected cache must never start a camera transfer.")
    }

    private data class StartedTransfer(
        val handle: Int,
        val resumeOffset: Long,
    )
}
