package com.opencapture.openzcine.bridge

import java.util.concurrent.atomic.AtomicBoolean
import kotlin.test.Test
import kotlin.test.assertContentEquals
import kotlin.test.assertEquals
import kotlin.test.assertTrue
import kotlin.test.fail
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.flow.toList
import kotlinx.coroutines.launch
import kotlinx.coroutines.test.runTest

/**
 * Pure marshaling behavior with injected start/stop hooks — the native pump
 * itself is tested in Swift against the fake ZR
 * (`Tests/OpenZCineAndroidFacadeTests/LiveViewPumpTests.swift`).
 */
class SwiftCoreLiveFrameSourceTest {
    @Test
    fun `completes empty without the native core`() = runTest {
        val source =
            SwiftCoreLiveFrameSource(
                available = { false },
                start = { fail("must not start live view without the native library") },
                stop = { fail("must not stop live view without the native library") },
            )

        assertEquals(emptyList(), source.frames.toList())
    }

    @Test
    fun `bridges callbacks into frames and completes when the pump ends`() = runTest {
        val jpeg = byteArrayOf(1, 2, 3)
        var recordingState: Boolean? = null
        val source =
            SwiftCoreLiveFrameSource(
                available = { true },
                start = { listener ->
                    listener.onFrame(jpeg, 7L, true)
                    listener.onEnded()
                },
                stop = {},
                onRecordingState = { recordingState = it },
            )

        val frames = source.frames.toList()

        assertEquals(1, frames.size)
        assertContentEquals(jpeg, frames.single().jpegData)
        assertEquals(7L, frames.single().timestampNanos)
        assertTrue(frames.single().isRecording)
        assertEquals(true, recordingState)
    }

    @Test
    fun `cancelling collection stops the pump`() = runTest {
        val stopped = AtomicBoolean(false)
        val source =
            SwiftCoreLiveFrameSource(
                available = { true },
                start = { listener -> listener.onFrame(byteArrayOf(1), 1L, false) },
                stop = { stopped.set(true) },
            )

        val job = launch { source.frames.first() }
        job.join()

        assertTrue(stopped.get())
    }
}
