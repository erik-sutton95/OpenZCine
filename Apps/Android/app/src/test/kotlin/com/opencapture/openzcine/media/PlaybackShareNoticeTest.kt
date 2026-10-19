package com.opencapture.openzcine.media

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNull

/** ZAB-524: playback says why Share waits while the clip is still caching from the camera. */
class PlaybackShareNoticeTest {
    @Test fun cachingClipExplainsTheShareWait() {
        assertEquals("Still caching from the camera. Share will finish the copy first.",
            playbackShareNotice(PlaybackShareState.BUFFERING, cameraTransferAvailable = true))
        assertEquals("Buffering camera proxy. Delivery unlocks after the private cache completes.",
            playbackShareNotice(PlaybackShareState.BUFFERING, cameraTransferAvailable = false))
        assertNull(playbackShareNotice(PlaybackShareState.READY, cameraTransferAvailable = true))
        assertNull(playbackShareNotice(PlaybackShareState.UNAVAILABLE, cameraTransferAvailable = false))
    }
}
