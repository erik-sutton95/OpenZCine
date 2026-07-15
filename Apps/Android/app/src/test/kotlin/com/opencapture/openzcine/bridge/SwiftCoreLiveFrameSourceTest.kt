package com.opencapture.openzcine.bridge

import com.opencapture.openzcine.core.LiveFrame
import java.util.concurrent.atomic.AtomicBoolean
import kotlin.test.Test
import kotlin.test.assertContentEquals
import kotlin.test.assertEquals
import kotlin.test.assertTrue
import kotlin.test.fail
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.async
import kotlinx.coroutines.cancelAndJoin
import kotlinx.coroutines.flow.collect
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.launch
import kotlinx.coroutines.test.runCurrent
import kotlinx.coroutines.test.runTest

/**
 * Pure marshaling behavior with injected start/stop hooks — the native pump
 * itself is tested in Swift against the fake ZR
 * (`Tests/OpenZCineAndroidFacadeTests/LiveViewPumpTests.swift`).
 */
@OptIn(ExperimentalCoroutinesApi::class)
class SwiftCoreLiveFrameSourceTest {
    @Test
    fun `does not start or stop without the native core`() = runTest {
        val source =
            SwiftCoreLiveFrameSource(
                available = { false },
                start = { fail("must not start live view without the native library") },
                stop = { fail("must not stop live view without the native library") },
                sharingScope = backgroundScope,
            )

        val collection = launch { source.frames.collect() }
        runCurrent()
        collection.cancelAndJoin()
    }

    @Test
    fun `bridges callbacks into frames recording state and camera audio`() = runTest {
        val jpeg = byteArrayOf(1, 2, 3)
        lateinit var listener: SwiftCore.LiveFrameListener
        var recordingState: Boolean? = null
        val source =
            SwiftCoreLiveFrameSource(
                available = { true },
                start = { listener = it },
                stop = {},
                sharingScope = backgroundScope,
                onRecordingState = { recordingState = it },
            )

        val result = async { source.frames.first() }
        runCurrent()
        listener.onFrame(
            jpeg = jpeg,
            timestampNanos = 7L,
            isRecording = true,
            leftLevelDb = -24.0,
            leftPeakDb = -6.0,
            rightLevelDb = -36.0,
            rightPeakDb = -18.0,
            hasAudioLevels = true,
        )
        runCurrent()
        val frame = result.await()

        assertContentEquals(jpeg, frame.jpegData)
        assertEquals(7L, frame.timestampNanos)
        assertTrue(frame.isRecording)
        assertEquals(true, recordingState)
        assertEquals(-24.0, frame.audioLevels?.left?.levelDb)
        assertEquals(-6.0, frame.audioLevels?.left?.peakDb)
        assertEquals(-36.0, frame.audioLevels?.right?.levelDb)
        assertEquals(-18.0, frame.audioLevels?.right?.peakDb)
        assertEquals(false, frame.audioLevels?.isDebugFixture)
    }

    @Test
    fun `missing camera audio remains unavailable rather than synthetic silence`() = runTest {
        lateinit var listener: SwiftCore.LiveFrameListener
        val source =
            SwiftCoreLiveFrameSource(
                available = { true },
                start = { listener = it },
                stop = {},
                sharingScope = backgroundScope,
            )

        val result = async { source.frames.first() }
        runCurrent()
        listener.onFrame(byteArrayOf(4), 8L, false)
        runCurrent()

        assertEquals(null, result.await().audioLevels)
    }

    @Test
    fun `two collectors share one pump and the last cancellation stops it`() = runTest {
        var starts = 0
        var stops = 0
        lateinit var listener: SwiftCore.LiveFrameListener
        val source =
            SwiftCoreLiveFrameSource(
                available = { true },
                start = {
                    starts++
                    listener = it
                },
                stop = { stops++ },
                sharingScope = backgroundScope,
            )

        val feed = async { source.frames.first() }
        val scope = async { source.frames.first() }
        runCurrent()
        assertEquals(1, starts)
        assertEquals(0, stops)

        listener.onFrame(byteArrayOf(1), 1L, false)
        runCurrent()
        feed.await()
        scope.await()
        runCurrent()

        assertEquals(1, starts)
        assertEquals(1, stops)
    }

    @Test
    fun `pump end restarts while a collector remains subscribed`() = runTest {
        var starts = 0
        var stops = 0
        lateinit var listener: SwiftCore.LiveFrameListener
        val source =
            SwiftCoreLiveFrameSource(
                available = { true },
                start = {
                    starts++
                    listener = it
                },
                stop = { stops++ },
                sharingScope = backgroundScope,
                restartDelayMillis = 0L,
            )
        val frames = mutableListOf<LiveFrame>()
        val collector = launch { source.frames.collect { frames += it } }
        runCurrent()

        listener.onEnded()
        runCurrent()

        assertEquals(2, starts)
        assertEquals(1, stops)
        listener.onFrame(byteArrayOf(9), 9L, true)
        runCurrent()

        assertEquals(1, frames.size)
        assertContentEquals(byteArrayOf(9), frames.single().jpegData)
        assertTrue(frames.single().isRecording)
        collector.cancelAndJoin()
        runCurrent()
        assertEquals(2, stops)
    }

    @Test
    fun `cancelling collection stops the pump`() = runTest {
        val stopped = AtomicBoolean(false)
        val source =
            SwiftCoreLiveFrameSource(
                available = { true },
                start = { listener -> listener.onFrame(byteArrayOf(1), 1L, false) },
                stop = { stopped.set(true) },
                sharingScope = backgroundScope,
            )

        val job = launch { source.frames.first() }
        runCurrent()
        job.join()
        runCurrent()

        assertTrue(stopped.get())
    }
}
