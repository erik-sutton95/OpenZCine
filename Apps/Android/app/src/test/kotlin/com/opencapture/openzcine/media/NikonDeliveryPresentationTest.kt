@file:OptIn(kotlinx.coroutines.ExperimentalCoroutinesApi::class)

package com.opencapture.openzcine.media

import com.opencapture.openzcine.frameio.FrameioDeliveryState
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNull
import kotlin.test.assertTrue
import kotlin.time.Duration.Companion.milliseconds
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.Job
import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.launch
import kotlinx.coroutines.flow.collect
import kotlinx.coroutines.test.UnconfinedTestDispatcher
import kotlinx.coroutines.test.runCurrent
import kotlinx.coroutines.test.runTest
import kotlinx.coroutines.withContext

/** SIMULATED actual app intent composition; original wire/staging tests remain unchanged. */
class NikonDeliveryPresentationTest {
    private fun progress(name: String, caching: Boolean = false) = MediaDeliveryOverlayState(
        MediaDeliveryKind.FRAMEIO, 2, 1, 0.5, name, caching)
    private fun uploadingState(name: String) = FrameioDeliveryState.Uploading(1, 2, name, 0.7)

    @Test fun `native replacement retains admitted external raw job and cancel reaches both`() = runTest {
        val owner = NikonDeliveryPresentation(backgroundScope)
        val uploadJob = Job()
        val upload = owner.trackExternalDelivery(uploadJob)
        val first = CompletableDeferred<Unit>()
        val successor = CompletableDeferred<Unit>()
        owner.beginNative { report -> report(progress("first-native")); first.await(); null }
        runCurrent()
        assertEquals("first-native", owner.overlayState?.filename)
        owner.beginNative { report -> report(progress("successor-native")); successor.await(); null }
        runCurrent()
        assertTrue(uploadJob.isActive)
        assertEquals("successor-native", owner.overlayState?.filename)
        owner.cancel()
        runCurrent()
        assertTrue(uploadJob.isCancelled)
        assertFalse(owner.nativeRunning)
        assertNull(owner.overlayState)
        owner.publishCache(upload, progress("retired"))
        assertNull(owner.overlayState)
        owner.close()
    }

    @Test fun `upload observer is suppressed while external cache retains donor publication order`() = runTest {
        val owner = NikonDeliveryPresentation(backgroundScope)
        val uploadJob = Job()
        val upload = owner.trackExternalDelivery(uploadJob)
        val finishNative = CompletableDeferred<Unit>()
        owner.beginNative { report -> report(progress("native")); finishNative.await(); null }
        runCurrent()
        owner.bindFrameioDeliveryState(upload, uploadingState("suppressed"))
        assertEquals("native", owner.overlayState?.filename)
        owner.publishCache(upload, progress("actual-cache", caching = true))
        assertEquals("actual-cache", owner.overlayState?.filename)
        assertTrue(owner.overlayState!!.isCaching)
        finishNative.complete(Unit)
        runCurrent()
        assertNull(owner.overlayState)
        assertTrue(uploadJob.isActive)
        owner.bindFrameioDeliveryState(upload, uploadingState("next-admitted-observation"))
        assertEquals("next-admitted-observation", owner.overlayState?.filename)
        owner.close()
        assertTrue(uploadJob.isCancelled)
    }

    @Test fun `old surface finally and captured report cannot clear successor raw handle or progress`() = runTest {
        val owner = NikonDeliveryPresentation(backgroundScope)
        val oldJob = Job()
        val old = owner.trackExternalDelivery(oldJob)
        runCurrent()
        owner.publishCache(old, progress("old", caching = true))
        val newJob = Job()
        val successor = owner.trackExternalDelivery(newJob)
        runCurrent()
        owner.publishCache(successor, progress("successor", caching = true))
        owner.finishExternalDelivery(old)
        owner.bindFrameioDeliveryState(old, FrameioDeliveryState.Completed(9, 0))
        owner.publishCache(old, progress("late-old"))
        runCurrent()
        assertEquals("successor", owner.overlayState?.filename)
        assertNull(owner.completionToast)
        assertTrue(newJob.isActive)
        assertTrue(oldJob.isActive)
        owner.cancel()
        assertTrue(newJob.isCancelled)
        assertTrue(oldJob.isActive)
        oldJob.cancel()
        owner.close()
    }

    @Test fun `raw cancellation callback registers successor without outgoing cancellation writes`() = runTest {
        val owner = NikonDeliveryPresentation(backgroundScope)
        val oldJob = Job()
        owner.trackExternalDelivery(oldJob)
        runCurrent()
        val successorJob = Job()
        lateinit var successor: NikonDeliveryPresentation.ExternalTicket
        oldJob.invokeOnCompletion { successor = owner.trackExternalDelivery(successorJob) }
        owner.cancel()
        runCurrent()
        owner.publishCache(successor, progress("replacement-after-cancel"))
        assertTrue(oldJob.isCancelled)
        assertTrue(successorJob.isActive)
        assertEquals("replacement-after-cancel", owner.overlayState?.filename)
        owner.close()
        assertTrue(successorJob.isCancelled)
    }

