package com.opencapture.openzcine

import android.graphics.Bitmap
import android.graphics.Color
import androidx.test.ext.junit.runners.AndroidJUnit4
import com.opencapture.opencine.media.FeedIncidentBreadcrumb
import com.opencapture.opencine.media.FeedIncidentLifecycle
import com.opencapture.opencine.media.FeedIncidentSnapshot
import com.opencapture.opencine.media.FeedIncidentSource
import com.opencapture.opencine.media.FeedRepairRecord
import com.opencapture.opencine.nikon.LiveFrame
import com.opencapture.opencine.runtime.MonitorFramePacingStats
import com.opencapture.opencine.runtime.MonitorJpegFrameDecoder
import com.opencapture.opencine.runtime.monitorPumpFramesWithSourceFrame
import com.opencapture.openzcine.diagnostics.NikonFeedIncidentProducer
import java.io.ByteArrayOutputStream
import java.util.concurrent.atomic.AtomicLong
import kotlinx.coroutines.flow.flowOf
import kotlinx.coroutines.runBlocking
import org.junit.Test
import org.junit.runner.RunWith
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNotNull
import kotlin.test.assertNull
import kotlin.test.assertTrue

/** SIMULATED source owners over the actual shared pump/JPEG decoder; no JNI camera or scanout. */
@RunWith(AndroidJUnit4::class)
class NikonFeedIncidentProducerTest {
    @Test fun consumingJPEGCallbackReportsDecodeWithoutInventingPacketsAcceptanceOrPresentation() = runBlocking {
        val source = RecordingSource()
        val owner = AtomicLong(1)
        val producer = NikonFeedIncidentProducer(source, { owner.get() == 1L }, { 10.0 })
        try {
            val frame = LiveFrame(1, jpeg())
            producer.received() // The existing generation-filtered health collector observes delivery.
            pump(frame, producer)
            producer.publish(FeedIncidentLifecycle(connected = true))
            val sample = source.snapshots.single()
            assertEquals(0.0, sample.ages.accessUnitAge)
            assertEquals(0.0, sample.ages.decodedOutputAge)
            assertNull(sample.ages.packetAge)
            assertNull(sample.ages.decodeAcceptAge)
            assertNull(sample.ages.presentAge)
            assertNull(sample.ingress)
            assertTrue(sample.lifecycle.outputObservable)
            assertTrue(sample.lifecycle.liveEstablished)
            assertFalse(sample.lifecycle.presentationExpected)
        } finally { producer.end() }
        assertEquals(1, source.ends)
    }

    @Test fun retiredCapturedDecodeCompletionCannotPopulateSuccessorOwner() = runBlocking {
        val owner = AtomicLong(1)
        val oldSource = RecordingSource()
        val currentSource = RecordingSource()
        val old = NikonFeedIncidentProducer(oldSource, { owner.get() == 1L }, { 10.0 })
        val current = NikonFeedIncidentProducer(currentSource, { owner.get() == 2L }, { 11.0 })
        try {
            old.received()
            val frame = LiveFrame(1, jpeg())
            val decoder = MonitorJpegFrameDecoder()
            monitorPumpFramesWithSourceFrame(frames = flowOf(frame), stats = MonitorFramePacingStats(log = {}),
                timestampNanos = { it.timestampNanos },
                decode = { input -> old.decode {
                    val output = decoder.decode(input.jpegData)
                    // Retire after native decode, before the captured completion publishes facts.
                    old.end()
                    owner.set(2)
                    output
                } },
                present = { _, bitmap -> assertNotNull(bitmap); old.published() })
            old.publish(FeedIncidentLifecycle(connected = true))
            current.publish(FeedIncidentLifecycle(connected = true))
            assertTrue(oldSource.snapshots.isEmpty())
            val before = currentSource.snapshots.single()
            assertNull(before.ages.accessUnitAge)
            assertNull(before.ages.decodedOutputAge)
            assertFalse(before.lifecycle.outputObservable)
            assertFalse(before.lifecycle.liveEstablished)
            current.received()
            pump(LiveFrame(2, jpeg()), current)
            current.publish(FeedIncidentLifecycle(connected = true))
            assertEquals(0.0, currentSource.snapshots.last().ages.decodedOutputAge)
            assertTrue(currentSource.snapshots.last().lifecycle.outputObservable)
            assertNull(currentSource.snapshots.last().ages.presentAge)
        } finally { old.end(); current.end() }
        assertEquals(1, oldSource.ends)
        assertEquals(1, currentSource.ends)
    }

    @Test fun knownOwnerReplacementRejectsOldDeliveryAndDecoderFactsBeforeLifecycleDisposal() = runBlocking {
        val owner = AtomicLong(1)
        val source = RecordingSource()
        val old = NikonFeedIncidentProducer(source, { owner.get() == 1L }, { 10.0 })
        try {
            owner.set(2)
            old.received()
            pump(LiveFrame(1, jpeg()), old)
            val before = old.snapshot(FeedIncidentLifecycle(connected = true))
            assertNull(before.ages.accessUnitAge)
            assertNull(before.ages.decodedOutputAge)
            assertFalse(before.lifecycle.liveEstablished)
            old.publish(FeedIncidentLifecycle(connected = true))
            assertTrue(source.snapshots.isEmpty())
        } finally { old.end() }
    }

    private suspend fun pump(frame: LiveFrame, captured: NikonFeedIncidentProducer) {
        val decoder = MonitorJpegFrameDecoder()
        monitorPumpFramesWithSourceFrame(frames = flowOf(frame), stats = MonitorFramePacingStats(log = {}),
            timestampNanos = { it.timestampNanos }, decode = { captured.decode { decoder.decode(it.jpegData) } },
            present = { _, bitmap -> assertNotNull(bitmap); captured.published() })
    }

    private fun jpeg(): ByteArray {
        val bitmap = Bitmap.createBitmap(32, 24, Bitmap.Config.ARGB_8888)
        bitmap.eraseColor(Color.YELLOW)
        return ByteArrayOutputStream().use { stream ->
            try { check(bitmap.compress(Bitmap.CompressFormat.JPEG, 90, stream)); stream.toByteArray() }
            finally { bitmap.recycle() }
        }
    }

    private class RecordingSource : FeedIncidentSource {
        val snapshots = mutableListOf<FeedIncidentSnapshot>()
        var ends = 0
        override fun ingestSnapshot(snapshot: FeedIncidentSnapshot) { snapshots += snapshot }
        override fun endSession(nowSeconds: Double) { ends++ }
        override fun recordBreadcrumb(breadcrumb: FeedIncidentBreadcrumb) = Unit
        override fun recordRepair(repair: FeedRepairRecord) = Unit
        override fun noteDecoderGeneration(generation: Int) = Unit
        override fun noteSocketGeneration(generation: Int) = Unit
        override fun noteExhausted(nowSeconds: Double) = Unit
        override fun noteUnexpectedDisconnect(nowSeconds: Double) = Unit
    }
}
