package com.opencapture.openzcine.media

import com.opencapture.opencine.appkit.MonitorDeliveryAdmission
import com.opencapture.opencine.appkit.MonitorDeliveryDestination
import com.opencapture.opencine.appkit.MonitorDeliveryModel
import com.opencapture.opencine.appkit.cacheOriginals
import com.opencapture.opencine.nikon.NikonMediaClipRecord
import com.opencapture.opencine.nikon.NikonMediaContentKind
import com.opencapture.opencine.nikon.NikonNative
import kotlin.coroutines.EmptyCoroutineContext
import kotlin.io.path.createTempDirectory
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNotNull
import kotlin.test.assertNull
import kotlinx.coroutines.test.runTest

/** SIMULATED native bridge; the actual Nikon cache adapter retains its real cache/cleanup paths. */
class NikonDeliveryOriginalAdmissionTest {
    @Test fun currentReceiptCachesThroughItsCapturedNativeBridge() = runTest {
        withStore { store ->
            val selected = selection()
            val bridge = Bridge()
            val source = originals(store, selected, bridge, { true })
            source.loadCompleteEntries()
            val result = MonitorDeliveryModel.cacheOriginals(listOf(selected), MonitorDeliveryDestination.NATIVE_SHARE,
                source.admission, source.service, { it.clip.filename }, progress = {})
            assertNotNull(result)
            assertEquals(listOf(selected), result.ready)
            assertEquals(1, bridge.starts)
            assertEquals(0, bridge.stops)
            assertEquals(4L, source.workItem(selected)?.entry?.expectedLength)
        }
    }
    @Test fun cachedOfflineReceiptNeedsNoNativeBridgeOrReplacementOwner() = runTest {
        withStore { store ->
            val selected = selection()
            store.openEntry(selected.cameraID, MediaCacheObjectIdentity(selected.clip), 4).apply {
                append(0, bytes); complete()
            }
            val bridge = Bridge()
            val source = originals(store, selected, bridge, { true }, connected = false)
            source.loadCompleteEntries()
            val result = MonitorDeliveryModel.cacheOriginals(listOf(selected), MonitorDeliveryDestination.NATIVE_SHARE,
                source.admission, source.service, { it.clip.filename }, progress = {})
            assertEquals(listOf(selected), result?.ready)
            assertEquals(0, bridge.starts)
            assertEquals(0, bridge.resolutions)
        }
    }
    @Test fun progressReplacementRefusesBeforeFirstNativeSizeOrStart() = runTest {
        withStore { store ->
            val selected = selection(); val bridge = Bridge(); var epoch = 1
            val source = originals(store, selected, bridge, { epoch == 1 })
            source.loadCompleteEntries()
            val result = MonitorDeliveryModel.cacheOriginals(listOf(selected), MonitorDeliveryDestination.NATIVE_SHARE,
                source.admission, source.service, { it.clip.filename }, progress = { epoch = 2 })
            assertNull(result)
            assertEquals(0, bridge.resolutions)
            assertEquals(0, bridge.starts)
        }
    }
    @Test fun replacementInsideSizeResolutionRefusesActualUnsentStart() = runTest {
        withStore { store ->
            val selected = selection(); var epoch = 1
            val bridge = Bridge(onResolve = { epoch = 2 })
            val source = originals(store, selected, bridge, { epoch == 1 })
            source.loadCompleteEntries()
            val result = MonitorDeliveryModel.cacheOriginals(listOf(selected), MonitorDeliveryDestination.NATIVE_SHARE,
                source.admission, source.service, { it.clip.filename }, progress = {})
            assertNull(result)
            assertEquals(1, bridge.resolutions)
            assertEquals(0, bridge.starts)
            assertEquals(1, bridge.stops)
        }
    }
    @Test fun enteredCompletionRetainsOriginalCacheButCannotPublishIntoSuccessor() = runTest {
        withStore { store ->
            val selected = selection(); var epoch = 1
            val bridge = Bridge(onStart = { epoch = 2 })
            val source = originals(store, selected, bridge, { epoch == 1 })
            source.loadCompleteEntries()
            val result = MonitorDeliveryModel.cacheOriginals(listOf(selected), MonitorDeliveryDestination.NATIVE_SHARE,
                source.admission, source.service, { it.clip.filename }, progress = {})
            assertNull(result)
            assertEquals(1, bridge.starts)
            assertEquals(0, bridge.stops)
            assertNotNull(store.completedEntryOrNull(selected.cameraID, MediaCacheObjectIdentity(selected.clip), 4))
        }
    }
    @Test fun enteredABACannotSendNextSelectedClipOrReleaseSuccessorCredit() = runTest {
        withStore { store ->
            val first = selection(); val second = selection(2); var epoch = 1
            val bridge = Bridge(onStart = { epoch = 3 })
            val source = NikonDeliveryOriginals(listOf(first, second), store, true, bridge,
                MonitorDeliveryAdmission { epoch == 1 }, EmptyCoroutineContext, 1)
            source.loadCompleteEntries()
            val result = MonitorDeliveryModel.cacheOriginals(listOf(first, second), MonitorDeliveryDestination.NATIVE_SHARE,
                source.admission, source.service, { it.clip.filename }, progress = {})
            assertNull(result)
            assertEquals(1, bridge.starts)
            assertNull(source.workItem(second))
            assertEquals(0, bridge.stops)
        }
    }
    private fun originals(store: MediaCacheStore, selection: MediaDeliverySelection, bridge: Bridge,
        current: () -> Boolean, connected: Boolean = true) = NikonDeliveryOriginals(listOf(selection), store,
            connected, bridge, MonitorDeliveryAdmission(current), EmptyCoroutineContext, 1)
    private suspend fun withStore(operation: suspend (MediaCacheStore) -> Unit) {
        val root = createTempDirectory("SIMULATED-nikon-delivery-admission")
        try { operation(MediaCacheStore(root)) } finally { root.toFile().deleteRecursively() }
    }
    private fun selection(handle: Long = 1) = MediaDeliverySelection("SIMULATED-A", NikonMediaClipRecord(
        handle, 1, 4, "20261007T120000", 1920, 1080, "A$handle.MOV", NikonMediaContentKind.PLAYABLE_PROXY, null))
    private class Bridge(val onResolve: () -> Unit = {}, val onStart: () -> Unit = {}) : MediaObjectTransferBridge {
        override val isAvailable = true
        var resolutions = 0; var starts = 0; var stops = 0
        override fun resolveMediaSize(handle: Int, reportedSize: Long): Long {
            resolutions++; onResolve(); return reportedSize
        }
        override fun startMediaTransfer(handle: Int, reportedSize: Long, resumeOffset: Long,
            listener: NikonNative.MediaTransferListener) {
            starts++; onStart(); listener.onStarted(reportedSize)
            check(listener.onChunk(resumeOffset, bytes)); listener.onCompleted(reportedSize)
        }
        override fun stopMediaTransfer() { stops++ }
    }
    private companion object { val bytes = byteArrayOf(1, 2, 3, 4) }
}
