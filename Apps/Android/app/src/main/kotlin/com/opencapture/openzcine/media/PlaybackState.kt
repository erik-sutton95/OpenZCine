package com.opencapture.openzcine.media


/** Cache completeness shown by playback chrome; delivery itself can still cache from the camera. */
internal enum class PlaybackShareState {
    /** The cache is still growing. Share remains available when the camera can finish the copy. */
    BUFFERING,

    /** A validated final cache artifact may be staged into FileProvider storage. */
    READY,

    /** The transfer ended without a complete artifact. */
    UNAVAILABLE,
}

/** Derives cache completeness from the entry's validated state. */
internal fun playbackShareState(
    state: MediaCacheState,
    downloadedBytes: Long,
    expectedLength: Long,
): PlaybackShareState =
    when {
        state == MediaCacheState.COMPLETE && downloadedBytes == expectedLength -> PlaybackShareState.READY
        state == MediaCacheState.ACTIVE -> PlaybackShareState.BUFFERING
        else -> PlaybackShareState.UNAVAILABLE
    }

/**
 * Native share / save (and Frame.io after a cache pre-pass) can start when a complete local
 * copy exists, or the camera is connected so the delivery run can pull the file first.
 *
 * Mirrors iOS `MediaDeliveryEligibility`.
 */
internal fun canDeliverMedia(
    readyCount: Int,
    clipCount: Int,
    cameraConnected: Boolean,
): Boolean = clipCount > 0 && (readyCount > 0 || cameraConnected)
