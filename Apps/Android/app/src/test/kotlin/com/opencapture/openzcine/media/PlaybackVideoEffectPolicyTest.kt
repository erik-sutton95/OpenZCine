package com.opencapture.openzcine.media

import androidx.media3.common.Player
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertTrue

class PlaybackVideoEffectPolicyTest {
    @Test
    fun `api 29 through 32 enables image assists only for confirmed SDR`() {
        for (sdk in 29..32) {
            assertFalse(playbackImageEffectsAvailable(sdk, true, PlaybackVideoColorMode.UNKNOWN))
            assertTrue(playbackImageEffectsAvailable(sdk, true, PlaybackVideoColorMode.SDR))
            assertFalse(playbackImageEffectsAvailable(sdk, true, PlaybackVideoColorMode.HDR))
        }
        assertFalse(playbackImageEffectsAvailable(32, false, PlaybackVideoColorMode.SDR))
        assertFalse(playbackImageEffectsAvailable(28, true, PlaybackVideoColorMode.SDR))
    }

    @Test
    fun `api 33 keeps the existing AGSL capability contract`() {
        assertTrue(playbackImageEffectsAvailable(33, true, PlaybackVideoColorMode.UNKNOWN))
        assertTrue(playbackImageEffectsAvailable(36, true, PlaybackVideoColorMode.HDR))
        assertFalse(playbackImageEffectsAvailable(36, false, PlaybackVideoColorMode.SDR))
    }

    @Test
    fun `clean scope tap always precedes fallback display assists`() {
        assertEquals(
            listOf(
                PlaybackVideoEffectStage.CLEAN_SCOPE,
                PlaybackVideoEffectStage.DISPLAY_ASSISTS,
            ),
            playbackVideoEffectStages(displayAssistsActive = true, scopesVisible = true),
        )
        assertEquals(
            listOf(PlaybackVideoEffectStage.DISPLAY_ASSISTS),
            playbackVideoEffectStages(displayAssistsActive = true, scopesVisible = false),
        )
        assertEquals(
            emptyList(),
            playbackVideoEffectStages(displayAssistsActive = false, scopesVisible = true),
        )
    }

    @Test
    fun `paused prepared player redraws after effect replacement`() {
        assertTrue(shouldRedrawPlaybackVideoEffects(Player.STATE_READY, isPlaying = false))
        assertTrue(shouldRedrawPlaybackVideoEffects(Player.STATE_ENDED, isPlaying = false))
        assertFalse(shouldRedrawPlaybackVideoEffects(Player.STATE_READY, isPlaying = true))
        assertFalse(shouldRedrawPlaybackVideoEffects(Player.STATE_IDLE, isPlaying = false))
    }
}
