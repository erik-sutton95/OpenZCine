package com.opencapture.openzcine

import com.opencapture.opencine.nikon.LiveAudioMeterChannel
import com.opencapture.opencine.nikon.LiveAudioMeterLevels
import kotlin.test.Test
import kotlin.test.assertTrue

class AudioMetersTest {
    @Test
    fun `accessibility distinguishes fixture values from camera data`() {
        val levels =
            LiveAudioMeterLevels(
                left = LiveAudioMeterChannel(levelDb = -18.0, peakDb = -6.0),
                right = LiveAudioMeterChannel(levelDb = -30.0, peakDb = -12.0),
                isDebugFixture = true,
            )

        val strings =
            PhoneStringResolver { resource, args ->
                when (resource) {
                    R.string.audio_channel_left -> "left"
                    R.string.audio_channel_right -> "right"
                    R.string.audio_channel_level ->
                        "%s %.0f dB, peak %.0f".format(args[0], args[1], args[2])
                    R.string.audio_state_summary -> "%s, %s, sensitivity %s".format(*args)
                    else -> error("Unexpected string resource $resource")
                }
            }
        val description = audioMeterStateDescription(strings, levels, "auto")

        assertTrue(description.contains("sensitivity AUTO"))
        assertTrue(description.contains("debug fixture, not camera audio"))
    }
}