    @Test fun `retired noncancellable native completion cannot publish over actual successor`() = runTest {
        val owner = NikonDeliveryPresentation(backgroundScope)
        val retired = CompletableDeferred<Unit>()
        val successor = CompletableDeferred<Unit>()
        owner.beginNative { report ->
            report(progress("retired-initial"))
            withContext(NonCancellable) { retired.await() }
            report(progress("retired-late"))
            "retired-toast"
        }
        runCurrent()
        owner.beginNative { report -> report(progress("successor")); successor.await(); "successor-toast" }
        runCurrent()
        retired.complete(Unit)
        runCurrent()
        assertEquals("successor", owner.overlayState?.filename)
        assertNull(owner.completionToast)
        assertTrue(owner.nativeRunning)
        successor.complete(Unit)
        runCurrent()
        assertNull(owner.overlayState)
        assertEquals("successor-toast", owner.completionToast)
        owner.close()
    }

    @Test fun `current caching finally clears only its bar while completed upload retains terminal ownership`() = runTest {
        val owner = NikonDeliveryPresentation(backgroundScope)
        val job = Job()
        val cache = owner.trackExternalDelivery(job)
        runCurrent()
        owner.publishCache(cache, progress("cache", caching = true))
        owner.finishExternalDelivery(cache)
        runCurrent()
        assertNull(owner.overlayState)
        assertTrue(job.isActive)
        val uploadJob = Job()
        val upload = owner.trackExternalDelivery(uploadJob)
        runCurrent()
        owner.bindFrameioDeliveryState(upload, uploadingState("upload"))
        owner.finishExternalDelivery(upload)
        runCurrent()
        assertEquals("upload", owner.overlayState?.filename)
        owner.bindFrameioDeliveryState(upload, FrameioDeliveryState.Completed(2, 1, 3))
        runCurrent()
        assertNull(owner.overlayState)
        assertEquals("Uploaded 2, 1 failed, 3 skipped", owner.completionToast)
        owner.close()
        job.cancel()
        uploadJob.cancel()
    }

    @Test fun `same text replacement toast retires old timer and preserves expanded state`() = runTest {
        val waits = mutableListOf<CompletableDeferred<Unit>>()
        val owner = NikonDeliveryPresentation(backgroundScope) { duration ->
            assertEquals(2500.milliseconds, duration)
            val wait = CompletableDeferred<Unit>()
            waits += wait
            withContext(NonCancellable) { wait.await() }
        }
        owner.isExpanded = true
        owner.showToast("same sentence")
        runCurrent()
        owner.showToast("same sentence")
        runCurrent()
        assertEquals(2, waits.size)
        waits[0].complete(Unit)
        runCurrent()
        assertEquals("same sentence", owner.completionToast)
        assertTrue(owner.isExpanded)
        waits[1].complete(Unit)
        runCurrent()
        assertNull(owner.completionToast)
        assertTrue(owner.isExpanded)
        owner.close()
    }

    @Test fun `actual display collector replacement survives outgoing native notification`() = runTest {
        val owner = NikonDeliveryPresentation(backgroundScope)
        val outgoing = CompletableDeferred<Unit>()
        val successor = CompletableDeferred<Unit>()
        var replaced = false
        val observer = backgroundScope.launch(UnconfinedTestDispatcher(testScheduler)) {
            owner.display.collect { state ->
                if (!replaced && state.overlay?.filename == "outgoing") {
                    replaced = true
                    owner.beginNative { report ->
                        report(progress("collector-successor"))
                        successor.await()
                        null
                    }
                }
            }
        }
        owner.beginNative { report ->
            report(progress("outgoing"))
            withContext(NonCancellable) { outgoing.await() }
            report(progress("outgoing-late"))
            "outgoing-toast"
        }
        runCurrent()
        assertTrue(replaced)
        outgoing.complete(Unit)
        runCurrent()
        assertEquals("collector-successor", owner.overlayState?.filename)
        assertNull(owner.completionToast)
        assertTrue(owner.nativeRunning)
        observer.cancel()
        successor.complete(Unit)
        runCurrent()
        owner.close()
    }

    @Test fun `pre hop captured preparation has no upload handle and root close retires late facts`() = runTest {
        val owner = NikonDeliveryPresentation(backgroundScope)
        val preparation = owner.trackExternalDelivery(null)
        runCurrent()
        owner.publishCache(preparation, progress("pre-hop", caching = true))
        assertEquals("pre-hop", owner.overlayState?.filename)
        owner.close()
        owner.publishCache(preparation, progress("late-pre-hop"))
        owner.bindFrameioDeliveryState(preparation, FrameioDeliveryState.Completed(1, 0))
        runCurrent()
        assertNull(owner.overlayState)
        assertNull(owner.completionToast)
    }
}
