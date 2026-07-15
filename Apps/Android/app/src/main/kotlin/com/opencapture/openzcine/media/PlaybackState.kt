package com.opencapture.openzcine.media

import kotlin.math.max

/**
 * Selection-preserving navigation for the video player.
 *
 * The browser hands this helper its already filtered and sorted result. It
 * deliberately accepts only clips that the shared Swift listing wire marked as
 * playable proxies: stills retain their dedicated viewer, and masters or
 * unsupported objects can never be presented as Android-decodable video.
 */
internal object PlaybackNavigation {
    /** Keeps the browser's current filter/order while excluding non-video actions. */
    fun playableClips(clips: List<MediaClipRecord>): List<MediaClipRecord> =
        clips.filter { it.contentKind == MediaContentKind.PLAYABLE_PROXY }

    /** Returns the adjacent playable item in the filtered result, or null at an edge. */
    fun adjacent(
        clips: List<MediaClipRecord>,
        active: MediaClipRecord,
        direction: Int,
    ): MediaClipRecord? {
        require(direction == -1 || direction == 1) { "direction must be -1 or 1." }
        val index = clips.indexOf(active)
        if (index < 0) return null
        return clips.getOrNull(index + direction)
    }
}

/** Pure timeline decisions shared by Compose's slider and preview-seek loop. */
internal object PlaybackTimeline {
    /** iOS-equivalent drag preview cadence: responsive without decoder seek storms. */
    const val PREVIEW_SEEK_INTERVAL_MILLIS: Long = 75L

    /** Clamps a requested seek to a finite, known media duration. */
    fun clampPosition(requestedMillis: Long, durationMillis: Long): Long =
        requestedMillis.coerceIn(0L, max(0L, durationMillis))

    /** Whether a drag movement may issue a coarse decoder seek now. */
    fun shouldPreviewSeek(lastSeekMillis: Long, nowMillis: Long): Boolean =
        nowMillis - lastSeekMillis >= PREVIEW_SEEK_INTERVAL_MILLIS
}

/** State of app-local output muting; Media3 owns focus and noisy-route handling. */
internal enum class PlaybackAudioMode(val volume: Float) {
    AUDIBLE(1f),
    MUTED(0f),
    ;

    /** Toggles only this player's volume; it never changes system volume. */
    fun toggled(): PlaybackAudioMode =
        if (this == AUDIBLE) MUTED else AUDIBLE
}

/** Complete-cache-only delivery state shown by playback chrome. */
internal enum class PlaybackShareState {
    /** The cache is still growing, so no external URI can be exposed. */
    BUFFERING,

    /** A validated final cache artifact may be staged into FileProvider storage. */
    READY,

    /** The transfer ended without a complete artifact. */
    UNAVAILABLE,
}

/** Derives safe share eligibility solely from the cache entry's validated state. */
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

/** Screen-space pan used for playback zoom without leaking Compose geometry into tests. */
internal data class PlaybackPan(
    val x: Float = 0f,
    val y: Float = 0f,
)

/**
 * Bounds a zoomed video to its viewport. A configured anamorphic presentation
 * can shrink the horizontal image before zooming, so the horizontal and
 * vertical limits are intentionally independent.
 */
internal fun clampPlaybackPan(
    requested: PlaybackPan,
    viewportWidth: Float,
    viewportHeight: Float,
    zoom: Float,
    horizontalPresentationScale: Float,
): PlaybackPan {
    val safeZoom = zoom.coerceAtLeast(1f)
    val scaledWidth = safeZoom * horizontalPresentationScale.coerceAtLeast(0f)
    val scaledHeight = safeZoom
    val maxX = (viewportWidth.coerceAtLeast(0f) * (scaledWidth - 1f).coerceAtLeast(0f)) / 2f
    val maxY = (viewportHeight.coerceAtLeast(0f) * (scaledHeight - 1f).coerceAtLeast(0f)) / 2f
    return PlaybackPan(
        x = requested.x.coerceIn(-maxX, maxX),
        y = requested.y.coerceIn(-maxY, maxY),
    )
}
