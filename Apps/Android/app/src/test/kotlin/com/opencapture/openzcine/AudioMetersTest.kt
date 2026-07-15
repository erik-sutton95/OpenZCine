package com.opencapture.openzcine

import com.opencapture.openzcine.bridge.ZoneFrame
import com.opencapture.openzcine.core.LiveAudioMeterChannel
import com.opencapture.openzcine.core.LiveAudioMeterLevels
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertTrue

class AudioMetersTest {
    @Test
    fun `debug fixture reserves room for an explicit provenance label`() {
        val normal = audioMeterPanelSize(isDebugFixture = false)
        val fixture = audioMeterPanelSize(isDebugFixture = true)

        assertEquals(28f, normal.first)
        assertEquals(168f, normal.second)
        assertTrue(fixture.first > normal.first)
        assertEquals(normal.second, fixture.second)
    }

    @Test
    fun `audio panel defaults bottom trailing and remains inside the viewport`() {
        val viewport = ZoneFrame(0f, 0f, 720f, 400f)
        val feed = ZoneFrame(59f, 0f, 617f, 400f)
        val (width, height) = audioMeterPanelSize(isDebugFixture = false)

        val frame = floatingAudioMeterFrame(feed, viewport, width, height)

        assertTrue(frame.x >= viewport.x)
        assertTrue(frame.y >= viewport.y)
        assertTrue(frame.x + frame.width <= viewport.x + viewport.width)
        assertTrue(frame.y + frame.height <= viewport.y + viewport.height)
        assertTrue(frame.x + frame.width <= feed.x + feed.width)
    }

    @Test
    fun `playback viewport does not apply its chrome clearance twice`() {
        val viewport = ZoneFrame(0f, 62f, 800f, 194f)
        val feed = ZoneFrame(81f, 0f, 640f, 360f)
        val (width, height) = audioMeterPanelSize(isDebugFixture = false)

        val frame =
            floatingAudioMeterFrame(
                feed,
                viewport,
                width,
                height,
                bottomChromeClearance = 0f,
            )

        assertEquals(78f, frame.y)
        assertEquals(246f, frame.y + frame.height)

        val portraitClearance =
            floatingAudioMeterFrame(
                feed,
                viewport,
                width,
                height,
                bottomChromeClearance = 0f,
                trailingEdgeGap = 70f,
            )
        assertEquals(feed.x + feed.width - width - 70f, portraitClearance.x)
    }

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
