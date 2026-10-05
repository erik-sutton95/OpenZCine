package com.opencapture.openzcine.media

import kotlin.test.Test
import kotlin.test.assertEquals

/** Pure playback policy coverage; Media3 and camera I/O remain outside JVM tests. */
class PlaybackStateTest {
    @Test
    fun `cache completeness is independent of delivery`() {
        assertEquals(
            PlaybackShareState.BUFFERING,
            playbackShareState(MediaCacheState.ACTIVE, downloadedBytes = 5L, expectedLength = 10L),
        )
        assertEquals(
            PlaybackShareState.UNAVAILABLE,
            playbackShareState(MediaCacheState.COMPLETE, downloadedBytes = 9L, expectedLength = 10L),
        )
        assertEquals(
            PlaybackShareState.READY,
            playbackShareState(MediaCacheState.COMPLETE, downloadedBytes = 10L, expectedLength = 10L),
        )
        assertEquals(
            PlaybackShareState.UNAVAILABLE,
            playbackShareState(MediaCacheState.FAILED, downloadedBytes = 10L, expectedLength = 10L),
        )
    }

    @Test
    fun `connected camera can start delivery before the cache completes`() {
        assertEquals(true, canDeliverMedia(readyCount = 0, clipCount = 1, cameraConnected = true))
        assertEquals(true, canDeliverMedia(readyCount = 1, clipCount = 1, cameraConnected = false))
        assertEquals(false, canDeliverMedia(readyCount = 0, clipCount = 1, cameraConnected = false))
        assertEquals(false, canDeliverMedia(readyCount = 0, clipCount = 0, cameraConnected = true))
    }
}
