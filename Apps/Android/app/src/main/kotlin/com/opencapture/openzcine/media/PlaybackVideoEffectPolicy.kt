@file:androidx.media3.common.util.UnstableApi

package com.opencapture.openzcine.media

import androidx.media3.common.C
import androidx.media3.common.ColorInfo
import androidx.media3.common.Player
import androidx.media3.common.Tracks

/** Selected decoder colour mode used to fail closed before enabling the SDR-only GLES path. */
internal enum class PlaybackVideoColorMode {
    UNKNOWN,
    SDR,
    HDR,
}

/** Ordered Media3 stages for a playback image-assist graph. */
internal enum class PlaybackVideoEffectStage {
    CLEAN_SCOPE,
    DISPLAY_ASSISTS,
}

/** Resolves the selected video track without treating an as-yet-unknown stream as SDR. */
internal fun selectedPlaybackVideoColorMode(tracks: Tracks): PlaybackVideoColorMode {
    var selectedVideoFound = false
    for (group in tracks.groups) {
        if (group.type != C.TRACK_TYPE_VIDEO) continue
        for (index in 0 until group.length) {
            if (!group.isTrackSelected(index)) continue
            selectedVideoFound = true
            if (ColorInfo.isTransferHdr(group.getTrackFormat(index).colorInfo)) {
                return PlaybackVideoColorMode.HDR
            }
        }
    }
    return if (selectedVideoFound) PlaybackVideoColorMode.SDR else PlaybackVideoColorMode.UNKNOWN
}

/** Image-effect capability for the API 33 AGSL path and the API 29–32 SDR GLES fallback. */
internal fun playbackImageEffectsAvailable(
    sdk: Int,
    swiftCoreAvailable: Boolean,
    colorMode: PlaybackVideoColorMode,
): Boolean =
    swiftCoreAvailable &&
        when {
            sdk >= 33 -> true
            sdk in 29..32 -> colorMode == PlaybackVideoColorMode.SDR
            else -> false
        }

/** Keeps the scope reader ahead of display assists so analysis always receives clean pixels. */
internal fun playbackVideoEffectStages(
    displayAssistsActive: Boolean,
    scopesVisible: Boolean,
): List<PlaybackVideoEffectStage> =
    if (!displayAssistsActive) {
        emptyList()
    } else {
        buildList {
            if (scopesVisible) add(PlaybackVideoEffectStage.CLEAN_SCOPE)
            add(PlaybackVideoEffectStage.DISPLAY_ASSISTS)
        }
    }

/** A changed graph needs explicit redraw only when no advancing decoder frame will apply it. */
internal fun shouldRedrawPlaybackVideoEffects(
    playbackState: Int,
    isPlaying: Boolean,
): Boolean = playbackState != Player.STATE_IDLE && !isPlaying
