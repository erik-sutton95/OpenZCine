package com.opencapture.openzcine.media

import com.opencapture.openzcine.bridge.SwiftCore
import java.nio.file.Files
import kotlin.io.path.createTempDirectory
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertIs

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

    private data class StartedTransfer(
        val handle: Int,
        val resumeOffset: Long,
    )
}
