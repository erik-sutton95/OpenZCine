package com.opencapture.openzcine.media

import com.opencapture.opencine.nikon.NikonMediaClipRecord
import com.opencapture.opencine.nikon.NikonMediaContentKind
import com.opencapture.openzcine.bridge.SwiftCore
import kotlin.coroutines.EmptyCoroutineContext
import kotlin.io.path.createTempDirectory
import com.opencapture.opencine.appkit.MonitorDeliveryAdmission
import com.opencapture.opencine.appkit.MonitorDeliveryDestination
import com.opencapture.opencine.appkit.MonitorDeliveryModel
import com.opencapture.opencine.appkit.cacheOriginals
import kotlin.coroutines.CoroutineContext
import kotlinx.coroutines.delay
import kotlinx.coroutines.CancellationException
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertTrue
import kotlinx.coroutines.test.runTest
import com.opencapture.opencine.nikon.NikonNative

// The delivery pre-pass composition the shared coordinator now runs, kept as the test driver.
/** What the delivery cache pre-pass produced, plus the clips the camera never handed over. */
private data class MediaDeliveryCachePass(
    val items: List<MediaDeliveryWorkItem>,
    val uncachedCount: Int,
)

/**
 * Pulls every selected clip that has no complete cache artifact off the camera before delivery
 * starts (iOS `MediaDeliveryRunner`'s pre-pass, `MediaDeliveryOverlay.swift`). Without it the
 * delivery paths filtered the selection down to whatever happened to be cached already, so
 * selecting ten clips with two cached shared two and dropped eight without a word.
 *
 * Sequential by contract: the Swift core serializes one PTP data channel, so a parallel pass
 * would only queue behind itself. A clip the camera still refuses is counted, never dropped
 * silently, so the run can say how many did not come across.
 */
private suspend fun cacheSelectionForDelivery(
    selection: List<MediaDeliverySelection>,
    cacheStore: MediaCacheStore,
    cameraTransferAvailable: Boolean,
    bridge: MediaObjectTransferBridge,
    ioContext: CoroutineContext = kotlinx.coroutines.Dispatchers.IO,
    pollIntervalMillis: Long = 200L,
    /** `(1-based index among clips being cached, count being cached, clip, 0…1)`. */
    onProgress: (Int, Int, MediaDeliverySelection, Double) -> Unit = { _, _, _, _ -> },
): MediaDeliveryCachePass {
    val originals = NikonDeliveryOriginals(selection, cacheStore, cameraTransferAvailable,
        bridge, MonitorDeliveryAdmission { true }, ioContext, pollIntervalMillis)
    originals.loadCompleteEntries()
    val missing = selection.filter { !originals.service.available(it) }
    val cached = MonitorDeliveryModel.cacheOriginals(
        records = selection, destination = MonitorDeliveryDestination.NATIVE_SHARE,
        admission = originals.admission, originals = originals.service,
        filename = { it.clip.filename }, sleep = { delay(pollIntervalMillis) },
        progress = { value ->
            if (cameraTransferAvailable) missing.getOrNull(value.clipIndex - 1)?.let { item ->
                onProgress(value.clipIndex, value.totalClips, item, value.clipFraction)
            }
        },
    ) ?: throw CancellationException("Delivery cache source retired.")
    val items = cached.ready.mapNotNull(originals::workItem)
    return MediaDeliveryCachePass(items, uncachedCount = selection.size - items.size)
}

/**
 * The delivery cache pre-pass: every selected clip reaches the destination, and the ones the
 * camera would not give up are counted rather than dropped in silence.
 */
