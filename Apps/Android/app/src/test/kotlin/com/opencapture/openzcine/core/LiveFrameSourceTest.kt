package com.opencapture.openzcine.core

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertSame
import kotlin.test.assertTrue
import kotlinx.coroutines.flow.flowOf
import kotlinx.coroutines.flow.toList
import kotlinx.coroutines.test.runTest

class LiveFrameSourceTest {
    /**
     * The pixels are dropped and everything else survives.
     *
     * Three of the four live-frame collectors read only metadata, yet each pinned a ~150 KB JPEG
     * in its conflate buffer — one large-object allocation per frame on a 21 MB heap.
     */
    @Test
    fun `metadata frames keep every reading and drop the pixels`() = runTest {
        val timecode = LiveFrameTimecode(on = true, hour = 1, minute = 2, second = 3, frame = 4)
        val audio = LiveAudioMeterLevels(LiveAudioMeterChannel(-12.0, -6.0), LiveAudioMeterChannel(-13.0, -7.0))
        val frame =
            LiveFrame(
                timestampNanos = 1_234,
                jpegData = ByteArray(150_000) { 7 },
                isRecording = true,
                audioLevels = audio,
                timecode = timecode,
                measuredFramesPerSecond = 24.97,
                rotation = LiveFeedRotation.PORTRAIT_GRIP_UP,
            )

        val stripped = flowOf(frame).metadataOnly().toList().single()

        assertTrue(stripped.jpegData.isEmpty(), "a metadata consumer must not pin the pixels")
        assertEquals(1_234, stripped.timestampNanos)
        assertTrue(stripped.isRecording)
        assertSame(audio, stripped.audioLevels)
        assertSame(timecode, stripped.timecode)
        assertEquals(24.97, stripped.measuredFramesPerSecond)
        assertEquals(LiveFeedRotation.PORTRAIT_GRIP_UP, stripped.rotation)
    }

    /** The empty payload is shared, so stripping never allocates an array of its own. */
    @Test
    fun `stripping does not allocate a payload per frame`() = runTest {
        val frames =
            listOf(
                LiveFrame(timestampNanos = 1, jpegData = ByteArray(1_000)),
                LiveFrame(timestampNanos = 2, jpegData = ByteArray(1_000)),
            )

        val stripped = frames.asFlowOfLiveFrames().metadataOnly().toList()

        assertSame(stripped[0].jpegData, stripped[1].jpegData)
    }

    private fun List<LiveFrame>.asFlowOfLiveFrames() = flowOf(*toTypedArray())
}
