package com.opencapture.openzcine

import com.opencapture.opencine.nikon.LiveAudioMeterChannel
import com.opencapture.opencine.nikon.LiveAudioMeterLevels

private const val AUDIO_METER_FLOOR_DB = -60.0

/** iOS-equivalent sensitivity label fallback. */
internal fun displayedAudioSensitivity(value: String?): String =
    value?.trim()?.takeIf(String::isNotEmpty)?.uppercase() ?: "—"

/** TalkBack-facing readout; fixture provenance is explicit rather than implied by moving bars. */
internal fun audioMeterStateDescription(
    strings: PhoneStringResolver,
    levels: LiveAudioMeterLevels?,
    sensitivity: String?,
): String {
    if (levels == null) {
        return strings.resolve(
            R.string.audio_state_unavailable,
            displayedAudioSensitivity(sensitivity),
        )
    }
    fun channel(name: String, value: LiveAudioMeterChannel): String =
        if (value.levelDb <= AUDIO_METER_FLOOR_DB + 0.5) {
            strings.resolve(R.string.audio_channel_silent, name)
        } else {
            strings.resolve(
                R.string.audio_channel_level,
                name,
                value.levelDb,
                value.peakDb,
            )
        }
    val summary =
        strings.resolve(
            R.string.audio_state_summary,
            channel(strings.resolve(R.string.audio_channel_left), levels.left),
            channel(strings.resolve(R.string.audio_channel_right), levels.right),
            displayedAudioSensitivity(sensitivity),
        )
    return if (levels.isDebugFixture) {
        summary + ", debug fixture, not camera audio"
    } else {
        summary
    }
}
