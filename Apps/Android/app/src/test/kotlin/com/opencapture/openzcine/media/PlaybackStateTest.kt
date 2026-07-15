package com.opencapture.openzcine.media

import androidx.media3.common.Player
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNull

/** Pure playback policy coverage; Media3 and camera I/O remain outside JVM tests. */
class PlaybackStateTest {
    private val cameraID = "ZR-6001234"

    @Test
    fun `previous and next retain the filtered favorite video order`() {
        val first = clip(1, "A001.MOV")
        val still = clip(2, "DSC_0002.JPG", MediaContentKind.STILL_PHOTO)
        val second = clip(3, "B001.MP4")
        val third = clip(4, "C001.MOV")
        val favoriteIDs = setOf(first.libraryKey(cameraID), still.libraryKey(cameraID), third.libraryKey(cameraID))
        val filtered =
            MediaLibraryFiltering.displayed(
                clips = listOf(first, still, second, third),
                category = MediaLibraryCategory.FAVORITES,
                favoriteIDs = favoriteIDs,
                cameraID = cameraID,
                sortOrder = MediaLibrarySortOrder.NAME,
            )
        val playable = PlaybackNavigation.playableClips(filtered)

        assertEquals(listOf(first, third), playable)
        assertNull(PlaybackNavigation.adjacent(playable, first, direction = -1))
        assertEquals(third, PlaybackNavigation.adjacent(playable, first, direction = 1))
        assertEquals(first, PlaybackNavigation.adjacent(playable, third, direction = -1))
        assertNull(PlaybackNavigation.adjacent(playable, third, direction = 1))
    }

    @Test
    fun `timeline clamps precise seeks and throttles only preview seeks`() {
        assertEquals(0L, PlaybackTimeline.clampPosition(-1L, 60_000L))
        assertEquals(42_000L, PlaybackTimeline.clampPosition(42_000L, 60_000L))
        assertEquals(60_000L, PlaybackTimeline.clampPosition(61_000L, 60_000L))
        assertEquals(0L, PlaybackTimeline.clampPosition(5L, -1L))
        assertEquals(false, PlaybackTimeline.shouldPreviewSeek(1_000L, 1_074L))
        assertEquals(true, PlaybackTimeline.shouldPreviewSeek(1_000L, 1_075L))
    }

    @Test
    fun `mute is player local and complete cache is the only shareable state`() {
        assertEquals(PlaybackAudioMode.MUTED, PlaybackAudioMode.AUDIBLE.toggled())
        assertEquals(0f, PlaybackAudioMode.MUTED.volume)
        assertEquals(PlaybackAudioMode.AUDIBLE, PlaybackAudioMode.MUTED.toggled())
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
    fun `end then seek-back state removes the replay affordance`() {
        assertEquals(true, requiresPlaybackReplay(Player.STATE_ENDED))
        assertEquals(false, requiresPlaybackReplay(Player.STATE_BUFFERING))
        assertEquals(false, requiresPlaybackReplay(Player.STATE_READY))
    }

    @Test
    fun `pan remains inside the zoomed presentation including desqueeze`() {
        assertEquals(
            PlaybackPan(x = 0f, y = 300f),
            clampPlaybackPan(
                requested = PlaybackPan(x = 900f, y = 900f),
                viewportWidth = 1_000f,
                viewportHeight = 600f,
                zoom = 2f,
                horizontalPresentationScale = 0.5f,
            ),
        )
        assertEquals(
            PlaybackPan(x = -500f, y = -900f),
            clampPlaybackPan(
                requested = PlaybackPan(x = -900f, y = -900f),
                viewportWidth = 1_000f,
                viewportHeight = 600f,
                zoom = 4f,
                horizontalPresentationScale = 0.5f,
            ),
        )
    }

    private fun clip(
        handle: Long,
        filename: String,
        contentKind: MediaContentKind = MediaContentKind.PLAYABLE_PROXY,
    ): MediaClipRecord =
        MediaClipRecord(
            handle = handle,
            storageId = 1,
            sizeBytes = 100,
            captureDate = "20260715T101010",
            pixelWidth = 3840,
            pixelHeight = 2160,
            filename = filename,
            contentKind = contentKind,
            stillPhoto =
                if (contentKind == MediaContentKind.STILL_PHOTO) {
                    StillPhotoClassification("JPEG", StillPreviewStrategy.PROGRESSIVE)
                } else {
                    null
                },
        )
}