class MediaDeliveryCachePassTest {
    @Test
    fun `clips still on the camera are cached before delivery instead of being dropped`() = runTest {
        withStore { store ->
            val cached = clip(handle = 1, filename = "A001.MOV")
            val onCamera = listOf(clip(2, "A002.MOV"), clip(3, "A003.MOV"))
            store.openEntry(CAMERA, MediaCacheObjectIdentity(cached), cached.sizeBytes).apply {
                append(0, SAMPLE)
                complete()
            }
            val bridge = FakeTransferBridge()
            val progress = mutableListOf<Pair<Int, Int>>()

            val pass =
                cacheSelectionForDelivery(
                    selection = (listOf(cached) + onCamera).map { MediaDeliverySelection(CAMERA, it) },
                    cacheStore = store,
                    cameraTransferAvailable = true,
                    bridge = bridge,
                    ioContext = EmptyCoroutineContext,
                    pollIntervalMillis = 1,
                ) { index, count, _, _ -> progress += index to count }

            assertEquals(listOf("A001.MOV", "A002.MOV", "A003.MOV"), pass.items.map { it.clip.filename })
            assertEquals(0, pass.uncachedCount)
            assertEquals(listOf(2, 3), bridge.startedHandles)
            // Progress counts only the clips actually being pulled off the camera (iOS `toCache`).
            assertEquals(listOf(1 to 2, 2 to 2), progress.distinct())
        }
    }

    @Test
    fun `a clip the camera refuses is reported, and the rest of the run still delivers`() = runTest {
        withStore { store ->
            val refused = clip(2, "A002.MOV")
            val bridge = FakeTransferBridge(failingHandles = setOf(2))

            val pass =
                cacheSelectionForDelivery(
                    selection =
                        listOf(clip(1, "A001.MOV"), refused).map { MediaDeliverySelection(CAMERA, it) },
                    cacheStore = store,
                    cameraTransferAvailable = true,
                    bridge = bridge,
                    ioContext = EmptyCoroutineContext,
                    pollIntervalMillis = 1,
                )

            assertEquals(listOf("A001.MOV"), pass.items.map { it.clip.filename })
            assertEquals(1, pass.uncachedCount)
            assertTrue(bridge.stopCount > 0, "a refused transfer is torn down, not left running")
            assertEquals("1 clip couldn't be cached from the camera.", uncachedClipsMessage(1))
        }
    }

    @Test
    fun `a disconnected camera caches nothing and never opens a transfer`() = runTest {
        withStore { store ->
            val bridge = FakeTransferBridge()

            val pass =
                cacheSelectionForDelivery(
                    selection = listOf(MediaDeliverySelection(CAMERA, clip(1, "A001.MOV"))),
                    cacheStore = store,
                    cameraTransferAvailable = false,
                    bridge = bridge,
                    ioContext = EmptyCoroutineContext,
                    pollIntervalMillis = 1,
                )

            assertEquals(0, pass.items.size)
            assertEquals(1, pass.uncachedCount)
            assertEquals(emptyList<Int>(), bridge.startedHandles)
        }
    }

    private suspend fun withStore(block: suspend (MediaCacheStore) -> Unit) {
        val root = createTempDirectory("openzcine-delivery-cache-pass")
        try {
            block(MediaCacheStore(root.resolve("media-cache")))
        } finally {
            root.toFile().deleteRecursively()
        }
    }

    private fun clip(handle: Long, filename: String): NikonMediaClipRecord =
        NikonMediaClipRecord(
            handle = handle,
            storageId = 0x0001_0001,
            sizeBytes = SAMPLE.size.toLong(),
            captureDate = "20260808T101010",
            pixelWidth = 1920,
            pixelHeight = 1080,
            filename = filename,
            contentKind = NikonMediaContentKind.PLAYABLE_PROXY,
            stillPhoto = null,
        )

    /** Delivers the whole object synchronously, the way the Swift pump does for a small clip. */
    private class FakeTransferBridge(
        private val failingHandles: Set<Int> = emptySet(),
    ) : MediaObjectTransferBridge {
        override val isAvailable: Boolean = true
        val startedHandles = mutableListOf<Int>()
        var stopCount = 0

        override fun resolveMediaSize(handle: Int, reportedSize: Long): Long = reportedSize

        override fun startMediaTransfer(
            handle: Int,
            reportedSize: Long,
            resumeOffset: Long,
            listener: NikonNative.MediaTransferListener,
        ) {
            startedHandles += handle
            if (handle in failingHandles) {
                listener.onFailed("Camera refused the transfer.")
                return
            }
            listener.onStarted(reportedSize)
            check(listener.onChunk(resumeOffset, SAMPLE))
            listener.onCompleted(reportedSize)
        }

        override fun stopMediaTransfer() {
            stopCount += 1
        }
    }

    private companion object {
        const val CAMERA = "ZR-6001234"
        val SAMPLE = byteArrayOf(1, 2, 3, 4)
    }
}
